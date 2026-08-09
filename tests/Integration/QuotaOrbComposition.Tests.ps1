BeforeDiscovery {
    $viewPath = Join-Path $PSScriptRoot '..\..\companion\Private\QuotaOrbView.ps1'
    $xamlPath = Join-Path $PSScriptRoot '..\..\companion\UI\QuotaOrb.xaml'
    $script:QuotaOrbFilesExist =
        (Test-Path -LiteralPath $viewPath -PathType Leaf) -and
        (Test-Path -LiteralPath $xamlPath -PathType Leaf)
}

BeforeAll {
    $script:QuotaOrbViewPath = Join-Path $PSScriptRoot '..\..\companion\Private\QuotaOrbView.ps1'
    $script:QuotaOrbXamlPath = Join-Path $PSScriptRoot '..\..\companion\UI\QuotaOrb.xaml'
    if ((Test-Path -LiteralPath $script:QuotaOrbViewPath -PathType Leaf) -and
        (Test-Path -LiteralPath $script:QuotaOrbXamlPath -PathType Leaf)) {
        . $script:QuotaOrbViewPath
    }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    function New-TestOrbRow {
        param(
            [string]$Key = 'official:weekly',
            [string]$Label = '周额度',
            [string]$ValueText = '74%',
            [AllowNull()][object]$ProgressValue = 74,
            [string]$ResetTime = '重置时间：2026-08-08 14:50',
            [bool]$IsStale = $false
        )

        [pscustomobject][ordered]@{
            Key = $Key
            SourceKind = 'Official'
            SourceId = 'codex'
            GroupLabel = 'Codex 官方额度'
            Label = $Label
            ValueText = $ValueText
            SecondaryText = ''
            ProgressValue = $ProgressValue
            Countdown = '6天 23:04:48'
            ResetTime = $ResetTime
            IsStale = $IsStale
            UpdatedAt = [DateTimeOffset]'2026-08-02T10:00:00Z'
            State = $(if ($IsStale) { 'Stale' } else { 'Live' })
        }
    }
}

Describe 'quota orb composition' {
    AfterEach {
        if ($null -ne $script:OrbView) {
            try { & $script:OrbView.Dispose } catch {}
            $script:OrbView = $null
        }
    }

    It 'provides the orb XAML and adapter files' {
        Test-Path -LiteralPath $script:QuotaOrbXamlPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $script:QuotaOrbViewPath -PathType Leaf | Should -BeTrue
    }

    Context 'when orb composition files exist' -Skip:(-not $script:QuotaOrbFilesExist) {
        It 'computes deterministic geometry for a 74 percent arc' {
            $geometry = Get-QuotaOrbArcGeometry -Percent 74 -Radius 35
            $angle = 360 * 74 / 100
            $radians = ($angle - 90) * [Math]::PI / 180

            $geometry.EndX | Should -Be (35 + (35 * [Math]::Cos($radians))) -Because 'arc X is deterministic'
            $geometry.EndY | Should -Be (35 + (35 * [Math]::Sin($radians))) -Because 'arc Y is deterministic'
            $geometry.IsLargeArc | Should -BeTrue
            @($geometry.PSObject.Properties.Name) | Should -Be @('EndX', 'EndY', 'IsLargeArc')
        }

        It 'loads the fixed circular visual contract' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath

            $OrbView.Window.WindowStyle | Should -Be ([Windows.WindowStyle]::None)
            $OrbView.Window.AllowsTransparency | Should -BeTrue
            $OrbView.Window.Width | Should -Be 112
            $OrbView.Window.Height | Should -Be 112
            $OrbView.Window.ShowInTaskbar | Should -BeFalse
            foreach ($name in @(
                'RootBorder', 'HeaderDragArea', 'RingTrack', 'RingValue', 'MetricText',
                'ValueText', 'SourceText', 'ModeButton', 'CloseButton'
            )) {
                $OrbView.Controls.Contains($name) | Should -BeTrue
                $OrbView.Controls[$name] | Should -Not -BeNullOrEmpty
            }
            $OrbView.Controls.RootBorder.CornerRadius.TopLeft | Should -Be 56
            $OrbView.Controls.RootBorder.BorderBrush.ToString() | Should -Not -BeExactly '#FFFFFFFF'
            $OrbView.Controls.RingTrack.Width | Should -Be 76
            $OrbView.Controls.RingTrack.Height | Should -Be 76
            $OrbView.Controls.RingTrack.StrokeThickness |
                Should -Be $OrbView.Controls.RingValue.StrokeThickness
            (($OrbView.Controls.RingTrack.Width - $OrbView.Controls.RingTrack.StrokeThickness) / 2) |
                Should -Be 35
            $OrbView.Controls.RingValue.Width | Should -Be 70
            $OrbView.Controls.RingValue.Height | Should -Be 70
            $OrbView.Controls.RingValue.StrokeStartLineCap |
                Should -Be ([Windows.Media.PenLineCap]::Round)
            $OrbView.Controls.RingValue.StrokeEndLineCap |
                Should -Be ([Windows.Media.PenLineCap]::Round)
        }

        It 'renders percentage text and the matching 74 percent arc' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath
            $row = New-TestOrbRow

            & $OrbView.RenderFocus -Row $row

            $OrbView.Controls.MetricText.Text | Should -BeExactly '74%'
            $OrbView.Controls.MetricText.Visibility | Should -Be ([Windows.Visibility]::Visible)
            $OrbView.Controls.ValueText.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $OrbView.Controls.RingValue.Visibility | Should -Be ([Windows.Visibility]::Visible)
            $figure = $OrbView.Controls.RingValue.Data.Figures[0]
            $segment = $figure.Segments[0]
            $expected = Get-QuotaOrbArcGeometry -Percent 74 -Radius 35
            $segment.Point.X | Should -Be $expected.EndX
            $segment.Point.Y | Should -Be $expected.EndY
            $segment.IsLargeArc | Should -BeTrue
        }

        It 'renders stable geometry for <Percent> percent' -TestCases @(
            @{ Percent = 0; ExpectFullCircle = $false }
            @{ Percent = 100; ExpectFullCircle = $true }
        ) {
            param($Percent, $ExpectFullCircle)

            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath
            $row = New-TestOrbRow -ValueText "$Percent%" -ProgressValue $Percent

            & $OrbView.RenderFocus -Row $row

            $OrbView.Controls.RingValue.Visibility | Should -Be ([Windows.Visibility]::Visible)
            $figure = $OrbView.Controls.RingValue.Data.Figures[0]
            $segment = $figure.Segments[0]
            $figure.StartPoint.X | Should -Be 35
            $figure.StartPoint.Y | Should -Be 0
            $segment.Size.Width | Should -Be 35
            $segment.Size.Height | Should -Be 35
            $segment.SweepDirection | Should -Be ([Windows.Media.SweepDirection]::Clockwise)

            if ($ExpectFullCircle) {
                $distanceFromStart = [Math]::Sqrt(
                    [Math]::Pow($segment.Point.X - $figure.StartPoint.X, 2) +
                    [Math]::Pow($segment.Point.Y - $figure.StartPoint.Y, 2)
                )
                $distanceFromStart | Should -BeGreaterThan 0
                $distanceFromStart | Should -BeLessThan 0.01
                $segment.IsLargeArc | Should -BeTrue
            }
            else {
                $segment.IsLargeArc | Should -BeFalse
            }
        }

        It 'renders a pinned absolute wallet without fabricating an arc' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath
            $wallet = New-TestOrbRow -Key 'relay:wakaka:wallet' -Label '账户余额' `
                -ValueText '$18.42 USD' -ProgressValue $null -ResetTime '最近更新：刚刚'

            & $OrbView.RenderFocus -Row $wallet -PinnedKey 'relay:wakaka:wallet'

            $OrbView.Controls.RingValue.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $OrbView.Controls.MetricText.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $OrbView.Controls.ValueText.Visibility | Should -Be ([Windows.Visibility]::Visible)
            $OrbView.Controls.ValueText.Text | Should -BeExactly '$18.42 USD'
            $OrbView.Controls.SourceText.Text | Should -BeExactly '账户余额'
        }

        It 'renders an em dash for an unpinned absolute wallet' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath
            $wallet = New-TestOrbRow -Key 'relay:wakaka:wallet' -Label '账户余额' `
                -ValueText '$18.42 USD' -ProgressValue $null

            & $OrbView.RenderFocus -Row $wallet

            $OrbView.Controls.RingValue.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $OrbView.Controls.ValueText.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $OrbView.Controls.MetricText.Visibility | Should -Be ([Windows.Visibility]::Visible)
            $OrbView.Controls.MetricText.Text | Should -BeExactly '—'
        }

        It 'builds a safe hover tooltip with source value freshness and reset' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath
            $row = New-TestOrbRow -IsStale $true

            & $OrbView.RenderFocus -Row $row

            $tooltip = [string]$OrbView.Controls.RootBorder.ToolTip
            $tooltip | Should -Match 'Codex 官方额度.*周额度'
            $tooltip | Should -Match '74%'
            $tooltip | Should -Match '数据已过期'
            $tooltip | Should -Match '重置时间：2026-08-08 14:50'
        }

        It 'applies both themes without replacing the focus snapshot' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath -Theme Dark
            $row = New-TestOrbRow
            & $OrbView.RenderFocus $row

            & $OrbView.SetTheme Light
            $OrbView.State.Theme | Should -BeExactly 'Light'
            $OrbView.Controls.RootBorder.Background.ToString() | Should -BeExactly '#E6F4EFEA'
            [object]::ReferenceEquals($OrbView.State.FocusRow, $row) | Should -BeTrue

            & $OrbView.SetTheme Dark
            $OrbView.Controls.RootBorder.Background.ToString() | Should -BeExactly '#E6323A4C'
        }

        It 'routes body mode close and finite drag callbacks exactly once' {
            $calls = [Collections.Generic.List[string]]::new()
            $script:placement = $null
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath `
                -DragAction {
                    param($window)
                    $window.Left = 12
                    $window.Top = 34
                    $calls.Add('drag-action')
                } `
                -OnDrag { param($value) $calls.Add('drag'); $script:placement = $value } `
                -OnOpenFull { $calls.Add('open') } `
                -OnModeRequested { $calls.Add('mode') } `
                -OnCloseRequested { $calls.Add('close') }

            $bodyEvent = [Windows.Input.MouseButtonEventArgs]::new(
                [Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left
            )
            $OrbView.State.Delegates.BodyMouseLeftButtonUp.Invoke($OrbView.Controls.RootBorder, $bodyEvent)
            $OrbView.Controls.ModeButton.RaiseEvent(
                [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
            )
            $OrbView.Controls.CloseButton.RaiseEvent(
                [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
            )
            $dragEvent = [Windows.Input.MouseButtonEventArgs]::new(
                [Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left
            )
            $OrbView.State.Delegates.HeaderMouseLeftButtonDown.Invoke(
                $OrbView.Controls.HeaderDragArea,
                $dragEvent
            )

            @($calls) | Should -Be @('open', 'mode', 'close', 'drag-action', 'drag')
            [double]::IsNaN($script:placement.Left) | Should -BeFalse
            [double]::IsNaN($script:placement.Top) | Should -BeFalse
        }

        It 'cancels ordinary closing and disposes idempotently' {
            $closeCalls = 0
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath `
                -OnCloseRequested { $script:closeCalls++ }

            $ordinary = [ComponentModel.CancelEventArgs]::new()
            $OrbView.State.Delegates.Closing.Invoke($OrbView.Window, $ordinary)
            $ordinary.Cancel | Should -BeTrue
            $script:closeCalls | Should -Be 1

            { & $OrbView.Dispose; & $OrbView.Dispose } | Should -Not -Throw
            $OrbView.State.Disposed | Should -BeTrue
            $OrbView.State.Callbacks | Should -BeNullOrEmpty
            $script:OrbView = $null
        }
    }
}
