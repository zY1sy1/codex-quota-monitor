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
            [string]$SourceLabel = 'Codex 官方',
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
            SourceLabel = $SourceLabel
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
            $geometry = Get-QuotaOrbArcGeometry -Percent 74 -Radius 36 -CenterX 40 -CenterY 40
            $angle = 360 * 74 / 100
            $radians = ($angle - 90) * [Math]::PI / 180

            $geometry.EndX | Should -Be (40 + (36 * [Math]::Cos($radians))) -Because 'arc X is deterministic'
            $geometry.EndY | Should -Be (40 + (36 * [Math]::Sin($radians))) -Because 'arc Y is deterministic'
            $geometry.IsLargeArc | Should -BeTrue
            @($geometry.PSObject.Properties.Name) | Should -Be @('EndX', 'EndY', 'IsLargeArc')
        }

        It 'defaults arc geometry to the shared ring cell spec' {
            $geometry = Get-QuotaOrbArcGeometry -Percent 25
            $geometry.EndX | Should -Be 76 -Because '25 percent ends on the right edge of the ring'
            $geometry.EndY | Should -Be 40
            $geometry.IsLargeArc | Should -BeFalse
        }

        It 'loads the fixed circular visual contract' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath

            $OrbView.Window.WindowStyle | Should -Be ([Windows.WindowStyle]::None)
            $OrbView.Window.AllowsTransparency | Should -BeTrue
            $OrbView.Window.Width | Should -Be 84
            $OrbView.Window.Height | Should -Be 84
            $OrbView.Window.ShowInTaskbar | Should -BeFalse
            foreach ($name in @(
                'RootBorder', 'HeaderDragArea', 'RingTrack', 'RingValue', 'MetricText',
                'ValueText', 'SourceText', 'ModeButton', 'CloseButton'
            )) {
                $OrbView.Controls.Contains($name) | Should -BeTrue
                $OrbView.Controls[$name] | Should -Not -BeNullOrEmpty
            }
            $OrbView.Controls.RootBorder.CornerRadius.TopLeft | Should -Be 42
            $OrbView.Controls.RootBorder.BorderThickness.Top | Should -Be 0 -Because 'the quota ring itself forms the orb edge'
            $OrbView.Controls.RingTrack.Width | Should -Be 80
            $OrbView.Controls.RingTrack.Height | Should -Be 80
            $OrbView.Controls.RingTrack.StrokeThickness | Should -Be 8
            $OrbView.Controls.RingTrack.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $OrbView.Controls.RingValue.Width | Should -Be 80
            $OrbView.Controls.RingValue.Height | Should -Be 80
            $OrbView.Controls.RingValue.StrokeThickness | Should -Be 8
            $OrbView.Controls.RingValue.Stretch | Should -Be ([Windows.Media.Stretch]::None) -Because 'raw ring coordinates keep the ink inscribed inside the cell'
            $OrbView.Controls.RingValue.StrokeStartLineCap |
                Should -Be ([Windows.Media.PenLineCap]::Round)
            $OrbView.Controls.RingValue.StrokeEndLineCap |
                Should -Be ([Windows.Media.PenLineCap]::Round)
        }

        It 'renders percentage text and the matching 74 percent arc over a full track' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath
            $row = New-TestOrbRow

            & $OrbView.RenderFocus -Row $row

            $OrbView.Controls.MetricText.Text | Should -BeExactly '74%'
            $OrbView.Controls.MetricText.Visibility | Should -Be ([Windows.Visibility]::Visible)
            $OrbView.Controls.ValueText.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $trackData = $OrbView.Controls.RingTrack.Data
            $trackData | Should -BeOfType ([Windows.Media.EllipseGeometry])
            $trackData.Center.X | Should -Be 40
            $trackData.Center.Y | Should -Be 40
            $trackData.RadiusX | Should -Be 36
            $trackData.RadiusY | Should -Be 36
            $OrbView.Controls.RingTrack.Visibility | Should -Be ([Windows.Visibility]::Visible)
            $OrbView.Controls.RingValue.Visibility | Should -Be ([Windows.Visibility]::Visible)
            $figure = $OrbView.Controls.RingValue.Data.Figures[0]
            $figure.StartPoint.X | Should -Be 40
            $figure.StartPoint.Y | Should -Be 4 -Because 'the arc starts at the top of the shared radius-36 circle'
            $segment = $figure.Segments[0]
            $expected = Get-QuotaOrbArcGeometry -Percent 74 -Radius 36 -CenterX 40 -CenterY 40
            $segment.Point.X | Should -Be $expected.EndX
            $segment.Point.Y | Should -Be $expected.EndY
            $segment.Size.Width | Should -Be 36
            $segment.Size.Height | Should -Be 36
            $segment.IsLargeArc | Should -BeTrue
        }

        It 'renders no value arc at zero percent but keeps the empty track' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath
            $row = New-TestOrbRow -ValueText '0%' -ProgressValue 0

            & $OrbView.RenderFocus -Row $row

            $OrbView.Controls.MetricText.Text | Should -BeExactly '0%'
            $OrbView.Controls.RingValue.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $OrbView.Controls.RingValue.Data | Should -BeNullOrEmpty
            $OrbView.Controls.RingTrack.Visibility | Should -Be ([Windows.Visibility]::Visible) -Because 'a numeric percentage still reads as a ring'
        }

        It 'renders a genuine closed circle at one hundred percent' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath
            $row = New-TestOrbRow -ValueText '100%' -ProgressValue 100

            & $OrbView.RenderFocus -Row $row

            $OrbView.Controls.RingValue.Visibility | Should -Be ([Windows.Visibility]::Visible)
            $data = $OrbView.Controls.RingValue.Data
            $data | Should -BeOfType ([Windows.Media.EllipseGeometry])
            $data.Center.X | Should -Be 40
            $data.Center.Y | Should -Be 40
            $data.RadiusX | Should -Be 36
            $data.RadiusY | Should -Be 36
            $track = $OrbView.Controls.RingTrack.Data
            $track.Center | Should -Be $data.Center -Because 'track and value share one circle spec'
            $track.RadiusX | Should -Be $data.RadiusX
        }

        It 'compacts a relay ratio to the leading amount only on the orb face' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath
            $row = New-TestOrbRow -Key 'relay:wakaka:plan' -Label 'standard' `
                -SourceLabel 'Wakaka' -ValueText '$2.02 / $5.00 USD' -ProgressValue 40.4

            & $OrbView.RenderFocus -Row $row

            $OrbView.Controls.MetricText.Text | Should -BeExactly '$2.02'
            $OrbView.Controls.MetricText.Visibility | Should -Be ([Windows.Visibility]::Visible)
            $OrbView.Controls.RingValue.Visibility | Should -Be ([Windows.Visibility]::Visible)
            [string]$OrbView.Controls.RootBorder.ToolTip |
                Should -Match '\$2\.02 / \$5\.00 USD' -Because 'the tooltip keeps the full ratio'
        }

        It 'strips the currency unit but keeps plain amounts and percentages' {
            ConvertTo-QuotaOrbCompactValueText -Text '74%' | Should -BeExactly '74%'
            ConvertTo-QuotaOrbCompactValueText -Text '$18.42 USD' | Should -BeExactly '$18.42'
            ConvertTo-QuotaOrbCompactValueText -Text '¥12.30 CNY' | Should -BeExactly '¥12.30'
            ConvertTo-QuotaOrbCompactValueText -Text '--' | Should -BeExactly '--'
        }

        It 'renders a pinned absolute wallet without fabricating an arc' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath
            $wallet = New-TestOrbRow -Key 'relay:wakaka:wallet' -Label '账户余额' `
                -SourceLabel 'Wakaka' -ValueText '$18.42 USD' -ProgressValue $null `
                -ResetTime '最近更新：刚刚'

            & $OrbView.RenderFocus -Row $wallet -PinnedKey 'relay:wakaka:wallet'

            $OrbView.Controls.RingValue.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $OrbView.Controls.RingTrack.Visibility | Should -Be ([Windows.Visibility]::Collapsed) -Because 'a wallet without a percentage must not fake a ring'
            $OrbView.Controls.MetricText.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $OrbView.Controls.ValueText.Visibility | Should -Be ([Windows.Visibility]::Visible)
            $OrbView.Controls.ValueText.Text | Should -BeExactly '$18.42'
            $OrbView.Controls.SourceText.Text | Should -BeExactly '账户余额' -Because 'the orb face prefers the bare short label'
            $valueBlock = $OrbView.Controls.ValueText
            $valueBlock.FontSize | Should -BeGreaterOrEqual 13
            $valueBlock.FontSize | Should -BeLessOrEqual 19 -Because 'the hero amount shrinks to the largest size that still fits'
            # Fit invariant, independent of OS font: the rendered string must be
            # narrower than MaxWidth in the control's own family (YaHei on zh-CN).
            $fitTypeface = [Windows.Media.Typeface]::new(
                $valueBlock.FontFamily, [Windows.FontStyles]::Normal,
                [Windows.FontWeights]::Bold, [Windows.FontStretches]::Normal)
            $fitText = [Windows.Media.FormattedText]::new(
                $valueBlock.Text, [Globalization.CultureInfo]::CurrentUICulture,
                [Windows.FlowDirection]::LeftToRight, $fitTypeface,
                $valueBlock.FontSize, [Windows.Media.Brushes]::White, 1.0)
            $fitText.Width | Should -BeLessOrEqual ([double]$valueBlock.MaxWidth) -Because 'anything wider would render as CharacterEllipsis dots'
            $valueBlock.FontWeight | Should -Be ([Windows.FontWeights]::Bold)
            $OrbView.Controls.SourceText.FontSize | Should -Be 10
            [string]$OrbView.Controls.RootBorder.ToolTip | Should -Match '^Wakaka · 账户余额' -Because 'the tooltip keeps the full source context'
        }

        It 'shrinks a long pinned amount below hero size instead of ellipsizing' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath
            $wallet = New-TestOrbRow -Key 'relay:wakaka:wallet' -Label '账户余额' `
                -SourceLabel 'Wakaka' -ValueText '$1234.56 USD' -ProgressValue $null `
                -ResetTime '最近更新：刚刚'

            & $OrbView.RenderFocus -Row $wallet -PinnedKey 'relay:wakaka:wallet'

            $longBlock = $OrbView.Controls.ValueText
            $longBlock.FontSize | Should -BeLessThan 19 -Because 'a nine-character amount cannot stay at hero size'
            $fitTypeface = [Windows.Media.Typeface]::new(
                $longBlock.FontFamily, [Windows.FontStyles]::Normal,
                [Windows.FontWeights]::Bold, [Windows.FontStretches]::Normal)
            $fitText = [Windows.Media.FormattedText]::new(
                $longBlock.Text, [Globalization.CultureInfo]::CurrentUICulture,
                [Windows.FlowDirection]::LeftToRight, $fitTypeface,
                $longBlock.FontSize, [Windows.Media.Brushes]::White, 1.0)
            $fitText.Width | Should -BeLessOrEqual ([double]$longBlock.MaxWidth)
            $longBlock.Text | Should -BeExactly '$1234.56' -Because 'the full amount is kept, only the glyph size adapts'
        }

        It 'renders an em dash for an unpinned absolute wallet' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath
            $wallet = New-TestOrbRow -Key 'relay:wakaka:wallet' -Label '账户余额' `
                -ValueText '$18.42 USD' -ProgressValue $null

            & $OrbView.RenderFocus -Row $wallet

            $OrbView.Controls.RingValue.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $OrbView.Controls.RingTrack.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $OrbView.Controls.ValueText.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $OrbView.Controls.MetricText.Visibility | Should -Be ([Windows.Visibility]::Visible)
            $OrbView.Controls.MetricText.Text | Should -BeExactly '—'
        }

        It 'shows a stable unavailable state for a missing manually pinned row' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath

            & $OrbView.RenderFocus -Row $null -PinnedKey 'relay:missing'

            $OrbView.Controls.MetricText.Text | Should -BeExactly '—'
            $OrbView.Controls.SourceText.Text | Should -BeExactly '所选额度暂不可用'
            $OrbView.Controls.RingValue.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
            $OrbView.Controls.RingTrack.Visibility | Should -Be ([Windows.Visibility]::Collapsed)
        }

        It 'builds a safe hover tooltip with source value freshness and reset' {
            $script:OrbView = New-QuotaOrbView -XamlPath $script:QuotaOrbXamlPath
            $row = New-TestOrbRow -IsStale $true

            & $OrbView.RenderFocus -Row $row

            $tooltip = [string]$OrbView.Controls.RootBorder.ToolTip
            $tooltip | Should -Match 'Codex 官方 · 周额度'
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
            $OrbView.Controls.RingTrack.Stroke.ToString() | Should -BeExactly '#40716D68'
            [object]::ReferenceEquals($OrbView.State.FocusRow, $row) | Should -BeTrue

            & $OrbView.SetTheme Dark
            $OrbView.Controls.RootBorder.Background.ToString() | Should -BeExactly '#E6323A4C'
            $OrbView.Controls.RingTrack.Stroke.ToString() | Should -BeExactly '#4D707A90'
            $OrbView.Controls.RingValue.Stroke.ToString() | Should -BeExactly '#FF58C2C7'
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
