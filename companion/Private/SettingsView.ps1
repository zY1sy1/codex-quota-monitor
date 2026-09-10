if (-not (Get-Command Get-MonitorAppIconPath -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'WindowIcon.ps1')
}
if (-not (Get-Command Set-SettingsWindowTheme -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Theme.ps1')
}

function New-SettingsView {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$XamlPath = (Join-Path $PSScriptRoot '..\UI\Settings.xaml')
    )

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne
        [Threading.ApartmentState]::STA) {
        throw 'The settings window requires an STA thread.'
    }
    if (-not (Get-Command Set-SettingsWindowTheme -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'Theme.ps1')
    }
    $setSettingsWindowThemeFunction = ${function:Set-SettingsWindowTheme}
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    if (-not (Test-Path -LiteralPath $XamlPath -PathType Leaf)) {
        throw "Settings XAML was not found: $XamlPath"
    }

    $stream = $null
    $reader = $null
    try {
        $stream = [IO.FileStream]::new(
            [IO.Path]::GetFullPath($XamlPath), [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read
        )
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        $window = [Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
    if ($window -isnot [Windows.Window]) {
        throw 'Settings XAML root must be a Window.'
    }

    $windowIcon = ConvertTo-MonitorWindowIconSource (Get-MonitorAppIconPath)
    if ($null -ne $windowIcon) {
        $window.Icon = $windowIcon
    }

    $controlNames = @(
        'RootGrid', 'SidebarBorder',
        'AppearanceNavRadio', 'BehaviorNavRadio', 'RelayNavRadio',
        'AppearancePage', 'BehaviorPage', 'RelayPage',
        'DisplayModeGroup', 'FullModeRadio', 'CompactBarModeRadio', 'OrbModeRadio',
        'ThemeGroup', 'LightThemeRadio', 'DarkThemeRadio',
        'FullLayoutGroup', 'OverviewLayoutRadio', 'TabsLayoutRadio',
        'LayoutAvailabilityText', 'TopmostCheckBox', 'StartupCheckBox',
        'TodaySpendCheckBox',
        'RelayOrderSurface', 'RelayOrderList', 'RelayOrderEmptyText',
        'RefreshButton', 'ManageRelaysButton', 'StatusText'
    )
    $controls = [ordered]@{}
    foreach ($name in $controlNames) {
        $control = $window.FindName($name)
        if ($null -eq $control) {
            $window.Close()
            throw "Settings XAML is missing named control '$name'."
        }
        $controls[$name] = $control
    }

    $state = [pscustomobject][ordered]@{
        Window = $window
        Controls = $controls
        Callbacks = $null
        Disposed = $false
        CurrentPage = 'Appearance'
        Delegates = [ordered]@{}
        RelayOrderHandlers = [Collections.Generic.List[object]]::new()
    }

    # A local reader keeps this view loadable on its own, the same way the
    # relay manager view carries its own field accessor.
    $getField = {
        param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name)
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [Collections.IDictionary]) {
            return ([Collections.IDictionary]$InputObject)[$Name]
        }
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
        return $null
    }

    $invoke = {
        param([string]$Name, [object[]]$Arguments)
        if ($state.Disposed -or $null -eq $state.Callbacks) { return $null }
        $callback = $state.Callbacks.PSObject.Properties[$Name]
        if ($null -ne $callback -and $null -ne $callback.Value) {
            return & $callback.Value @Arguments
        }
        return $null
    }.GetNewClosure()

    $setPage = {
        param([ValidateSet('Appearance', 'Behavior', 'Relay')][string]$Page)
        if ($state.Disposed) { return }
        $state.CurrentPage = $Page
        foreach ($name in @('Appearance', 'Behavior', 'Relay')) {
            $state.Controls["${name}Page"].Visibility = if ($name -eq $Page) {
                [Windows.Visibility]::Visible
            }
            else {
                [Windows.Visibility]::Collapsed
            }
            $state.Controls["${name}NavRadio"].IsChecked = ($name -eq $Page)
        }
    }.GetNewClosure()

    foreach ($definition in @(
        @{ Control = 'AppearanceNavRadio'; Page = 'Appearance' }
        @{ Control = 'BehaviorNavRadio'; Page = 'Behavior' }
        @{ Control = 'RelayNavRadio'; Page = 'Relay' }
    )) {
        $page = [string]$definition.Page
        $handler = [Windows.RoutedEventHandler]{
            param($sender, $args)
            & $setPage $page
        }.GetNewClosure()
        $state.Delegates[$definition.Control] = $handler
        $controls[$definition.Control].Add_Click($handler)
    }

    foreach ($definition in @(
        @{ Control = 'FullModeRadio'; Callback = 'OnSetDisplayMode'; Tag = 'Full' }
        @{ Control = 'CompactBarModeRadio'; Callback = 'OnSetDisplayMode'; Tag = 'CompactBar' }
        @{ Control = 'OrbModeRadio'; Callback = 'OnSetDisplayMode'; Tag = 'Orb' }
        @{ Control = 'LightThemeRadio'; Callback = 'OnSetTheme'; Tag = 'Light' }
        @{ Control = 'DarkThemeRadio'; Callback = 'OnSetTheme'; Tag = 'Dark' }
        @{ Control = 'OverviewLayoutRadio'; Callback = 'OnSetFullLayout'; Tag = 'Overview' }
        @{ Control = 'TabsLayoutRadio'; Callback = 'OnSetFullLayout'; Tag = 'Tabs' }
    )) {
        $callbackName = [string]$definition.Callback
        $tagValue = [string]$definition.Tag
        $handler = [Windows.RoutedEventHandler]{
            param($sender, $args)
            $null = & $invoke $callbackName @($tagValue)
        }.GetNewClosure()
        $state.Delegates[$definition.Control] = $handler
        $controls[$definition.Control].Add_Click($handler)
    }

    foreach ($definition in @(
        @{ Control = 'TopmostCheckBox'; Callback = 'OnToggleTopmost' }
        @{ Control = 'StartupCheckBox'; Callback = 'OnToggleStartup' }
        @{ Control = 'TodaySpendCheckBox'; Callback = 'OnToggleTodaySpend' }
        @{ Control = 'RefreshButton'; Callback = 'OnRefresh' }
        @{ Control = 'ManageRelaysButton'; Callback = 'OnManageRelays' }
    )) {
        $callbackName = [string]$definition.Callback
        $handler = [Windows.RoutedEventHandler]{
            param($sender, $args)
            $null = & $invoke $callbackName @()
        }.GetNewClosure()
        $state.Delegates[$definition.Control] = $handler
        $controls[$definition.Control].Add_Click($handler)
    }

    $closing = [ComponentModel.CancelEventHandler]{
        param($sender, $eventArgs)
        if (-not $state.Disposed) {
            $eventArgs.Cancel = $true
            $null = & $invoke 'OnClosing' @()
            $state.Window.Hide()
        }
    }.GetNewClosure()
    $state.Delegates.Closing = $closing
    $window.Add_Closing($closing)

    $showDialog = {
        if ($state.Disposed) { return }
        & $setPage 'Appearance'
        return $state.Window.ShowDialog()
    }.GetNewClosure()

    $setSnapshot = {
        param(
            [string]$Mode,
            [string]$Theme,
            [string]$FullLayout,
            [bool]$Topmost,
            [bool]$Startup,
            [bool]$ShowTodaySpend = $true
        )
        if ($state.Disposed) { return }

        $modeControl = switch ($Mode) {
            'CompactBar' { $state.Controls.CompactBarModeRadio }
            'Orb' { $state.Controls.OrbModeRadio }
            default { $state.Controls.FullModeRadio }
        }
        $themeControl = if ($Theme -eq 'Light') {
            $state.Controls.LightThemeRadio
        }
        else {
            $state.Controls.DarkThemeRadio
        }
        $layoutControl = if ($FullLayout -eq 'Tabs') {
            $state.Controls.TabsLayoutRadio
        }
        else {
            $state.Controls.OverviewLayoutRadio
        }

        foreach ($control in @(
            $state.Controls.FullModeRadio, $state.Controls.CompactBarModeRadio,
            $state.Controls.OrbModeRadio, $state.Controls.LightThemeRadio,
            $state.Controls.DarkThemeRadio, $state.Controls.OverviewLayoutRadio,
            $state.Controls.TabsLayoutRadio
        )) {
            $control.IsChecked = $false
        }
        $modeControl.IsChecked = $true
        $themeControl.IsChecked = $true
        $layoutControl.IsChecked = $true
        $state.Controls.TopmostCheckBox.IsChecked = $Topmost
        $state.Controls.StartupCheckBox.IsChecked = $Startup
        $state.Controls.TodaySpendCheckBox.IsChecked = $ShowTodaySpend

        $layoutEnabled = ($Mode -eq 'Full')
        $state.Controls.OverviewLayoutRadio.IsEnabled = $layoutEnabled
        $state.Controls.TabsLayoutRadio.IsEnabled = $layoutEnabled
        $state.Controls.LayoutAvailabilityText.Text = '仅完整窗口模式可用'
        $null = & $setSettingsWindowThemeFunction -Window $state.Window -Theme $Theme
        $state.Controls.StatusText.Text = '更改即时保存'
        $state.Controls.StatusText.Foreground =
            $state.Window.Resources['SettingsTextSecondaryBrush']
    }.GetNewClosure()

    $detachRelayOrderHandlers = {
        foreach ($entry in @($state.RelayOrderHandlers)) {
            try { $entry.Control.Remove_Click($entry.Handler) } catch { }
        }
        $state.RelayOrderHandlers.Clear()
        $state.Controls.RelayOrderList.Children.Clear()
    }.GetNewClosure()

    # One styled row per provider, in display order. The label carries the
    # 已停用 tag because a disabled provider is invisible in the floating
    # window, so this list is the only place the state shows up.
    $setRelayOrder = {
        param([AllowEmptyCollection()][object[]]$Providers)
        if ($state.Disposed) { return }
        & $detachRelayOrderHandlers

        # Captured here on purpose: a closure nested inside another closure only
        # picks up the variables its own text names directly, so the row handlers
        # below need this alias rather than reaching for $invoke themselves.
        $invokeForRows = $invoke

        $items = [Collections.Generic.List[object]]::new()
        foreach ($provider in @($Providers)) {
            if ($null -ne $provider) { $items.Add($provider) }
        }
        if ($items.Count -eq 0) {
            $state.Controls.RelayOrderSurface.Visibility = [Windows.Visibility]::Collapsed
            $state.Controls.RelayOrderEmptyText.Visibility = [Windows.Visibility]::Visible
            return
        }
        $state.Controls.RelayOrderSurface.Visibility = [Windows.Visibility]::Visible
        $state.Controls.RelayOrderEmptyText.Visibility = [Windows.Visibility]::Collapsed

        $resources = $state.Window.Resources
        $panel = $state.Controls.RelayOrderList
        for ($index = 0; $index -lt $items.Count; $index++) {
            $provider = $items[$index]
            if ($index -gt 0) {
                $separator = [Windows.Controls.Border]::new()
                $separator.Height = 1
                $separator.Background = $resources['SettingsSeparatorBrush']
                $null = $panel.Children.Add($separator)
            }

            $providerId = [string](& $getField $provider 'Id')
            $displayName = [string](& $getField $provider 'Name')
            if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $providerId }
            $isEnabled = [bool](& $getField $provider 'Enabled')

            $row = [Windows.Controls.Border]::new()
            $row.Style = $resources['OrderRowStyle']
            $grid = [Windows.Controls.Grid]::new()
            $ordinalColumn = [Windows.Controls.ColumnDefinition]::new()
            $ordinalColumn.Width = [Windows.GridLength]::new([double]22)
            $labelColumn = [Windows.Controls.ColumnDefinition]::new()
            $labelColumn.Width = [Windows.GridLength]::new([double]1, [Windows.GridUnitType]::Star)
            $buttonColumn = [Windows.Controls.ColumnDefinition]::new()
            $buttonColumn.Width = [Windows.GridLength]::Auto
            foreach ($column in @($ordinalColumn, $labelColumn, $buttonColumn)) {
                $grid.ColumnDefinitions.Add($column)
            }

            $ordinal = [Windows.Controls.TextBlock]::new()
            $ordinal.Text = [string]($index + 1)
            $ordinal.FontSize = 11
            $ordinal.Foreground = $resources['SettingsTextSecondaryBrush']
            $ordinal.VerticalAlignment = [Windows.VerticalAlignment]::Center
            [Windows.Controls.Grid]::SetColumn($ordinal, 0)
            $null = $grid.Children.Add($ordinal)

            $label = [Windows.Controls.TextBlock]::new()
            $label.Text = $displayName
            $label.FontSize = 13
            $label.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
            $label.VerticalAlignment = [Windows.VerticalAlignment]::Center
            $label.Foreground = $resources[$(if ($isEnabled) {
                'SettingsTextPrimaryBrush'
            }
            else {
                'SettingsTextSecondaryBrush'
            })]
            $labelRow = [Windows.Controls.StackPanel]::new()
            $labelRow.Orientation = [Windows.Controls.Orientation]::Horizontal
            $null = $labelRow.Children.Add($label)
            if (-not $isEnabled) {
                $tag = [Windows.Controls.Border]::new()
                $tag.Margin = [Windows.Thickness]::new(8, 0, 0, 0)
                $tag.Padding = [Windows.Thickness]::new(6, 1, 6, 1)
                $tag.CornerRadius = [Windows.CornerRadius]::new(3)
                $tag.BorderThickness = [Windows.Thickness]::new(1)
                $tag.BorderBrush = $resources['SettingsSeparatorBrush']
                $tag.Background = $resources['SettingsSidebarBrush']
                $tag.VerticalAlignment = [Windows.VerticalAlignment]::Center
                $tagText = [Windows.Controls.TextBlock]::new()
                $tagText.Text = '已停用'
                $tagText.FontSize = 10
                $tagText.Foreground = $resources['SettingsTextSecondaryBrush']
                $tag.Child = $tagText
                $null = $labelRow.Children.Add($tag)
            }
            [Windows.Controls.Grid]::SetColumn($labelRow, 1)
            $null = $grid.Children.Add($labelRow)

            $buttons = [Windows.Controls.StackPanel]::new()
            $buttons.Orientation = [Windows.Controls.Orientation]::Horizontal
            $buttons.VerticalAlignment = [Windows.VerticalAlignment]::Center
            foreach ($definition in @(
                @{ Callback = 'OnMoveRelayUp'; Action = '上移'; Data = 'M2.6,7.4 L5.8,4.2 L9,7.4'
                   Enabled = ($index -gt 0) }
                @{ Callback = 'OnMoveRelayDown'; Action = '下移'; Data = 'M2.6,4.6 L5.8,7.8 L9,4.6'
                   Enabled = ($index -lt ($items.Count - 1)) }
            )) {
                $callbackName = [string]$definition.Callback
                $actionName = [string]$definition.Action
                $button = [Windows.Controls.Button]::new()
                $button.Style = $resources['OrderMoveButtonStyle']
                $button.IsEnabled = [bool]$definition.Enabled
                $button.ToolTip = "$actionName「$displayName」"
                [Windows.Automation.AutomationProperties]::SetName(
                    $button, "${actionName}中转站：$displayName"
                )
                $icon = [Windows.Shapes.Path]::new()
                $icon.Style = $resources['OrderMoveIconStyle']
                $icon.Data = [Windows.Media.Geometry]::Parse([string]$definition.Data)
                $button.Content = $icon
                $handler = [Windows.RoutedEventHandler]{
                    param($sender, $args)
                    $null = & $invokeForRows $callbackName @($providerId)
                }.GetNewClosure()
                $state.RelayOrderHandlers.Add(
                    [pscustomobject][ordered]@{ Control = $button; Handler = $handler }
                )
                $button.Add_Click($handler)
                $null = $buttons.Children.Add($button)
            }
            [Windows.Controls.Grid]::SetColumn($buttons, 2)
            $null = $grid.Children.Add($buttons)

            $row.Child = $grid
            $null = $panel.Children.Add($row)
        }
    }.GetNewClosure()

    $setStatus = {
        param(
            [string]$Message,
            [ValidateSet('Idle', 'Success', 'Error')]
            [string]$Kind = 'Idle'
        )
        if ($state.Disposed) { return }
        $state.Controls.StatusText.Text = if ([string]::IsNullOrWhiteSpace($Message)) {
            '更改即时保存'
        }
        else {
            $Message
        }
        $brushKey = switch ($Kind) {
            'Success' { 'SettingsSuccessBrush' }
            'Error' { 'SettingsDangerBrush' }
            default { 'SettingsTextSecondaryBrush' }
        }
        $state.Controls.StatusText.Foreground = $state.Window.Resources[$brushKey]
    }.GetNewClosure()

    $setCallbacks = {
        param(
            [Parameter()][AllowNull()][scriptblock]$OnSetDisplayMode,
            [Parameter()][AllowNull()][scriptblock]$OnSetTheme,
            [Parameter()][AllowNull()][scriptblock]$OnSetFullLayout,
            [Parameter()][AllowNull()][scriptblock]$OnToggleTopmost,
            [Parameter()][AllowNull()][scriptblock]$OnToggleStartup,
            [Parameter()][AllowNull()][scriptblock]$OnToggleTodaySpend,
            [Parameter()][AllowNull()][scriptblock]$OnRefresh,
            [Parameter()][AllowNull()][scriptblock]$OnManageRelays,
            [Parameter()][AllowNull()][scriptblock]$OnMoveRelayUp,
            [Parameter()][AllowNull()][scriptblock]$OnMoveRelayDown,
            [Parameter()][AllowNull()][scriptblock]$OnClosing
        )
        if ($state.Disposed) { return }
        $state.Callbacks = [pscustomobject][ordered]@{
            OnSetDisplayMode = $OnSetDisplayMode
            OnSetTheme = $OnSetTheme
            OnSetFullLayout = $OnSetFullLayout
            OnToggleTopmost = $OnToggleTopmost
            OnToggleStartup = $OnToggleStartup
            OnToggleTodaySpend = $OnToggleTodaySpend
            OnRefresh = $OnRefresh
            OnManageRelays = $OnManageRelays
            OnMoveRelayUp = $OnMoveRelayUp
            OnMoveRelayDown = $OnMoveRelayDown
            OnClosing = $OnClosing
        }
    }.GetNewClosure()

    $dispose = {
        if ($state.Disposed) { return }
        $state.Disposed = $true
        try { & $detachRelayOrderHandlers } catch { }
        try { $window.remove_Closing($state.Delegates.Closing) } catch { }
        foreach ($name in @($state.Delegates.Keys)) {
            if ($name -eq 'Closing') { continue }
            if (-not $state.Controls.Contains($name)) { continue }
            try { $state.Controls[$name].remove_Click($state.Delegates[$name]) } catch { }
        }
        $state.Delegates.Clear()
        $state.Callbacks = $null
        try { $window.Close() } catch { }
    }.GetNewClosure()

    & $setPage 'Appearance'

    return [pscustomobject][ordered]@{
        Window = $window
        Controls = $controls
        State = $state
        ShowDialog = $showDialog
        SetPage = $setPage
        SetSnapshot = $setSnapshot
        SetRelayOrder = $setRelayOrder
        SetStatus = $setStatus
        SetCallbacks = $setCallbacks
        Dispose = $dispose
    }
}
