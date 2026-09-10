if (-not (Get-Command Get-MonitorAppIconPath -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'WindowIcon.ps1')
}
if (-not (Get-Command Set-SettingsWindowTheme -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Theme.ps1')
}

# Drag-to-reorder arithmetic, kept pure so it can be tested without a mouse.
# RowCenters are the vertical midpoints of the rows in their current on-screen
# order. The dragged row lands wherever the cursor has passed the midpoint of
# the row above it, so the answer is simply how many *other* rows the cursor has
# moved past — which is already the index to insert at once the dragged row has
# been removed from the panel.
function Get-RelayOrderDropIndex {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][double[]]$RowCenters,
        [Parameter(Mandatory)][double]$CursorY,
        [Parameter(Mandatory)][int]$DraggedIndex
    )
    $target = 0
    for ($index = 0; $index -lt $RowCenters.Count; $index++) {
        if ($index -eq $DraggedIndex) { continue }
        if ($RowCenters[$index] -lt $CursorY) { $target++ }
    }
    return $target
}

function Test-SettingsOrderPressOnButton {
    param([AllowNull()][object]$Source)
    $current = $Source
    while ($null -ne $current) {
        if ($current -is [Windows.Controls.Button]) { return $true }
        if ($current -isnot [Windows.Media.Visual]) { return $false }
        $current = [Windows.Media.VisualTreeHelper]::GetParent($current)
    }
    return $false
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
        DragRow = $null
        DragProviderId = $null
        DragFromIndex = -1
        DragStartY = 0
        DragActive = $false
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

    # Rows carry their own bottom hairline so the panel children map one-to-one
    # onto providers; that identity is what makes the drag index math trivial.
    $applyOrderSeparators = {
        $panel = $state.Controls.RelayOrderList
        $children = @($panel.Children)
        for ($index = 0; $index -lt $children.Count; $index++) {
            $target = if ($index -lt ($children.Count - 1)) {
                [Windows.Thickness]::new(0, 0, 0, 1)
            }
            else {
                [Windows.Thickness]::new(0)
            }
            if ($children[$index].BorderThickness -ne $target) {
                $children[$index].BorderThickness = $target
            }
        }
    }.GetNewClosure()

    $resetRelayDrag = {
        if ($null -ne $state.DragRow) {
            try { $state.DragRow.Opacity = 1 } catch { }
            try {
                $state.DragRow.SetResourceReference(
                    [Windows.Controls.Border]::BorderBrushProperty, 'SettingsSeparatorBrush'
                )
            }
            catch { }
        }
        $state.DragRow = $null
        $state.DragProviderId = $null
        $state.DragFromIndex = -1
        $state.DragStartY = 0
        $state.DragActive = $false
    }.GetNewClosure()

    $detachRelayOrderHandlers = {
        foreach ($entry in @($state.RelayOrderHandlers)) {
            try {
                if ($entry.Kind -eq 'Mouse') {
                    $entry.Control.Remove_MouseLeftButtonDown($entry.Handler)
                }
                else {
                    $entry.Control.Remove_Click($entry.Handler)
                }
            }
            catch { }
        }
        $state.RelayOrderHandlers.Clear()
        & $resetRelayDrag
        $state.Controls.RelayOrderList.Children.Clear()
    }.GetNewClosure()

    # One styled row per provider, in display order. The label carries the
    # 已停用 tag because a disabled provider is invisible in the floating
    # window, so this list is the only place the state shows up. Rows are
    # dragged to reorder, with the arrows kept for precise and keyboard use.
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
            $providerId = [string](& $getField $provider 'Id')
            $displayName = [string](& $getField $provider 'Name')
            if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $providerId }
            $isEnabled = [bool](& $getField $provider 'Enabled')

            $row = [Windows.Controls.Border]::new()
            $row.Style = $resources['OrderRowStyle']
            # Dynamic references rather than captured brush objects, so the rows
            # re-theme with the window instead of freezing the colours they were
            # built with.
            $row.SetResourceReference(
                [Windows.Controls.Border]::BorderBrushProperty, 'SettingsSeparatorBrush'
            )
            $row.Cursor = [Windows.Input.Cursors]::SizeAll
            $row.ToolTip = "拖动「$displayName」调整顺序"
            [Windows.Automation.AutomationProperties]::SetName(
                $row, "中转站第 $($index + 1) 位：$displayName"
            )
            $grid = [Windows.Controls.Grid]::new()
            $gripColumn = [Windows.Controls.ColumnDefinition]::new()
            $gripColumn.Width = [Windows.GridLength]::Auto
            $ordinalColumn = [Windows.Controls.ColumnDefinition]::new()
            $ordinalColumn.Width = [Windows.GridLength]::new([double]22)
            $labelColumn = [Windows.Controls.ColumnDefinition]::new()
            $labelColumn.Width = [Windows.GridLength]::new([double]1, [Windows.GridUnitType]::Star)
            $buttonColumn = [Windows.Controls.ColumnDefinition]::new()
            $buttonColumn.Width = [Windows.GridLength]::Auto
            foreach ($column in @($gripColumn, $ordinalColumn, $labelColumn, $buttonColumn)) {
                $grid.ColumnDefinitions.Add($column)
            }

            $grip = [Windows.Shapes.Path]::new()
            $grip.Data = [Windows.Media.Geometry]::Parse(
                'M1,2 H3.4 M1,5 H3.4 M1,8 H3.4 M6.6,2 H9 M6.6,5 H9 M6.6,8 H9'
            )
            $grip.StrokeThickness = 1.3
            $grip.StrokeStartLineCap = [Windows.Media.PenLineCap]::Round
            $grip.StrokeEndLineCap = [Windows.Media.PenLineCap]::Round
            $grip.SetResourceReference(
                [Windows.Shapes.Shape]::StrokeProperty, 'SettingsTextSecondaryBrush'
            )
            $grip.Width = 10
            $grip.Height = 10
            $grip.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
            $grip.Opacity = 0.65
            $grip.VerticalAlignment = [Windows.VerticalAlignment]::Center
            $grip.IsHitTestVisible = $false
            [Windows.Controls.Grid]::SetColumn($grip, 0)
            $null = $grid.Children.Add($grip)

            $ordinal = [Windows.Controls.TextBlock]::new()
            $ordinal.Text = [string]($index + 1)
            $ordinal.FontSize = 11
            $ordinal.SetResourceReference(
                [Windows.Controls.TextBlock]::ForegroundProperty, 'SettingsTextSecondaryBrush'
            )
            $ordinal.VerticalAlignment = [Windows.VerticalAlignment]::Center
            [Windows.Controls.Grid]::SetColumn($ordinal, 1)
            $null = $grid.Children.Add($ordinal)

            $label = [Windows.Controls.TextBlock]::new()
            $label.Text = $displayName
            $label.FontSize = 13
            $label.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
            $label.VerticalAlignment = [Windows.VerticalAlignment]::Center
            $label.SetResourceReference(
                [Windows.Controls.TextBlock]::ForegroundProperty, $(if ($isEnabled) {
                    'SettingsTextPrimaryBrush'
                }
                else {
                    'SettingsTextSecondaryBrush'
                })
            )
            $labelRow = [Windows.Controls.StackPanel]::new()
            $labelRow.Orientation = [Windows.Controls.Orientation]::Horizontal
            $null = $labelRow.Children.Add($label)
            if (-not $isEnabled) {
                $tag = [Windows.Controls.Border]::new()
                $tag.Margin = [Windows.Thickness]::new(8, 0, 0, 0)
                $tag.Padding = [Windows.Thickness]::new(6, 1, 6, 1)
                $tag.CornerRadius = [Windows.CornerRadius]::new(3)
                $tag.BorderThickness = [Windows.Thickness]::new(1)
                $tag.SetResourceReference(
                    [Windows.Controls.Border]::BorderBrushProperty, 'SettingsSeparatorBrush'
                )
                $tag.SetResourceReference(
                    [Windows.Controls.Border]::BackgroundProperty, 'SettingsSidebarBrush'
                )
                $tag.VerticalAlignment = [Windows.VerticalAlignment]::Center
                $tagText = [Windows.Controls.TextBlock]::new()
                $tagText.Text = '已停用'
                $tagText.FontSize = 10
                $tagText.SetResourceReference(
                    [Windows.Controls.TextBlock]::ForegroundProperty, 'SettingsTextSecondaryBrush'
                )
                $tag.Child = $tagText
                $null = $labelRow.Children.Add($tag)
            }
            [Windows.Controls.Grid]::SetColumn($labelRow, 2)
            $null = $grid.Children.Add($labelRow)

            $buttons = [Windows.Controls.StackPanel]::new()
            $buttons.Orientation = [Windows.Controls.Orientation]::Horizontal
            $buttons.VerticalAlignment = [Windows.VerticalAlignment]::Center
            foreach ($definition in @(
                @{ Action = '上移'; Offset = -1; Data = 'M2.6,7.4 L5.8,4.2 L9,7.4'
                   Enabled = ($index -gt 0) }
                @{ Action = '下移'; Offset = 1; Data = 'M2.6,4.6 L5.8,7.8 L9,4.6'
                   Enabled = ($index -lt ($items.Count - 1)) }
            )) {
                $actionName = [string]$definition.Action
                $rowOffset = [int]$definition.Offset
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
                    $null = & $invokeForRows 'OnMoveRelay' @($providerId, $rowOffset)
                }.GetNewClosure()
                $state.RelayOrderHandlers.Add([pscustomobject][ordered]@{
                    Control = $button; Handler = $handler; Kind = 'Click'
                })
                $button.Add_Click($handler)
                $null = $buttons.Children.Add($button)
            }
            [Windows.Controls.Grid]::SetColumn($buttons, 3)
            $null = $grid.Children.Add($buttons)

            $row.Child = $grid
            $pressHandler = [Windows.Input.MouseButtonEventHandler]{
                param($sender, $eventArgs)
                if ($state.Disposed -or $null -ne $state.DragRow) { return }
                # ButtonBase marks its own press handled, but a future layout
                # change could put a press back on the row; never drag from it.
                if (Test-SettingsOrderPressOnButton -Source $eventArgs.OriginalSource) { return }
                $state.DragRow = $row
                $state.DragProviderId = $providerId
                $state.DragFromIndex = $index
                $state.DragStartY = $eventArgs.GetPosition($panel).Y
                $state.DragActive = $false
                $null = $panel.CaptureMouse()
                $eventArgs.Handled = $true
            }.GetNewClosure()
            $state.RelayOrderHandlers.Add([pscustomobject][ordered]@{
                Control = $row; Handler = $pressHandler; Kind = 'Mouse'
            })
            $row.Add_MouseLeftButtonDown($pressHandler)
            $null = $panel.Children.Add($row)
        }
        & $applyOrderSeparators
    }.GetNewClosure()

    $relayOrderMouseMove = [Windows.Input.MouseEventHandler]{
        param($sender, $eventArgs)
        if ($state.Disposed -or $null -eq $state.DragRow) { return }
        $panel = $state.Controls.RelayOrderList
        $position = $eventArgs.GetPosition($panel)
        if (-not $state.DragActive) {
            if ([Math]::Abs($position.Y - $state.DragStartY) -lt 4) { return }
            $state.DragActive = $true
            $state.DragRow.Opacity = 0.55
            $state.DragRow.SetResourceReference(
                [Windows.Controls.Border]::BorderBrushProperty, 'SettingsAccentBrush'
            )
        }
        $current = $panel.Children.IndexOf($state.DragRow)
        if ($current -lt 0) { return }
        $children = @($panel.Children)
        $centers = [Collections.Generic.List[double]]::new()
        for ($index = 0; $index -lt $children.Count; $index++) {
            $top = $children[$index].TranslatePoint([Windows.Point]::new(0, 0), $panel).Y
            $centers.Add($top + ($children[$index].ActualHeight / 2))
        }
        $target = Get-RelayOrderDropIndex -RowCenters $centers.ToArray() `
            -CursorY $position.Y -DraggedIndex $current
        if ($target -ne $current -and $target -ge 0 -and $target -lt $children.Count) {
            $panel.Children.RemoveAt($current)
            $panel.Children.Insert($target, $state.DragRow)
            & $applyOrderSeparators
        }
    }.GetNewClosure()

    $relayOrderMouseUp = [Windows.Input.MouseButtonEventHandler]{
        param($sender, $eventArgs)
        if ($state.Disposed) { return }
        if ($null -eq $state.DragRow) { return }
        $panel = $state.Controls.RelayOrderList
        if ($panel.IsMouseCaptured) { $panel.ReleaseMouseCapture() }
        $row = $state.DragRow
        $providerId = [string]$state.DragProviderId
        $fromIndex = [int]$state.DragFromIndex
        $wasDragging = [bool]$state.DragActive
        $toIndex = $panel.Children.IndexOf($row)
        & $resetRelayDrag
        if ($wasDragging -and $toIndex -ge 0 -and $toIndex -ne $fromIndex) {
            $null = & $invoke 'OnMoveRelay' @($providerId, ($toIndex - $fromIndex))
        }
    }.GetNewClosure()

    $relayOrderLostCapture = [Windows.Input.MouseEventHandler]{
        param($sender, $eventArgs)
        if ($state.Disposed) { return }
        & $resetRelayDrag
    }.GetNewClosure()

    $state.Delegates.RelayOrderMouseMove = $relayOrderMouseMove
    $state.Delegates.RelayOrderMouseUp = $relayOrderMouseUp
    $state.Delegates.RelayOrderLostCapture = $relayOrderLostCapture
    $controls.RelayOrderList.Add_MouseMove($relayOrderMouseMove)
    $controls.RelayOrderList.Add_MouseLeftButtonUp($relayOrderMouseUp)
    $controls.RelayOrderList.Add_LostMouseCapture($relayOrderLostCapture)

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
            [Parameter()][AllowNull()][scriptblock]$OnMoveRelay,
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
            OnMoveRelay = $OnMoveRelay
            OnClosing = $OnClosing
        }
    }.GetNewClosure()

    $dispose = {
        if ($state.Disposed) { return }
        $state.Disposed = $true
        try { & $detachRelayOrderHandlers } catch { }
        try { $controls.RelayOrderList.Remove_MouseMove($state.Delegates.RelayOrderMouseMove) } catch { }
        try {
            $controls.RelayOrderList.Remove_MouseLeftButtonUp($state.Delegates.RelayOrderMouseUp)
        }
        catch { }
        try {
            $controls.RelayOrderList.Remove_LostMouseCapture($state.Delegates.RelayOrderLostCapture)
        }
        catch { }
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
