BeforeAll {
    $script:WpfViewPath = Join-Path $PSScriptRoot '..\..\companion\Private\WpfView.ps1'
    $script:XamlPath = Join-Path $PSScriptRoot '..\..\companion\UI\MainWindow.xaml'
    if (Test-Path -LiteralPath $script:WpfViewPath -PathType Leaf) {
        . $script:WpfViewPath
    }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    function Get-TestDescendant {
        param(
            [Parameter(Mandatory)]$Root,
            [Parameter(Mandatory)][type]$Type,
            [string]$Tag
        )

        $matches = [Collections.Generic.List[object]]::new()
        $queue = [Collections.Generic.Queue[object]]::new()
        $queue.Enqueue($Root)
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            if ($current -is $Type -and ([string]::IsNullOrEmpty($Tag) -or [string]$current.Tag -eq $Tag)) {
                $matches.Add($current)
            }
            if ($current -is [Windows.DependencyObject]) {
                for ($index = 0; $index -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($current); $index++) {
                    $queue.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($current, $index))
                }
            }
        }

        return $matches
    }

    function New-TestPresentationRow {
        param(
            [string]$Key = 'codex|primary',
            [string]$Label = '5 小时额度',
            [string]$RemainingText = '74.5%',
            [AllowNull()][object]$ProgressValue = 74.5,
            [string]$CountdownText = '04:59:59',
            [string]$ResetTimeText = '重置时间：2026-07-13 13:00'
        )

        [pscustomobject][ordered]@{
            Key = $Key
            Label = $Label
            RemainingText = $RemainingText
            ProgressValue = $ProgressValue
            CountdownText = $CountdownText
            ResetTimeText = $ResetTimeText
        }
    }
}

Describe 'WPF floating window composition' {
    BeforeEach {
        $script:View = $null
    }

    AfterEach {
        if ($null -ne $script:View) {
            & $script:View.Dispose
        }
    }

    It 'requires an STA thread' {
        [Threading.Thread]::CurrentThread.GetApartmentState().ToString() | Should -BeExactly 'STA'
    }

    It 'loads the loose XAML with the exact named visual contract and releases the source file' {
        $script:View = New-QuotaWindowView -XamlPath $XamlPath

        $window = $View.Window
        $window | Should -BeOfType ([Windows.Window])
        $window.WindowStyle | Should -Be ([Windows.WindowStyle]::None)
        $window.AllowsTransparency | Should -BeTrue
        $window.Background.ToString() | Should -BeExactly '#00FFFFFF'
        $window.Width | Should -Be 420
        $window.SizeToContent | Should -Be ([Windows.SizeToContent]::Height)
        $window.MinHeight | Should -Be 240
        $window.Topmost | Should -BeTrue
        $window.ShowInTaskbar | Should -BeFalse

        foreach ($name in @(
            'RootBorder', 'HeaderDragArea', 'ConnectionDot', 'TitleText', 'PinButton',
            'ThemeButton', 'ModeButton', 'LayoutButton', 'HideButton', 'CloseButton',
            'OverviewPanel', 'TabsPanel', 'OfficialRows', 'RelayRows',
            'OfficialTabRows', 'RelayTabRows', 'OfficialTabButton', 'RelayTabButton',
            'OfficialExpander', 'RelayExpander', 'FreshnessText'
        )) {
            $View.Controls.Contains($name) | Should -BeTrue
            $View.Controls[$name] | Should -Not -BeNullOrEmpty
            [object]::ReferenceEquals($window.FindName($name), $View.Controls[$name]) | Should -BeTrue
        }

        $View.Controls.RootBorder | Should -BeOfType ([Windows.Controls.Border])
        $View.Controls.RootBorder.Background.ToString() | Should -BeExactly '#E6323A4C'
        $View.Controls.RootBorder.CornerRadius.TopLeft | Should -BeLessOrEqual 8
        $View.Controls.RootBorder.Padding.Left | Should -Be 16
        $View.Controls.HeaderDragArea.ActualHeight | Should -Be 0
        $View.Controls.ConnectionDot | Should -BeOfType ([Windows.Controls.Border])
        $View.Controls.TitleText | Should -BeOfType ([Windows.Controls.TextBlock])
        $View.Controls.TitleText.IsHitTestVisible | Should -BeFalse
        $View.Controls.OfficialRows | Should -BeOfType ([Windows.Controls.StackPanel])
        $View.Controls.RelayRows | Should -BeOfType ([Windows.Controls.StackPanel])
        $View.Controls.FreshnessText | Should -BeOfType ([Windows.Controls.TextBlock])
        $View.State.Theme | Should -BeExactly 'Dark'
        $View.State.FullLayout | Should -BeExactly 'Overview'
        $View.State.OfficialRows.Count | Should -Be 0
        $View.State.RelayRows.Count | Should -Be 0
        $View.State.FocusKey | Should -BeNullOrEmpty
        $View.State.Palette.Surface | Should -BeExactly '#E6323A4C'
        $window.Tag | Should -BeExactly 'Dark'

        foreach ($buttonName in @(
            'PinButton', 'ThemeButton', 'ModeButton', 'LayoutButton', 'HideButton', 'CloseButton'
        )) {
            $button = $View.Controls[$buttonName]
            $button | Should -BeOfType ([Windows.Controls.Button])
            $button.Width | Should -BeGreaterOrEqual 28
            $button.Height | Should -BeGreaterOrEqual 28
            $button.Focusable | Should -BeTrue
            [string]$button.ToolTip | Should -Not -BeNullOrEmpty
            [Windows.Automation.AutomationProperties]::GetName($button) | Should -Not -BeNullOrEmpty
        }
        [Windows.Automation.AutomationProperties]::GetName($View.Controls.ConnectionDot) | Should -Match '连接状态'

        $exclusive = [IO.File]::Open($XamlPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $exclusive.Dispose()
    }

    It 'renders two presentation rows with literal text, progress, countdown, and reset time' {
        $script:View = New-QuotaWindowView -XamlPath $XamlPath
        $malicious = '<Button Click="Invoke-Evil">&amp; literal</Button>'
        $rows = @()
        $rows += New-TestPresentationRow
        $rows += [pscustomobject][ordered]@{
            Key = 'codex|secondary'
            Label = $malicious
            RemainingText = '--%'
            ProgressValue = $null
            CountdownText = '1天 00:00:00'
            ResetTimeText = '重置时间未知'
        }

        & $View.Render -PresentationRows $rows

        $View.Controls.OfficialRows.Children.Count | Should -Be 2
        $texts = @(Get-TestDescendant -Root $View.Controls.OfficialRows -Type ([Windows.Controls.TextBlock]))
        @($texts.Text) | Should -Contain '5 小时额度'
        @($texts.Text) | Should -Contain '74.5%'
        @($texts.Text) | Should -Contain '04:59:59'
        @($texts.Text) | Should -Contain '重置时间：2026-07-13 13:00'
        @($texts.Text) | Should -Contain $malicious
        @($texts.Text) | Should -Contain '--%'
        @($texts.Text) | Should -Contain '重置时间未知'

        $bars = @(Get-TestDescendant -Root $View.Controls.OfficialRows -Type ([Windows.Controls.ProgressBar]) -Tag 'QuotaProgress')
        $bars.Count | Should -Be 2
        $bars[0].Visibility | Should -Be ([Windows.Visibility]::Visible)
        $bars[0].Value | Should -Be 74.5
        $bars[1].Visibility | Should -Be ([Windows.Visibility]::Collapsed)
    }

    It 'lays out the progress indicator from the actual value' {
        $script:View = New-QuotaWindowView -XamlPath $XamlPath
        & $View.Render -PresentationRows @((New-TestPresentationRow -ProgressValue 50))
        $bar = @(Get-TestDescendant -Root $View.Controls.OfficialRows -Type ([Windows.Controls.ProgressBar]) -Tag 'QuotaProgress')[0]

        $bar.Width = 200
        $bar.ApplyTemplate() | Out-Null
        $bar.Measure([Windows.Size]::new(200, 6))
        $bar.Arrange([Windows.Rect]::new(0, 0, 200, 6))
        $bar.UpdateLayout()
        $indicator = $bar.Template.FindName('PART_Indicator', $bar)

        $indicator | Should -Not -BeNullOrEmpty
        $indicator.ActualWidth | Should -BeGreaterThan 90
        $indicator.ActualWidth | Should -BeLessThan 110
    }

    It 'replaces old rows and shows the exact empty-state message' {
        $script:View = New-QuotaWindowView -XamlPath $XamlPath
        & $View.Render -PresentationRows @(
            New-TestPresentationRow
            New-TestPresentationRow -Key 'weekly' -Label '周额度'
        )
        $View.Controls.OfficialRows.Children.Count | Should -Be 2

        & $View.Render -PresentationRows @((New-TestPresentationRow -Key 'other' -Label '其他额度'))
        $View.Controls.OfficialRows.Children.Count | Should -Be 1
        $texts = @(Get-TestDescendant -Root $View.Controls.OfficialRows -Type ([Windows.Controls.TextBlock]))
        @($texts.Text) | Should -Contain '其他额度'
        @($texts.Text) | Should -Not -Contain '周额度'

        & $View.Render -PresentationRows @()
        $View.Controls.OfficialRows.Children.Count | Should -Be 1
        $empty = $View.Controls.OfficialRows.Children[0]
        $empty | Should -BeOfType ([Windows.Controls.TextBlock])
        $empty.Text | Should -BeExactly '当前账户未返回额度窗口'
    }

    It 'contains long text and rejects missing or non-finite progress safely' -ForEach @(
        @{ Value = $null },
        @{ Value = [double]::NaN },
        @{ Value = [double]::PositiveInfinity },
        @{ Value = 'not-a-number' }
    ) {
        $script:View = New-QuotaWindowView -XamlPath $XamlPath
        $longLabel = '很长的官方额度名称' * 50
        $row = New-TestPresentationRow -Label $longLabel -ProgressValue $Value

        { & $View.Render -PresentationRows @($row) } | Should -Not -Throw

        $texts = @(Get-TestDescendant -Root $View.Controls.OfficialRows -Type ([Windows.Controls.TextBlock]))
        @($texts.Text) | Should -Contain $longLabel
        $bar = @(Get-TestDescendant -Root $View.Controls.OfficialRows -Type ([Windows.Controls.ProgressBar]) -Tag 'QuotaProgress')[0]
        $bar.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
    }

    It 'renders official and relay snapshots into overview and tabs in sync' {
        $script:View = New-QuotaWindowView -XamlPath $XamlPath
        $official = @(New-TestPresentationRow -Key 'official|five-hour' -Label '官方 5 小时')
        $relay = @(New-TestPresentationRow -Key 'relay|daily' -Label '中转日额度')
        $connectionState = [pscustomobject]@{ IsLive = $true }

        & $View.RenderGroups -OfficialRows $official -RelayRows $relay -State $connectionState

        foreach ($name in @('OfficialRows', 'OfficialTabRows')) {
            $View.Controls[$name].Children.Count | Should -Be 1
            $texts = @(Get-TestDescendant -Root $View.Controls[$name] -Type ([Windows.Controls.TextBlock]))
            @($texts.Text) | Should -Contain '官方 5 小时'
        }
        foreach ($name in @('RelayRows', 'RelayTabRows')) {
            $View.Controls[$name].Children.Count | Should -Be 1
            $texts = @(Get-TestDescendant -Root $View.Controls[$name] -Type ([Windows.Controls.TextBlock]))
            @($texts.Text) | Should -Contain '中转日额度'
        }
        @($View.State.OfficialRows).Count | Should -Be 1
        @($View.State.RelayRows).Count | Should -Be 1
        [object]::ReferenceEquals($View.State.ConnectionState, $connectionState) | Should -BeTrue
    }

    It 'renders the shared relay presentation contract without legacy field aliases' {
        $script:View = New-QuotaWindowView -XamlPath $XamlPath
        $relay = [pscustomobject][ordered]@{
            Key = 'relay:wkk:wallet'
            SourceKind = 'Relay'
            SourceId = 'wkk'
            GroupLabel = '中转站额度'
            Label = 'Wakaka 账户余额'
            ValueText = '$18.42 USD'
            SecondaryText = '最近查询成功'
            ProgressValue = $null
            Countdown = '18:26:40'
            ResetTime = '重置时间：明天 00:00'
            IsStale = $false
            UpdatedAt = [DateTimeOffset]'2026-08-02T10:00:00Z'
            State = 'Live'
        }

        & $View.RenderGroups -OfficialRows @() -RelayRows @($relay)

        foreach ($name in @('RelayRows', 'RelayTabRows')) {
            $texts = @(Get-TestDescendant -Root $View.Controls[$name] -Type ([Windows.Controls.TextBlock]))
            @($texts.Text) | Should -Contain 'Wakaka 账户余额'
            @($texts.Text) | Should -Contain '$18.42 USD'
            @($texts.Text) | Should -Contain '最近查询成功'
            @($texts.Text) | Should -Contain '18:26:40'
            @($texts.Text) | Should -Contain '重置时间：明天 00:00'
        }
    }

    It 'rethemes and relayouts from the existing snapshot without losing rows' {
        $script:View = New-QuotaWindowView -XamlPath $XamlPath
        & $View.RenderGroups `
            -OfficialRows @((New-TestPresentationRow -Key 'official' -Label '官方快照')) `
            -RelayRows @((New-TestPresentationRow -Key 'relay' -Label '中转快照'))

        & $View.SetTheme Light
        $View.State.Theme | Should -BeExactly 'Light'
        $View.State.Palette.Surface | Should -BeExactly '#E6F4EFEA'
        $View.Controls.RootBorder.Background.ToString() | Should -BeExactly '#E6F4EFEA'
        $View.Controls.OfficialRows.Children.Count | Should -Be 1
        $View.Controls.RelayTabRows.Children.Count | Should -Be 1

        & $View.SetLayout Tabs
        $View.State.FullLayout | Should -BeExactly 'Tabs'
        $View.Controls.OverviewPanel.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
        $View.Controls.TabsPanel.Visibility | Should -Be ([Windows.Visibility]::Visible)
        $View.Controls.OfficialTabRows.Visibility | Should -Be ([Windows.Visibility]::Visible)
        $View.Controls.RelayTabRows.Visibility | Should -Be ([Windows.Visibility]::Collapsed)

        $View.Controls.RelayTabButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $View.Controls.OfficialTabRows.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
        $View.Controls.RelayTabRows.Visibility | Should -Be ([Windows.Visibility]::Visible)
        $relayTexts = @(Get-TestDescendant -Root $View.Controls.RelayTabRows -Type ([Windows.Controls.TextBlock]))
        @($relayTexts.Text) | Should -Contain '中转快照'
    }

    It 'renders accessible focus controls and marks the selected quota' {
        $focused = [Collections.Generic.List[string]]::new()
        $script:View = New-QuotaWindowView -XamlPath $XamlPath `
            -OnFocusRequested { param($key) $focused.Add($key) }

        & $View.RenderGroups `
            -OfficialRows @((New-TestPresentationRow -Key 'official|selected')) `
            -RelayRows @() `
            -FocusKey 'official|selected'

        $card = $View.Controls.OfficialRows.Children[0]
        $card.BorderBrush.ToString() | Should -BeExactly '#FF58C2C7'
        $card.BorderThickness.Left | Should -Be 1
        $focusButton = @(Get-TestDescendant -Root $card -Type ([Windows.Controls.Button]) -Tag 'QuotaFocus')[0]
        $focusButton | Should -Not -BeNullOrEmpty
        $focusButton.Focusable | Should -BeTrue
        [string]$focusButton.ToolTip | Should -Match '取消聚焦'
        [Windows.Automation.AutomationProperties]::GetName($focusButton) | Should -Match '取消聚焦'

        $focusButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        @($focused) | Should -Be @('official|selected')
    }

    It 'grows from one to two rows and bounds many-row height through a ScrollViewer' {
        $script:View = New-QuotaWindowView -XamlPath $XamlPath
        & $View.Render -PresentationRows @((New-TestPresentationRow))
        $View.Controls.RootBorder.Measure([Windows.Size]::new(300, [double]::PositiveInfinity))
        $oneRowHeight = $View.Controls.RootBorder.DesiredSize.Height

        & $View.Dispose
        $script:View = New-QuotaWindowView -XamlPath $XamlPath

        & $View.Render -PresentationRows @(
            New-TestPresentationRow
            New-TestPresentationRow -Key 'weekly' -Label '周额度'
        )
        $View.Controls.RootBorder.Measure([Windows.Size]::new(300, [double]::PositiveInfinity))
        $twoRowHeight = $View.Controls.RootBorder.DesiredSize.Height

        $twoRowHeight | Should -BeGreaterThan $oneRowHeight
        $scroll = @(Get-TestDescendant -Root $View.Controls.RootBorder -Type ([Windows.Controls.ScrollViewer]))[0]
        $scroll.MaxHeight | Should -BeGreaterThan 0
        $scroll.MaxHeight | Should -BeLessOrEqual 560

        & $View.Dispose
        $script:View = New-QuotaWindowView -XamlPath $XamlPath
        $many = 1..50 | ForEach-Object { New-TestPresentationRow -Key "row-$_" -Label ("额度 $_") }
        & $View.Render -PresentationRows $many
        $View.Controls.RootBorder.Measure([Windows.Size]::new(300, [double]::PositiveInfinity))
        $View.Controls.RootBorder.DesiredSize.Height | Should -BeLessThan 680
    }

    It 'switches topmost and exposes current placement without showing the window' {
        $script:View = New-QuotaWindowView -XamlPath $XamlPath
        $View.Window.Left = 123
        $View.Window.Top = 45

        & $View.SetTopmost $false
        $View.Window.Topmost | Should -BeFalse
        $placement = & $View.GetPlacement
        @($placement.PSObject.Properties.Name) | Should -Be @('Left', 'Top', 'Topmost', 'Visible')
        $placement.Left | Should -Be 123
        $placement.Top | Should -Be 45
        $placement.Topmost | Should -BeFalse
        $placement.Visible | Should -BeFalse

        & $View.SetTopmost $true
        $View.Window.Topmost | Should -BeTrue
        [string]$View.Controls.PinButton.ToolTip | Should -Match '取消'
    }

    It 'shows freshness only when stale and exposes readable connection state' {
        $script:View = New-QuotaWindowView -XamlPath $XamlPath

        & $View.SetFreshness -IsLive $true -Text 'should not display'
        $View.Controls.FreshnessText.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
        [Windows.Automation.AutomationProperties]::GetName($View.Controls.ConnectionDot) | Should -BeExactly '连接状态：实时'
        $View.Controls.ConnectionDot.Background.ToString() | Should -BeExactly '#FF22C55E'

        & $View.SetTheme Light
        $View.Controls.ConnectionDot.Background.ToString() | Should -BeExactly '#FF22C55E'

        & $View.SetFreshness -IsLive $false -Text '最后同步：12:34，正在重连'
        $View.Controls.FreshnessText.Visibility | Should -Be ([Windows.Visibility]::Visible)
        $View.Controls.FreshnessText.Text | Should -BeExactly '最后同步：12:34，正在重连'
        [Windows.Automation.AutomationProperties]::GetName($View.Controls.ConnectionDot) | Should -BeExactly '连接状态：数据已过期'
        $View.Controls.ConnectionDot.Background.ToString() | Should -BeExactly '#FF6F6B67'

        & $View.SetTheme Dark
        $View.Controls.FreshnessText.Visibility | Should -Be ([Windows.Visibility]::Visible)
        $View.Controls.FreshnessText.Text | Should -BeExactly '最后同步：12:34，正在重连'
        $View.Controls.ConnectionDot.Background.ToString() | Should -BeExactly '#FFAFB8CB'
    }

    It 'raises each injected callback exactly once and performs injected drag before reporting placement' {
        $calls = [Collections.Generic.List[string]]::new()
        $dragPlacement = $null
        $script:View = New-QuotaWindowView -XamlPath $XamlPath `
            -DragAction { $calls.Add('drag-action') } `
            -OnDrag { param($placement) $calls.Add('on-drag'); $script:dragPlacement = $placement } `
            -OnToggleTopmost { $calls.Add('toggle') } `
            -OnThemeRequested { $calls.Add('theme') } `
            -OnModeRequested { $calls.Add('mode') } `
            -OnLayoutRequested { $calls.Add('layout') } `
            -OnHide { $calls.Add('hide') } `
            -OnCloseRequested { $calls.Add('close') }

        $mouseEvent = [Windows.Input.MouseButtonEventArgs]::new(
            [Windows.Input.Mouse]::PrimaryDevice,
            0,
            [Windows.Input.MouseButton]::Left
        )
        $mouseEvent.RoutedEvent = [Windows.UIElement]::MouseLeftButtonDownEvent
        $View.Controls.HeaderDragArea.RaiseEvent($mouseEvent)
        $View.Controls.PinButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $View.Controls.ThemeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $View.Controls.ModeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $View.Controls.LayoutButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $View.Controls.HideButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $View.Controls.CloseButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))

        @($calls) | Should -Be @(
            'drag-action', 'on-drag', 'toggle', 'theme', 'mode', 'layout', 'hide', 'close'
        )
        $script:dragPlacement | Should -Not -BeNullOrEmpty
        @($script:dragPlacement.PSObject.Properties.Name) | Should -Be @('Left', 'Top', 'Topmost', 'Visible')
    }

    It 'atomically replaces callbacks after composition and clears them on dispose' {
        $calls = [Collections.Generic.List[string]]::new()
        $script:View = New-QuotaWindowView -XamlPath $XamlPath -OnHide { $calls.Add('old') }

        & $View.SetCallbacks `
            -OnDrag { $calls.Add('new-drag') } `
            -OnToggleTopmost { $calls.Add('new-toggle') } `
            -OnThemeRequested { $calls.Add('new-theme') } `
            -OnModeRequested { $calls.Add('new-mode') } `
            -OnLayoutRequested { $calls.Add('new-layout') } `
            -OnFocusRequested { param($key) $calls.Add("new-focus:$key") } `
            -OnHide { $calls.Add('new-hide') } `
            -OnCloseRequested { $calls.Add('new-close') }

        $View.Controls.HideButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        @($calls) | Should -Be @('new-hide')
        @($View.State.Callbacks.PSObject.Properties.Name) | Should -Be @(
            'OnDrag', 'OnToggleTopmost', 'OnHide', 'OnCloseRequested'
            'OnThemeRequested', 'OnModeRequested', 'OnLayoutRequested', 'OnFocusRequested'
        )

        & $View.Dispose
        $View.State.Callbacks | Should -BeNullOrEmpty
        $before = $calls.Count
        $View.Controls.HideButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $calls.Count | Should -Be $before
        $script:View = $null
    }

    It 'cancels ordinary closing, permits explicit exit, and disposes idempotently' {
        $closeCalls = 0
        $script:View = New-QuotaWindowView -XamlPath $XamlPath -OnCloseRequested { $script:closeCalls++ }
        $closing = $View.State.Delegates.Closing

        $ordinary = [ComponentModel.CancelEventArgs]::new()
        $closing.Invoke($View.Window, $ordinary)
        $ordinary.Cancel | Should -BeTrue
        $script:closeCalls | Should -Be 1

        $View.State.AllowExit = $true
        $explicit = [ComponentModel.CancelEventArgs]::new()
        $closing.Invoke($View.Window, $explicit)
        $explicit.Cancel | Should -BeFalse
        $script:closeCalls | Should -Be 1

        { & $View.Dispose; & $View.Dispose } | Should -Not -Throw
        $View.State.Disposed | Should -BeTrue

        $before = $script:closeCalls
        $View.Controls.CloseButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $script:closeCalls | Should -Be $before
        $script:View = $null
    }

    It 'rejects MTA deterministically in a separate PowerShell process' {
        $pwsh = (Get-Process -Id $PID).Path
        $escapedView = $WpfViewPath.Replace("'", "''")
        $escapedXaml = $XamlPath.Replace("'", "''")
        $command = @"
. '$escapedView'
try {
    New-QuotaWindowView -XamlPath '$escapedXaml' | Out-Null
    exit 19
}
catch {
    if (`$_.Exception.Message -ne 'Codex quota floating window requires an STA thread.') {
        [Console]::Error.WriteLine(`$_.Exception.Message)
        exit 20
    }
    exit 0
}
"@

        $process = Start-Process -FilePath $pwsh -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-Mta', '-Command', $command
        ) -Wait -PassThru -WindowStyle Hidden
        try {
            $process.ExitCode | Should -Be 0
        }
        finally {
            $process.Dispose()
        }
    }
}
