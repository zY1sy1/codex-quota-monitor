BeforeAll {
    if ([string]::IsNullOrEmpty($env:windir) -and -not [string]::IsNullOrEmpty($env:SystemRoot)) {
        $env:windir = $env:SystemRoot
    }
    $script:CompanionRoot = Join-Path $PSScriptRoot '..\..\companion'
    $script:XamlPath = Join-Path $script:CompanionRoot 'UI\Settings.xaml'
    $script:ViewPath = Join-Path $script:CompanionRoot 'Private\SettingsView.ps1'
    $script:IconPath = Join-Path $script:CompanionRoot 'Private\WindowIcon.ps1'
    if (Test-Path -LiteralPath $script:IconPath -PathType Leaf) { . $script:IconPath }
    if (Test-Path -LiteralPath $script:ViewPath -PathType Leaf) { . $script:ViewPath }
}

Describe 'settings window composition' {
    BeforeEach {
        $script:Calls = [Collections.Generic.List[string]]::new()
        $script:View = New-SettingsView
        & $script:View.SetCallbacks `
            -OnSetDisplayMode { param($value) $script:Calls.Add("mode:$value") } `
            -OnSetTheme { param($value) $script:Calls.Add("theme:$value") } `
            -OnSetFullLayout { param($value) $script:Calls.Add("layout:$value") } `
            -OnToggleTopmost { $script:Calls.Add('topmost') } `
            -OnToggleStartup { $script:Calls.Add('startup') } `
            -OnRefresh { $script:Calls.Add('refresh') } `
            -OnManageRelays { $script:Calls.Add('relays') } `
            -OnClosing { $script:Calls.Add('closing') }
    }

    AfterEach {
        if ($null -ne $script:View -and -not $script:View.State.Disposed) {
            & $script:View.Dispose
        }
    }

    It 'requires an STA thread and loads every named settings control' {
        [Threading.Thread]::CurrentThread.GetApartmentState().ToString() | Should -BeExactly 'STA'
        $View.Window | Should -BeOfType ([Windows.Window])
        $View.Window.Title | Should -BeExactly '设置'
        foreach ($name in @(
            'DisplayModeGroup', 'FullModeRadio', 'CompactBarModeRadio', 'OrbModeRadio',
            'ThemeGroup', 'LightThemeRadio', 'DarkThemeRadio',
            'FullLayoutGroup', 'OverviewLayoutRadio', 'TabsLayoutRadio',
            'TopmostCheckBox', 'StartupCheckBox', 'RefreshButton', 'ManageRelaysButton',
            'StatusText'
        )) {
            $View.Controls[$name] | Should -Not -BeNullOrEmpty
        }
    }

    It 'localizes fixed interface text and display-mode tags' {
        $View.Controls.FullModeRadio.Content | Should -BeExactly '完整窗口'
        $View.Controls.CompactBarModeRadio.Content | Should -BeExactly '迷你条'
        $View.Controls.OrbModeRadio.Content | Should -BeExactly '额度球'
        $View.Controls.LightThemeRadio.Content | Should -BeExactly '浅色透明'
        $View.Controls.DarkThemeRadio.Content | Should -BeExactly '深色透明'
        $View.Controls.OverviewLayoutRadio.Content | Should -BeExactly '总览折叠'
        $View.Controls.TabsLayoutRadio.Content | Should -BeExactly '标签切换'
        $View.Controls.TopmostCheckBox.Content | Should -BeExactly '始终置顶'
        $View.Controls.StartupCheckBox.Content | Should -BeExactly '开机启动'
        $View.Controls.RefreshButton.Content | Should -BeExactly '立即刷新'
        $View.Controls.ManageRelaysButton.Content | Should -BeExactly '管理中转站'
        [string]$View.Controls.FullModeRadio.GroupName | Should -BeExactly 'DisplayModeGroup'
        [string]$View.Controls.OrbModeRadio.Tag | Should -BeExactly 'Orb'
        [string]$View.Controls.LightThemeRadio.Tag | Should -BeExactly 'Light'
        [string]$View.Controls.TabsLayoutRadio.Tag | Should -BeExactly 'Tabs'
    }

    It 'applies the application icon to the settings window' {
        $icon = Get-MonitorAppIconPath
        if ($null -eq $icon) {
            Set-ItResult -Skipped -Because 'no icon asset in this workspace layout'
        }
        $View.Window.Icon | Should -Not -BeNullOrEmpty
    }

    It 'renders a snapshot without invoking any action callbacks' {
        & $View.SetSnapshot -Mode Orb -Theme Light -FullLayout Tabs -Topmost $true -Startup $false

        $View.Controls.FullModeRadio.IsChecked | Should -BeFalse
        $View.Controls.CompactBarModeRadio.IsChecked | Should -BeFalse
        $View.Controls.OrbModeRadio.IsChecked | Should -BeTrue
        $View.Controls.LightThemeRadio.IsChecked | Should -BeTrue
        $View.Controls.DarkThemeRadio.IsChecked | Should -BeFalse
        $View.Controls.OverviewLayoutRadio.IsChecked | Should -BeFalse
        $View.Controls.TabsLayoutRadio.IsChecked | Should -BeTrue
        $View.Controls.TopmostCheckBox.IsChecked | Should -BeTrue
        $View.Controls.StartupCheckBox.IsChecked | Should -BeFalse
        $View.Controls.StatusText.Text | Should -BeExactly ''
        @($script:Calls) | Should -Be @()
    }

    It 'routes radio clicks by tag and checkbox toggles exactly once' {
        & $View.SetSnapshot -Mode Full -Theme Dark -FullLayout Overview -Topmost $false -Startup $false

        $View.Controls.CompactBarModeRadio.RaiseEvent(
            [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
        )
        $View.Controls.LightThemeRadio.RaiseEvent(
            [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
        )
        $View.Controls.TabsLayoutRadio.RaiseEvent(
            [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
        )
        $View.Controls.TopmostCheckBox.RaiseEvent(
            [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
        )
        $View.Controls.StartupCheckBox.RaiseEvent(
            [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
        )
        $View.Controls.RefreshButton.RaiseEvent(
            [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
        )
        $View.Controls.ManageRelaysButton.RaiseEvent(
            [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
        )

        @($script:Calls) | Should -Be @(
            'mode:CompactBar', 'theme:Light', 'layout:Tabs',
            'topmost', 'startup', 'refresh', 'relays'
        )
    }

    It 'sets the status text without touching the snapshot' {
        & $View.SetStatus '已请求刷新。'
        $View.Controls.StatusText.Text | Should -BeExactly '已请求刷新。'
    }

    It 'cancels ordinary closing and hides the window for reuse' {
        $View.Window.Show()
        $View.Window.Close()

        $View.Window.IsVisible | Should -BeFalse
        $View.Window.IsLoaded | Should -BeTrue
        @($script:Calls) | Should -Be @('closing')
    }

    It 'disposes idempotently and clears callbacks' {
        { & $View.Dispose; & $View.Dispose } | Should -Not -Throw

        $View.State.Disposed | Should -BeTrue
        $View.State.Callbacks | Should -BeNullOrEmpty
    }
}
