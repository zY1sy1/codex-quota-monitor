BeforeDiscovery {
    $viewPath = Join-Path $PSScriptRoot '..\..\companion\Private\CompactBarView.ps1'
    $xamlPath = Join-Path $PSScriptRoot '..\..\companion\UI\CompactBar.xaml'
    $script:CompactBarFilesExist =
        (Test-Path -LiteralPath $viewPath -PathType Leaf) -and
        (Test-Path -LiteralPath $xamlPath -PathType Leaf)
}

BeforeAll {
    $script:CompactBarViewPath = Join-Path $PSScriptRoot '..\..\companion\Private\CompactBarView.ps1'
    $script:CompactBarXamlPath = Join-Path $PSScriptRoot '..\..\companion\UI\CompactBar.xaml'
    if ((Test-Path -LiteralPath $script:CompactBarViewPath -PathType Leaf) -and
        (Test-Path -LiteralPath $script:CompactBarXamlPath -PathType Leaf)) {
        . $script:CompactBarViewPath
    }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    function New-TestCompactRow {
        param(
            [string]$Key = 'official:five-hour',
            [string]$SourceLabel = 'Codex 官方',
            [string]$Label = '5 小时额度',
            [string]$ValueText = '74%',
            [AllowNull()][object]$ProgressValue = 74,
            [string]$Countdown = '04:59:59',
            [string]$ResetTime = '重置时间：今天 23:00'
        )

        [pscustomobject][ordered]@{
            Key = $Key
            SourceKind = 'Official'
            SourceId = 'codex'
            SourceLabel = $SourceLabel
            GroupLabel = 'Codex 官方额度'
            Label = $Label
            ValueText = $ValueText
            SecondaryText = ''
            ProgressValue = $ProgressValue
            Countdown = $Countdown
            ResetTime = $ResetTime
            IsStale = $false
            UpdatedAt = [DateTimeOffset]'2026-08-02T10:00:00Z'
            State = 'Live'
        }
    }
}

Describe 'compact quota bar composition' {
    AfterEach {
        if ($null -ne $script:CompactView) {
            try { & $script:CompactView.Dispose } catch {}
            $script:CompactView = $null
        }
    }

    It 'provides the compact XAML and adapter files' {
        Test-Path -LiteralPath $script:CompactBarXamlPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $script:CompactBarViewPath -PathType Leaf | Should -BeTrue
    }

    Context 'when compact composition files exist' -Skip:(-not $script:CompactBarFilesExist) {
        It 'requires an STA thread' {
            [Threading.Thread]::CurrentThread.GetApartmentState() |
                Should -Be ([Threading.ApartmentState]::STA)
        }

        It 'loads the fixed compact visual contract without white separators' {
            $script:CompactView = New-CompactBarView -XamlPath $script:CompactBarXamlPath

            $window = $CompactView.Window
            $window.WindowStyle | Should -Be ([Windows.WindowStyle]::None)
            $window.AllowsTransparency | Should -BeTrue
            $window.Background.ToString() | Should -BeExactly '#00FFFFFF'
            $window.Width | Should -Be 280
            $window.Height | Should -Be 64
            $window.ResizeMode | Should -Be ([Windows.ResizeMode]::NoResize)
            $window.ShowInTaskbar | Should -BeFalse

            foreach ($name in @(
                'RootBorder', 'HeaderDragArea', 'MetricLabel', 'MetricValue',
                'ProgressTrack', 'ProgressFill', 'CountdownText', 'ResetTimeText',
                'ModeButton', 'CloseButton'
            )) {
                $CompactView.Controls.Contains($name) | Should -BeTrue
                $CompactView.Controls[$name] | Should -Not -BeNullOrEmpty
            }

            $CompactView.Controls.RootBorder.CornerRadius.TopLeft | Should -BeLessOrEqual 8
            $CompactView.Controls.RootBorder.BorderBrush.ToString() | Should -Not -BeExactly '#FFFFFFFF'
            $xaml = Get-Content -LiteralPath $script:CompactBarXamlPath -Raw
            $xaml | Should -Not -Match '(?i)x:Name\s*=\s*"[^\"]*(Segment|Separator)[^\"]*"'
        }

        It 'renders a percentage row and sizes one continuous fill from actual track width' {
            $script:CompactView = New-CompactBarView -XamlPath $script:CompactBarXamlPath
            $track = $CompactView.Controls.ProgressTrack
            & $CompactView.RenderFocus (New-TestCompactRow)

            $track.Width = 200
            $track.Measure([Windows.Size]::new(200, 5))
            $track.Arrange([Windows.Rect]::new(0, 0, 200, 5))
            $track.UpdateLayout()

            $CompactView.Controls.MetricLabel.Text | Should -BeExactly 'Codex 官方 · 5 小时额度'
            $CompactView.Controls.MetricValue.Text | Should -BeExactly '74%'
            $CompactView.Controls.CountdownText.Text | Should -BeExactly '04:59:59'
            $CompactView.Controls.ResetTimeText.Text | Should -BeExactly '重置时间：今天 23:00'
            $track.Visibility | Should -Be ([Windows.Visibility]::Visible)
            $CompactView.Controls.ProgressFill.Width | Should -Be 148
            [string]$CompactView.Controls.RootBorder.ToolTip | Should -Match 'Codex 官方 · 5 小时额度'
            [string]$CompactView.Controls.RootBorder.ToolTip | Should -Match '74%'
        }

        It 'hides progress for an absolute wallet without inventing a percentage' {
            $script:CompactView = New-CompactBarView -XamlPath $script:CompactBarXamlPath
            $wallet = New-TestCompactRow -Key 'relay:wakaka:wallet' -Label '账户余额' `
                -SourceLabel 'Wakaka' -ValueText '$18.42 USD' -ProgressValue $null `
                -Countdown '' -ResetTime '最近更新：刚刚'

            & $CompactView.RenderFocus $wallet

            $CompactView.Controls.MetricLabel.Text | Should -BeExactly 'Wakaka · 账户余额'
            $CompactView.Controls.MetricValue.Text | Should -BeExactly '$18.42 USD'
            $CompactView.Controls.ProgressTrack.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $CompactView.Controls.ProgressFill.Width | Should -Be 0
        }

        It 'shows a stable unavailable state for a missing manually pinned row' {
            $script:CompactView = New-CompactBarView -XamlPath $script:CompactBarXamlPath

            & $CompactView.RenderFocus $null 'relay:missing'

            $CompactView.Controls.MetricLabel.Text | Should -BeExactly '所选额度暂不可用'
            $CompactView.Controls.MetricValue.Text | Should -BeExactly '—'
            $CompactView.Controls.ProgressTrack.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
        }

        It 'renders a deterministic empty focus state' {
            $script:CompactView = New-CompactBarView -XamlPath $script:CompactBarXamlPath

            & $CompactView.RenderFocus $null

            $CompactView.Controls.MetricLabel.Text | Should -BeExactly '暂无可比较额度'
            $CompactView.Controls.MetricValue.Text | Should -BeExactly '—'
            $CompactView.Controls.ProgressTrack.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
        }

        It 'switches both themes without changing the named structure or snapshot' {
            $script:CompactView = New-CompactBarView -XamlPath $script:CompactBarXamlPath -Theme Dark
            $row = New-TestCompactRow
            & $CompactView.RenderFocus $row

            & $CompactView.SetTheme Light
            $CompactView.State.Theme | Should -BeExactly 'Light'
            $CompactView.Controls.RootBorder.Background.ToString() | Should -BeExactly '#E6F4EFEA'
            [object]::ReferenceEquals($CompactView.State.FocusRow, $row) | Should -BeTrue

            & $CompactView.SetTheme Dark
            $CompactView.State.Theme | Should -BeExactly 'Dark'
            $CompactView.Controls.RootBorder.Background.ToString() | Should -BeExactly '#E6323A4C'
            foreach ($name in @('MetricLabel', 'MetricValue', 'ProgressTrack', 'ProgressFill')) {
                $CompactView.Controls.Contains($name) | Should -BeTrue
            }
        }

        It 'routes body, mode, close, and drag callbacks exactly once' {
            $calls = [Collections.Generic.List[string]]::new()
            $script:dragPlacement = $null
            $script:CompactView = New-CompactBarView -XamlPath $script:CompactBarXamlPath `
                -DragAction {
                    param($window)
                    $window.Left = 12
                    $window.Top = 34
                    $calls.Add('drag-action')
                } `
                -OnDrag { param($placement) $calls.Add('drag'); $script:dragPlacement = $placement } `
                -OnOpenFull { $calls.Add('open') } `
                -OnModeRequested { $calls.Add('mode') } `
                -OnCloseRequested { $calls.Add('close') }

            $bodyEvent = [Windows.Input.MouseButtonEventArgs]::new(
                [Windows.Input.Mouse]::PrimaryDevice,
                0,
                [Windows.Input.MouseButton]::Left
            )
            $CompactView.State.Delegates.BodyMouseLeftButtonUp.Invoke($CompactView.Controls.RootBorder, $bodyEvent)
            $CompactView.Controls.ModeButton.RaiseEvent(
                [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
            )
            $CompactView.Controls.CloseButton.RaiseEvent(
                [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
            )

            $dragEvent = [Windows.Input.MouseButtonEventArgs]::new(
                [Windows.Input.Mouse]::PrimaryDevice,
                0,
                [Windows.Input.MouseButton]::Left
            )
            $CompactView.State.Delegates.HeaderMouseLeftButtonDown.Invoke(
                $CompactView.Controls.HeaderDragArea,
                $dragEvent
            )

            @($calls) | Should -Be @('open', 'mode', 'close', 'drag-action', 'drag')
            @($script:dragPlacement.PSObject.Properties.Name) | Should -Be @(
                'Left', 'Top', 'Topmost', 'Visible'
            )
            [double]::IsNaN($script:dragPlacement.Left) | Should -BeFalse
            [double]::IsNaN($script:dragPlacement.Top) | Should -BeFalse
        }

        It 'cancels ordinary closing and disposes all callbacks idempotently' {
            $closeCalls = 0
            $script:CompactView = New-CompactBarView -XamlPath $script:CompactBarXamlPath `
                -OnCloseRequested { $script:closeCalls++ }

            $ordinary = [ComponentModel.CancelEventArgs]::new()
            $CompactView.State.Delegates.Closing.Invoke($CompactView.Window, $ordinary)
            $ordinary.Cancel | Should -BeTrue
            $script:closeCalls | Should -Be 1

            { & $CompactView.Dispose; & $CompactView.Dispose } | Should -Not -Throw
            $CompactView.State.Disposed | Should -BeTrue
            $CompactView.State.Callbacks | Should -BeNullOrEmpty
            $script:CompactView = $null
        }
    }
}
