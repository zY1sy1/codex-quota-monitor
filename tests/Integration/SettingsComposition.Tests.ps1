BeforeAll {
    if ([string]::IsNullOrEmpty($env:windir) -and -not [string]::IsNullOrEmpty($env:SystemRoot)) {
        $env:windir = $env:SystemRoot
    }
    $script:CompanionRoot = Join-Path $PSScriptRoot '..\..\companion'
    $script:XamlPath = Join-Path $script:CompanionRoot 'UI\Settings.xaml'
    $script:ThemePath = Join-Path $script:CompanionRoot 'Private\Theme.ps1'
    $script:ViewPath = Join-Path $script:CompanionRoot 'Private\SettingsView.ps1'
    $script:IconPath = Join-Path $script:CompanionRoot 'Private\WindowIcon.ps1'
    if (Test-Path -LiteralPath $script:ThemePath -PathType Leaf) { . $script:ThemePath }
    if (Test-Path -LiteralPath $script:IconPath -PathType Leaf) { . $script:IconPath }
    if (Test-Path -LiteralPath $script:ViewPath -PathType Leaf) { . $script:ViewPath }

    function Get-RelayOrderRow {
        param($Panel)
        return @(
            $Panel.Children | Where-Object {
                $_ -is [Windows.Controls.Border] -and $null -ne $_.Child
            }
        )
    }

    function Get-RelayOrderRowParts {
        param($Row)
        $grid = $Row.Child
        [pscustomobject]@{
            Grip = @(
                $grid.Children | Where-Object { [Windows.Controls.Grid]::GetColumn($_) -eq 0 }
            )[0]
            Ordinal = @(
                $grid.Children | Where-Object { [Windows.Controls.Grid]::GetColumn($_) -eq 1 }
            )[0]
            Label = @(
                $grid.Children | Where-Object { [Windows.Controls.Grid]::GetColumn($_) -eq 2 }
            )[0]
            Buttons = @(
                $grid.Children | Where-Object { [Windows.Controls.Grid]::GetColumn($_) -eq 3 }
            )[0]
        }
    }
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
            -OnMoveRelay { param($value, $offset) $script:Calls.Add("relay:$value/$offset") } `
            -OnClosing { $script:Calls.Add('closing') }
    }

    AfterEach {
        if ($null -ne $script:View -and -not $script:View.State.Disposed) {
            & $script:View.Dispose
        }
    }

    It 'loads the resizable three-page settings center shell' {
        [Threading.Thread]::CurrentThread.GetApartmentState().ToString() |
            Should -BeExactly 'STA'
        $View.Window | Should -BeOfType ([Windows.Window])
        $View.Window.Title | Should -BeExactly '设置'
        $View.Window.Width | Should -Be 720
        $View.Window.Height | Should -Be 520
        $View.Window.MinWidth | Should -Be 640
        $View.Window.MinHeight | Should -Be 460
        $View.Window.SizeToContent | Should -Be ([Windows.SizeToContent]::Manual)
        foreach ($name in @(
            'RootGrid', 'SidebarBorder',
            'AppearanceNavRadio', 'BehaviorNavRadio', 'RelayNavRadio',
            'AppearancePage', 'BehaviorPage', 'RelayPage',
            'DisplayModeGroup', 'FullModeRadio', 'CompactBarModeRadio', 'OrbModeRadio',
            'ThemeGroup', 'LightThemeRadio', 'DarkThemeRadio',
            'FullLayoutGroup', 'OverviewLayoutRadio', 'TabsLayoutRadio',
            'LayoutAvailabilityText', 'TopmostCheckBox', 'StartupCheckBox',
            'TodaySpendCheckBox',
            'RefreshButton', 'ManageRelaysButton', 'StatusText'
        )) {
            $View.Controls[$name] | Should -Not -BeNullOrEmpty
        }
    }

    It 'shows only implemented navigation pages with exact Chinese text' {
        $View.Controls.AppearanceNavRadio.Content | Should -BeExactly '外观'
        $View.Controls.BehaviorNavRadio.Content | Should -BeExactly '行为'
        $View.Controls.RelayNavRadio.Content | Should -BeExactly '中转站'
        $View.Controls.FullModeRadio.Content | Should -BeExactly '完整窗口'
        $View.Controls.CompactBarModeRadio.Content | Should -BeExactly '迷你条'
        $View.Controls.OrbModeRadio.Content | Should -BeExactly '额度球'
        $View.Controls.LightThemeRadio.Content.Children[1].Text |
            Should -BeExactly '浅色透明'
        $View.Controls.DarkThemeRadio.Content.Children[1].Text |
            Should -BeExactly '深色透明'
        $View.Controls.OverviewLayoutRadio.Content | Should -BeExactly '总览折叠'
        $View.Controls.TabsLayoutRadio.Content | Should -BeExactly '标签切换'
        $View.Controls.RefreshButton.Content | Should -BeExactly '立即刷新额度'
        $View.Controls.ManageRelaysButton.Content | Should -BeExactly '打开中转站管理器'

        $raw = [IO.File]::ReadAllText($script:XamlPath)
        $raw | Should -Not -Match '诊断|关于|AutoQueryIntervalTextBox|自动查询间隔'
    }

    It 'applies the application icon to the settings window' {
        $icon = Get-MonitorAppIconPath
        if ($null -eq $icon) {
            Set-ItResult -Skipped -Because 'no icon asset in this workspace layout'
        }
        $View.Window.Icon | Should -Not -BeNullOrEmpty
    }

    It 'switches pages locally without invoking runtime callbacks' {
        $View.State.CurrentPage | Should -BeExactly 'Appearance'
        $View.Controls.AppearanceNavRadio.IsChecked | Should -BeTrue
        $View.Controls.AppearancePage.Visibility | Should -Be ([Windows.Visibility]::Visible)

        & $View.SetPage 'Behavior'
        $View.Controls.AppearancePage.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
        $View.Controls.BehaviorPage.Visibility | Should -Be ([Windows.Visibility]::Visible)
        $View.Controls.RelayPage.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
        $View.Controls.BehaviorNavRadio.IsChecked | Should -BeTrue

        $View.Controls.RelayNavRadio.RaiseEvent(
            [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
        )
        $View.State.CurrentPage | Should -BeExactly 'Relay'
        $View.Controls.RelayPage.Visibility | Should -Be ([Windows.Visibility]::Visible)
        @($script:Calls) | Should -Be @()
    }

    It 'applies a dark compact snapshot without invoking callbacks' {
        & $View.SetSnapshot -Mode CompactBar -Theme Dark -FullLayout Tabs `
            -Topmost $true -Startup $false

        $View.Window.Tag | Should -BeExactly 'Dark'
        $View.Window.Resources['SettingsAccentBrush'].ToString() |
            Should -BeExactly '#FF58C2C7'
        $View.Controls.CompactBarModeRadio.IsChecked | Should -BeTrue
        $View.Controls.DarkThemeRadio.IsChecked | Should -BeTrue
        $View.Controls.TabsLayoutRadio.IsChecked | Should -BeTrue
        $View.Controls.OverviewLayoutRadio.IsEnabled | Should -BeFalse
        $View.Controls.TabsLayoutRadio.IsEnabled | Should -BeFalse
        $View.Controls.LayoutAvailabilityText.Text |
            Should -BeExactly '仅完整窗口模式可用'
        $View.Controls.TopmostCheckBox.IsChecked | Should -BeTrue
        $View.Controls.StartupCheckBox.IsChecked | Should -BeFalse
        $View.Controls.StatusText.Text | Should -BeExactly '更改即时保存'
        @($script:Calls) | Should -Be @()
    }

    It 'reenables full-window layout without losing the saved selection' {
        & $View.SetSnapshot -Mode CompactBar -Theme Light -FullLayout Tabs `
            -Topmost $false -Startup $false
        & $View.SetSnapshot -Mode Full -Theme Light -FullLayout Tabs `
            -Topmost $false -Startup $false

        $View.Controls.TabsLayoutRadio.IsChecked | Should -BeTrue
        $View.Controls.OverviewLayoutRadio.IsEnabled | Should -BeTrue
        $View.Controls.TabsLayoutRadio.IsEnabled | Should -BeTrue
    }

    It 'routes settings and commands exactly once while navigation stays local' {
        & $View.SetSnapshot -Mode Full -Theme Dark -FullLayout Overview `
            -Topmost $false -Startup $false

        foreach ($controlName in @(
            'CompactBarModeRadio', 'LightThemeRadio', 'TabsLayoutRadio',
            'TopmostCheckBox', 'StartupCheckBox', 'RefreshButton', 'ManageRelaysButton'
        )) {
            $View.Controls[$controlName].RaiseEvent(
                [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
            )
        }
        @($script:Calls) | Should -Be @(
            'mode:CompactBar', 'theme:Light', 'layout:Tabs',
            'topmost', 'startup', 'refresh', 'relays'
        )
    }

    It 'renders idle success and error statuses in a fixed live region' {
        & $View.SetStatus '设置已同步' 'Success'
        $View.Controls.StatusText.Text | Should -BeExactly '设置已同步'
        $View.Controls.StatusText.Foreground.ToString() | Should -BeExactly '#FF24757A'

        & $View.SetStatus '无法应用主题：测试错误' 'Error'
        $View.Controls.StatusText.Text | Should -BeExactly '无法应用主题：测试错误'
        $View.Controls.StatusText.Foreground.ToString() | Should -BeExactly '#FFB42323'
        [Windows.Automation.AutomationProperties]::GetLiveSetting($View.Controls.StatusText) |
            Should -Be ([Windows.Automation.AutomationLiveSetting]::Polite)
    }

    It 'gives every interactive settings control an automation name' {
        [xml]$xaml = Get-Content -LiteralPath $script:XamlPath -Raw
        $manager = [Xml.XmlNamespaceManager]::new($xaml.NameTable)
        $manager.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
        $manager.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
        foreach ($name in @(
            'AppearanceNavRadio', 'BehaviorNavRadio', 'RelayNavRadio',
            'FullModeRadio', 'CompactBarModeRadio', 'OrbModeRadio',
            'LightThemeRadio', 'DarkThemeRadio',
            'OverviewLayoutRadio', 'TabsLayoutRadio',
            'TopmostCheckBox', 'StartupCheckBox', 'TodaySpendCheckBox',
            'RefreshButton', 'ManageRelaysButton'
        )) {
            $node = $xaml.SelectSingleNode("//*[@x:Name='$name']", $manager)
            $node | Should -Not -BeNullOrEmpty
            $node.GetAttribute('AutomationProperties.Name') |
                Should -Not -BeNullOrEmpty
        }
    }

    It 'uses native focusable controls for navigation segments switches and commands' {
        foreach ($name in @(
            'AppearanceNavRadio', 'BehaviorNavRadio', 'RelayNavRadio',
            'FullModeRadio', 'CompactBarModeRadio', 'OrbModeRadio',
            'LightThemeRadio', 'DarkThemeRadio',
            'OverviewLayoutRadio', 'TabsLayoutRadio'
        )) {
            $View.Controls[$name] | Should -BeOfType ([Windows.Controls.RadioButton])
            $View.Controls[$name].Focusable | Should -BeTrue
            $View.Controls[$name].IsTabStop | Should -BeTrue
        }
        foreach ($name in @('TopmostCheckBox', 'StartupCheckBox')) {
            $View.Controls[$name] | Should -BeOfType ([Windows.Controls.CheckBox])
            $View.Controls[$name].Focusable | Should -BeTrue
            $View.Controls[$name].IsTabStop | Should -BeTrue
            $View.Controls[$name].Width | Should -BeGreaterOrEqual 48
            $View.Controls[$name].Height | Should -BeGreaterOrEqual 36
        }
        foreach ($name in @('RefreshButton', 'ManageRelaysButton')) {
            $View.Controls[$name] | Should -BeOfType ([Windows.Controls.Button])
            $View.Controls[$name].Focusable | Should -BeTrue
            $View.Controls[$name].IsTabStop | Should -BeTrue
        }
        $View.Controls.StatusText.Focusable | Should -BeFalse
    }

    It 'shares one visible theme-driven keyboard focus visual' {
        $focusStyle = $View.Window.Resources['SettingsFocusVisual']
        $focusStyle | Should -BeOfType ([Windows.Style])
        $templateSetter = @($focusStyle.Setters | Where-Object {
            $_.Property -eq [Windows.Controls.Control]::TemplateProperty
        })
        $templateSetter.Count | Should -Be 1
        $focusBorder = $templateSetter[0].Value.LoadContent()
        $focusBorder | Should -BeOfType ([Windows.Controls.Border])
        $focusBorder.BorderThickness.Left | Should -Be 1
        $brushReference = $focusBorder.ReadLocalValue(
            [Windows.Controls.Border]::BorderBrushProperty
        )
        $brushReference.ResourceKey | Should -BeExactly 'SettingsAccentBrush'

        foreach ($name in @(
            'AppearanceNavRadio', 'FullModeRadio', 'LightThemeRadio',
            'TopmostCheckBox', 'RefreshButton', 'ManageRelaysButton'
        )) {
            $View.Controls[$name].FocusVisualStyle | Should -Be $focusStyle
        }
    }

    It 'renders the relay display order with edge-aware move buttons and a disabled tag' {
        & $View.SetRelayOrder @(
            [pscustomobject]@{ Id = 'a'; Name = 'wakaka'; Enabled = $true }
            [pscustomobject]@{ Id = 'b'; Name = 'relay-b'; Enabled = $false }
            [pscustomobject]@{ Id = 'c'; Name = 'relay-c'; Enabled = $true }
        )

        $View.Controls.RelayOrderSurface.Visibility | Should -Be ([Windows.Visibility]::Visible)
        $View.Controls.RelayOrderEmptyText.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
        # one child per provider; rows carry their own hairline
        $View.Controls.RelayOrderList.Children.Count | Should -Be 3

        $rows = @(Get-RelayOrderRow -Panel $View.Controls.RelayOrderList)
        $rows.Count | Should -Be 3
        foreach ($row in $rows) {
            $row.Style | Should -Be $View.Window.Resources['OrderRowStyle']
        }
        # every row but the last draws the separating hairline
        @($rows | ForEach-Object { $_.BorderThickness.Bottom }) | Should -Be @(1, 1, 0)

        $first = Get-RelayOrderRowParts -Row $rows[0]
        $middle = Get-RelayOrderRowParts -Row $rows[1]
        $last = Get-RelayOrderRowParts -Row $rows[2]
        @($first.Label.Children[0].Text, $middle.Label.Children[0].Text, $last.Label.Children[0].Text) |
            Should -Be @('wakaka', 'relay-b', 'relay-c')
        @($first.Ordinal.Text, $middle.Ordinal.Text, $last.Ordinal.Text) |
            Should -Be @('1', '2', '3')
        @($first.Buttons.Children | ForEach-Object IsEnabled) | Should -Be @($false, $true)
        @($middle.Buttons.Children | ForEach-Object IsEnabled) | Should -Be @($true, $true)
        @($last.Buttons.Children | ForEach-Object IsEnabled) | Should -Be @($true, $false)
        foreach ($button in @($first.Buttons.Children) + @($last.Buttons.Children)) {
            $button.Style | Should -Be $View.Window.Resources['OrderMoveButtonStyle']
            $button.Content | Should -BeOfType ([Windows.Shapes.Path])
        }

        # the enabled provider carries no tag; the disabled one is called out
        $first.Label.Children.Count | Should -Be 1
        $middle.Label.Children.Count | Should -Be 2
        $middle.Label.Children[1].Child.Text | Should -BeExactly '已停用'
    }

    It 'makes every relay row a drag handle' {
        & $View.SetRelayOrder @(
            [pscustomobject]@{ Id = 'a'; Name = 'wakaka'; Enabled = $true }
            [pscustomobject]@{ Id = 'b'; Name = 'relay-b'; Enabled = $true }
        )

        $rows = @(Get-RelayOrderRow -Panel $View.Controls.RelayOrderList)
        foreach ($row in $rows) {
            $row.Cursor | Should -Be ([Windows.Input.Cursors]::SizeAll)
            $row.ToolTip | Should -BeLike '拖动*调整顺序'
            $parts = Get-RelayOrderRowParts -Row $row
            # the grip is decoration only, so presses reach the row
            $parts.Grip | Should -BeOfType ([Windows.Shapes.Path])
            $parts.Grip.IsHitTestVisible | Should -BeFalse
        }
        # two buttons plus the row press handler per row
        $View.State.RelayOrderHandlers.Count | Should -Be 6
        @($View.State.RelayOrderHandlers.Kind | Group-Object | ForEach-Object { $_.Name }) |
            Should -Be @('Click', 'Mouse')
    }

    It 'routes relay order buttons to their callbacks with the provider id and offset' {
        & $View.SetRelayOrder @(
            [pscustomobject]@{ Id = 'a'; Name = 'wakaka'; Enabled = $true }
            [pscustomobject]@{ Id = 'b'; Name = 'relay-b'; Enabled = $true }
        )
        $rows = @(Get-RelayOrderRow -Panel $View.Controls.RelayOrderList)
        $parts = Get-RelayOrderRowParts -Row $rows[1]
        [Windows.Automation.AutomationProperties]::GetName($parts.Buttons.Children[0]) |
            Should -BeExactly '上移中转站：relay-b'

        $parts.Buttons.Children[0].RaiseEvent(
            [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
        )
        $parts.Buttons.Children[1].RaiseEvent(
            [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
        )

        @($script:Calls) | Should -Be @('relay:b/-1', 'relay:b/1')
    }

    It 'replaces the relay order rows instead of accumulating their handlers' {
        $providers = @(
            [pscustomobject]@{ Id = 'a'; Name = 'wakaka'; Enabled = $true }
            [pscustomobject]@{ Id = 'b'; Name = 'relay-b'; Enabled = $true }
        )
        & $View.SetRelayOrder $providers
        & $View.SetRelayOrder $providers

        $View.State.RelayOrderHandlers.Count | Should -Be 6
        $View.Controls.RelayOrderList.Children.Count | Should -Be 2
    }

    It 'shows an empty hint instead of an empty relay surface' {
        & $View.SetRelayOrder @()

        $View.Controls.RelayOrderSurface.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
        $View.Controls.RelayOrderEmptyText.Visibility | Should -Be ([Windows.Visibility]::Visible)
        $View.Controls.RelayOrderList.Children.Count | Should -Be 0
        $View.State.RelayOrderHandlers.Count | Should -Be 0
    }

    It 'computes the drag drop index from row centers' -ForEach @(
        # four rows with centers at 20/60/100/140: the dragged row lands after
        # whichever midpoints the cursor has passed.
        @{ Centers = @(20, 60, 100, 140); Cursor = 5;   Dragged = 0; Expected = 0 }
        @{ Centers = @(20, 60, 100, 140); Cursor = 30;  Dragged = 0; Expected = 0 }
        @{ Centers = @(20, 60, 100, 140); Cursor = 70;  Dragged = 0; Expected = 1 }
        @{ Centers = @(20, 60, 100, 140); Cursor = 110; Dragged = 0; Expected = 2 }
        @{ Centers = @(20, 60, 100, 140); Cursor = 500; Dragged = 0; Expected = 3 }
        # dragging the last row up
        @{ Centers = @(20, 60, 100, 140); Cursor = 500; Dragged = 3; Expected = 3 }
        @{ Centers = @(20, 60, 100, 140); Cursor = 110; Dragged = 3; Expected = 3 }
        @{ Centers = @(20, 60, 100, 140); Cursor = 30;  Dragged = 3; Expected = 1 }
        @{ Centers = @(20, 60, 100, 140); Cursor = 10;  Dragged = 3; Expected = 0 }
        # a single row can never move
        @{ Centers = @(20);              Cursor = 5;   Dragged = 0; Expected = 0 }
        @{ Centers = @(20);              Cursor = 900; Dragged = 0; Expected = 0 }
    ) {
        Get-RelayOrderDropIndex -RowCenters $Centers -CursorY $Cursor -DraggedIndex $Dragged |
            Should -Be $Expected
    }

    It 'keeps the dragged row in place while the cursor stays inside its own slot' {
        # the cursor has not reached the neighbour's midpoint yet
        Get-RelayOrderDropIndex -RowCenters @(20, 60, 100) -CursorY 65 -DraggedIndex 1 |
            Should -Be 1
        Get-RelayOrderDropIndex -RowCenters @(20, 60, 100) -CursorY 90 -DraggedIndex 1 |
            Should -Be 1
    }

    It 'persists the offset of a completed drag and clears the drag visuals' {
        & $View.SetRelayOrder @(
            [pscustomobject]@{ Id = 'a'; Name = 'wakaka'; Enabled = $true }
            [pscustomobject]@{ Id = 'b'; Name = 'relay-b'; Enabled = $true }
            [pscustomobject]@{ Id = 'c'; Name = 'relay-c'; Enabled = $true }
        )
        $panel = $View.Controls.RelayOrderList
        $rows = @(Get-RelayOrderRow -Panel $panel)
        $dragged = $rows[0]

        # the press and move handlers had picked row 0 up and carried it down
        $View.State.DragRow = $dragged
        $View.State.DragProviderId = 'a'
        $View.State.DragFromIndex = 0
        $View.State.DragActive = $true
        $dragged.Opacity = 0.55
        $dragged.BorderBrush = $View.Window.Resources['SettingsAccentBrush']
        $panel.Children.RemoveAt(0)
        $panel.Children.Insert(2, $dragged)

        $mouseUp = [Windows.Input.MouseButtonEventArgs]::new(
            [Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left
        )
        $View.State.Delegates.RelayOrderMouseUp.Invoke($panel, $mouseUp)

        @($script:Calls) | Should -Be @('relay:a/2')
        $View.State.DragRow | Should -BeNullOrEmpty
        $View.State.DragActive | Should -BeFalse
        $dragged.Opacity | Should -Be 1
        $dragged.BorderBrush.ToString() |
            Should -BeExactly $View.Window.Resources['SettingsSeparatorBrush'].ToString()
    }

    It 'notifies nobody when a drag ends where it began' {
        & $View.SetRelayOrder @(
            [pscustomobject]@{ Id = 'a'; Name = 'wakaka'; Enabled = $true }
            [pscustomobject]@{ Id = 'b'; Name = 'relay-b'; Enabled = $true }
        )
        $panel = $View.Controls.RelayOrderList
        $rows = @(Get-RelayOrderRow -Panel $panel)

        $View.State.DragRow = $rows[0]
        $View.State.DragProviderId = 'a'
        $View.State.DragFromIndex = 0
        $View.State.DragActive = $true

        $mouseUp = [Windows.Input.MouseButtonEventArgs]::new(
            [Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left
        )
        $View.State.Delegates.RelayOrderMouseUp.Invoke($panel, $mouseUp)

        @($script:Calls) | Should -Be @()
        $View.State.DragRow | Should -BeNullOrEmpty
    }

    It 'drops a drag that never passed the movement threshold' {
        & $View.SetRelayOrder @(
            [pscustomobject]@{ Id = 'a'; Name = 'wakaka'; Enabled = $true }
            [pscustomobject]@{ Id = 'b'; Name = 'relay-b'; Enabled = $true }
        )
        $panel = $View.Controls.RelayOrderList
        $rows = @(Get-RelayOrderRow -Panel $panel)

        # a plain click records the press but never activates the drag
        $View.State.DragRow = $rows[0]
        $View.State.DragProviderId = 'a'
        $View.State.DragFromIndex = 0
        $View.State.DragActive = $false

        $mouseUp = [Windows.Input.MouseButtonEventArgs]::new(
            [Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left
        )
        $View.State.Delegates.RelayOrderMouseUp.Invoke($panel, $mouseUp)

        @($script:Calls) | Should -Be @()
        $View.State.DragRow | Should -BeNullOrEmpty
    }

    It 'abandons the drag when the panel loses mouse capture' {
        & $View.SetRelayOrder @(
            [pscustomobject]@{ Id = 'a'; Name = 'wakaka'; Enabled = $true }
        )
        $panel = $View.Controls.RelayOrderList
        $rows = @(Get-RelayOrderRow -Panel $panel)
        $View.State.DragRow = $rows[0]
        $View.State.DragProviderId = 'a'
        $View.State.DragFromIndex = 0
        $View.State.DragActive = $true
        $rows[0].Opacity = 0.55

        $View.State.Delegates.RelayOrderLostCapture.Invoke(
            $panel,
            [Windows.Input.MouseEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice, 0)
        )

        $View.State.DragRow | Should -BeNullOrEmpty
        $rows[0].Opacity | Should -Be 1
        @($script:Calls) | Should -Be @()
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
