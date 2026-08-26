if (-not (Get-Command Get-MonitorAppIconPath -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'WindowIcon.ps1')
}

function New-SettingsView {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$XamlPath = (Join-Path $PSScriptRoot '..\UI\Settings.xaml')
    )

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'The settings window requires an STA thread.'
    }
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
    if ($window -isnot [Windows.Window]) { throw 'Settings XAML root must be a Window.' }

    $windowIcon = ConvertTo-MonitorWindowIconSource (Get-MonitorAppIconPath)
    if ($null -ne $windowIcon) {
        $window.Icon = $windowIcon
    }

    $controlNames = @(
        'DisplayModeGroup', 'FullModeRadio', 'CompactBarModeRadio', 'OrbModeRadio',
        'ThemeGroup', 'LightThemeRadio', 'DarkThemeRadio',
        'FullLayoutGroup', 'OverviewLayoutRadio', 'TabsLayoutRadio',
        'TopmostCheckBox', 'StartupCheckBox', 'RefreshButton', 'ManageRelaysButton',
        'StatusText'
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
        Delegates = [ordered]@{}
    }

    $invoke = {
        param([string]$Name, [object[]]$Arguments)
        if ($state.Disposed -or $null -eq $state.Callbacks) { return $null }
        $callback = $state.Callbacks.PSObject.Properties[$Name]
        if ($null -ne $callback -and $null -ne $callback.Value) { return & $callback.Value @Arguments }
        return $null
    }.GetNewClosure()

    foreach ($definition in @(
        @{ Control = 'FullModeRadio'; Callback = 'OnSetDisplayMode'; Tag = 'Full' },
        @{ Control = 'CompactBarModeRadio'; Callback = 'OnSetDisplayMode'; Tag = 'CompactBar' },
        @{ Control = 'OrbModeRadio'; Callback = 'OnSetDisplayMode'; Tag = 'Orb' },
        @{ Control = 'LightThemeRadio'; Callback = 'OnSetTheme'; Tag = 'Light' },
        @{ Control = 'DarkThemeRadio'; Callback = 'OnSetTheme'; Tag = 'Dark' },
        @{ Control = 'OverviewLayoutRadio'; Callback = 'OnSetFullLayout'; Tag = 'Overview' },
        @{ Control = 'TabsLayoutRadio'; Callback = 'OnSetFullLayout'; Tag = 'Tabs' }
    )) {
        $callbackName = $definition.Callback
        $tagValue = [string]$definition.Tag
        $handler = [Windows.RoutedEventHandler]{
            param($sender, $args)
            $null = & $invoke $callbackName @($tagValue)
        }.GetNewClosure()
        $state.Delegates[$definition.Control] = $handler
        $controls[$definition.Control].Add_Click($handler)
    }

    foreach ($definition in @(
        @{ Control = 'TopmostCheckBox'; Callback = 'OnToggleTopmost' },
        @{ Control = 'StartupCheckBox'; Callback = 'OnToggleStartup' },
        @{ Control = 'RefreshButton'; Callback = 'OnRefresh' },
        @{ Control = 'ManageRelaysButton'; Callback = 'OnManageRelays' }
    )) {
        $callbackName = $definition.Callback
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
            $null = & $invoke 'OnClosing'
            $state.Window.Hide()
        }
    }.GetNewClosure()
    $state.Delegates.Closing = $closing
    $window.Add_Closing($closing)

    $showDialog = { if (-not $state.Disposed) { return $state.Window.ShowDialog() } }.GetNewClosure()

    $setSnapshot = {
        param(
            [string]$Mode,
            [string]$Theme,
            [string]$FullLayout,
            [bool]$Topmost,
            [bool]$Startup
        )
        if ($state.Disposed) { return }
        $modeControl = switch ($Mode) {
            'CompactBar' { $state.Controls.CompactBarModeRadio }
            'Orb' { $state.Controls.OrbModeRadio }
            default { $state.Controls.FullModeRadio }
        }
        $themeControl = if ($Theme -eq 'Light') { $state.Controls.LightThemeRadio } else { $state.Controls.DarkThemeRadio }
        $layoutControl = if ($FullLayout -eq 'Tabs') { $state.Controls.TabsLayoutRadio } else { $state.Controls.OverviewLayoutRadio }
        $state.Controls.FullModeRadio.IsChecked = $false
        $state.Controls.CompactBarModeRadio.IsChecked = $false
        $state.Controls.OrbModeRadio.IsChecked = $false
        $state.Controls.LightThemeRadio.IsChecked = $false
        $state.Controls.DarkThemeRadio.IsChecked = $false
        $state.Controls.OverviewLayoutRadio.IsChecked = $false
        $state.Controls.TabsLayoutRadio.IsChecked = $false
        $modeControl.IsChecked = $true
        $themeControl.IsChecked = $true
        $layoutControl.IsChecked = $true
        $state.Controls.TopmostCheckBox.IsChecked = $Topmost
        $state.Controls.StartupCheckBox.IsChecked = $Startup
        $state.Controls.StatusText.Text = [string]::Empty
    }.GetNewClosure()

    $setStatus = {
        param([string]$Message)
        if ($state.Disposed) { return }
        $state.Controls.StatusText.Text = $Message
    }.GetNewClosure()

    $setCallbacks = {
        param(
            [Parameter()][AllowNull()][scriptblock]$OnSetDisplayMode,
            [Parameter()][AllowNull()][scriptblock]$OnSetTheme,
            [Parameter()][AllowNull()][scriptblock]$OnSetFullLayout,
            [Parameter()][AllowNull()][scriptblock]$OnToggleTopmost,
            [Parameter()][AllowNull()][scriptblock]$OnToggleStartup,
            [Parameter()][AllowNull()][scriptblock]$OnRefresh,
            [Parameter()][AllowNull()][scriptblock]$OnManageRelays,
            [Parameter()][AllowNull()][scriptblock]$OnClosing
        )
        if ($state.Disposed) { return }
        $state.Callbacks = [pscustomobject][ordered]@{
            OnSetDisplayMode = $OnSetDisplayMode
            OnSetTheme = $OnSetTheme
            OnSetFullLayout = $OnSetFullLayout
            OnToggleTopmost = $OnToggleTopmost
            OnToggleStartup = $OnToggleStartup
            OnRefresh = $OnRefresh
            OnManageRelays = $OnManageRelays
            OnClosing = $OnClosing
        }
    }.GetNewClosure()

    $dispose = {
        if ($state.Disposed) { return }
        $state.Disposed = $true
        try { $window.remove_Closing($state.Delegates.Closing) } catch { }
        foreach ($name in $state.Delegates.Keys) {
            if ($name -eq 'Closing') { continue }
            try { $state.Controls[$name].remove_Click($state.Delegates[$name]) } catch { }
        }
        $state.Delegates.Clear()
        $state.Callbacks = $null
        try { $window.Close() } catch { }
    }.GetNewClosure()

    return [pscustomobject][ordered]@{
        Window = $window
        Controls = $controls
        State = $state
        ShowDialog = $showDialog
        SetSnapshot = $setSnapshot
        SetStatus = $setStatus
        SetCallbacks = $setCallbacks
        Dispose = $dispose
    }
}
