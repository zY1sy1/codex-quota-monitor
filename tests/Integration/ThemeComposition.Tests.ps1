BeforeAll {
    $script:ThemePath = Join-Path $PSScriptRoot '..\..\companion\Private\Theme.ps1'
    $script:XamlPath = Join-Path $PSScriptRoot '..\..\companion\UI\MainWindow.xaml'
    if (Test-Path -LiteralPath $script:ThemePath -PathType Leaf) {
        . $script:ThemePath
    }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    function Open-TestQuotaWindowXaml {
        $stream = $null
        $reader = $null
        try {
            $stream = [IO.File]::Open(
                [IO.Path]::GetFullPath($script:XamlPath),
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read
            )
            $settings = [Xml.XmlReaderSettings]::new()
            $settings.CloseInput = $false
            $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
            $reader = [Xml.XmlReader]::Create($stream, $settings)
            return [Windows.Markup.XamlReader]::Load($reader)
        }
        finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }

    function Get-TestRelativeLuminance {
        param([Parameter(Mandatory)][string]$Color)
        $hex = $Color.TrimStart('#')
        if ($hex.Length -eq 8) { $hex = $hex.Substring(2) }
        $channels = for ($index = 0; $index -lt 6; $index += 2) {
            $channel = [Convert]::ToInt32($hex.Substring($index, 2), 16) / 255
            if ($channel -le 0.04045) {
                $channel / 12.92
            }
            else {
                [Math]::Pow(($channel + 0.055) / 1.055, 2.4)
            }
        }
        0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
    }

    function Get-TestContrastRatio {
        param([string]$Foreground, [string]$Background)
        $first = Get-TestRelativeLuminance $Foreground
        $second = Get-TestRelativeLuminance $Background
        ([Math]::Max($first, $second) + 0.05) /
            ([Math]::Min($first, $second) + 0.05)
    }
}

Describe 'quota monitor theme composition' {
    It 'returns the exact shared palette contract for both themes' -ForEach @(
        @{ Theme = 'Light' }
        @{ Theme = 'Dark' }
    ) {
        $palette = Get-MonitorThemePalette -Theme $Theme

        @($palette.Keys) | Should -Be @(
            'Surface', 'SurfaceStrong', 'TextPrimary', 'TextSecondary', 'Accent',
            'AccentSoft', 'AccentPressed', 'SelectionSurface',
            'Track', 'Separator', 'Shadow', 'Warning', 'Danger'
        )
    }

    It 'returns the exact opaque settings palette contract for <Theme>' -ForEach @(
        @{
            Theme = 'Light'
            Surface = '#FFF9FAFA'; Sidebar = '#FFF1F5F5'; SurfaceStrong = '#FFFFFFFF'
            TextPrimary = '#FF201F1D'; TextSecondary = '#FF6F6B67'
            Accent = '#FF348186'; AccentText = '#FFFFFFFF'; Success = '#FF24757A'
            Selection = '#FFE2F0F0'; Border = '#FF7A878C'; Separator = '#FFD1D9DC'
            Hover = '#FFEAF3F3'; Pressed = '#FFD9EAEA'; Danger = '#FFB42323'
        }
        @{
            Theme = 'Dark'
            Surface = '#FF323A4C'; Sidebar = '#FF272E3D'; SurfaceStrong = '#FF3A4358'
            TextPrimary = '#FFF4F3F1'; TextSecondary = '#FFAFB8CB'
            Accent = '#FF58C2C7'; AccentText = '#FF1F2832'; Success = '#FF79D9DD'
            Selection = '#FF354D58'; Border = '#FF8792A6'; Separator = '#FF566074'
            Hover = '#FF3A4658'; Pressed = '#FF425264'; Danger = '#FFFFA0A0'
        }
    ) {
        $palette = Get-SettingsThemePalette -Theme $Theme

        @($palette.Keys) | Should -Be @(
            'Surface', 'Sidebar', 'SurfaceStrong', 'TextPrimary', 'TextSecondary',
            'Accent', 'AccentText', 'Success', 'Selection', 'Border',
            'Separator', 'Hover', 'Pressed', 'Danger'
        )
        foreach ($key in @($palette.Keys)) {
            $palette[$key] | Should -BeExactly (Get-Variable -Name $key -ValueOnly)
            $palette[$key] | Should -Match '^#FF'
        }
    }

    It 'keeps settings text and controls above minimum contrast for <Theme>' -ForEach @(
        @{ Theme = 'Light' }
        @{ Theme = 'Dark' }
    ) {
        $palette = Get-SettingsThemePalette -Theme $Theme

        foreach ($background in @(
            $palette.Surface, $palette.Sidebar, $palette.SurfaceStrong
        )) {
            Get-TestContrastRatio $palette.TextPrimary $background |
                Should -BeGreaterOrEqual 4.5
            Get-TestContrastRatio $palette.TextSecondary $background |
                Should -BeGreaterOrEqual 4.5
        }
        Get-TestContrastRatio $palette.AccentText $palette.Accent |
            Should -BeGreaterOrEqual 4.5
        Get-TestContrastRatio $palette.Success $palette.SurfaceStrong |
            Should -BeGreaterOrEqual 4.5
        Get-TestContrastRatio $palette.Success $palette.Selection |
            Should -BeGreaterOrEqual 4.5
        foreach ($background in @($palette.Surface, $palette.SurfaceStrong)) {
            Get-TestContrastRatio $palette.Accent $background |
                Should -BeGreaterOrEqual 3
            Get-TestContrastRatio $palette.Border $background |
                Should -BeGreaterOrEqual 3
        }
        Get-TestContrastRatio $palette.Danger $palette.SurfaceStrong |
            Should -BeGreaterOrEqual 4.5
    }

    It 'applies every settings palette entry as a window resource' -ForEach @(
        @{ Theme = 'Light'; Accent = '#FF348186' }
        @{ Theme = 'Dark'; Accent = '#FF58C2C7' }
    ) {
        $window = [Windows.Window]::new()
        try {
            $palette = Set-SettingsWindowTheme -Window $window -Theme $Theme

            $window.Tag | Should -BeExactly $Theme
            $palette.Accent | Should -BeExactly $Accent
            foreach ($key in @($palette.Keys)) {
                $window.Resources["Settings${key}Brush"].ToString() |
                    Should -BeExactly $palette[$key]
            }
        }
        finally {
            $window.Close()
        }
    }

    It 'uses transparent cohesive surfaces without opaque white borders' {
        $light = Get-MonitorThemePalette -Theme Light
        $dark = Get-MonitorThemePalette -Theme Dark

        $light.Surface | Should -BeExactly '#E6F4EFEA'
        $light.SurfaceStrong | Should -BeExactly '#D9EEE7E1'
        $light.TextPrimary | Should -BeExactly '#FF201F1D'
        $light.TextSecondary | Should -BeExactly '#FF6F6B67'
        $light.Accent | Should -BeExactly '#FF4DADB3'
        $light.AccentSoft | Should -BeExactly '#244DADB3'
        $light.AccentPressed | Should -BeExactly '#3D4DADB3'
        $light.SelectionSurface | Should -BeExactly '#D9E4E4DE'
        $dark.Surface | Should -BeExactly '#E6323A4C'
        $dark.SurfaceStrong | Should -BeExactly '#D93A4358'
        $dark.TextPrimary | Should -BeExactly '#FFF4F3F1'
        $dark.TextSecondary | Should -BeExactly '#FFAFB8CB'
        $dark.Accent | Should -BeExactly '#FF58C2C7'
        $dark.AccentSoft | Should -BeExactly '#2458C2C7'
        $dark.AccentPressed | Should -BeExactly '#3D58C2C7'
        $dark.SelectionSurface | Should -BeExactly '#D93C4B5F'
        ($light.Values -join '|') | Should -Not -Match '#FFFFFFFF|#00FFFFFF'
        ($dark.Values -join '|') | Should -Not -Match '#FFFFFFFF|#00FFFFFF'
    }

    It 'keeps XAML free of hard white surfaces and decorative progress segments' {
        $xaml = Get-Content -LiteralPath $XamlPath -Raw

        $xaml | Should -Not -Match '(?i)(Background|BorderBrush)\s*=\s*"#FFFFFFFF"'
        $xaml | Should -Not -Match '(?i)x:Name\s*=\s*"[^\"]*(Segment|Separator)[^\"]*"'
    }

    It 'declares a circular quota focus template with theme-driven interaction brushes' {
        $xaml = Get-Content -LiteralPath $XamlPath -Raw

        foreach ($resourceName in @(
            'QuotaFocusRingBrush', 'QuotaFocusHoverBrush', 'QuotaFocusPressedBrush',
            'QuotaFocusKeyboardVisual', 'QuotaFocusButton'
        )) {
            $xaml | Should -Match ('x:Key="' + [regex]::Escape($resourceName) + '"')
        }
        $xaml | Should -Match 'x:Name="QuotaFocusSurface"'
        $xaml | Should -Match 'CornerRadius="12"'
        $xaml | Should -Match 'FocusVisualStyle"\s+Value="\{StaticResource QuotaFocusKeyboardVisual\}"'
    }

    It 'loads and instantiates the circular quota focus button and keyboard visual' {
        [Threading.Thread]::CurrentThread.GetApartmentState().ToString() | Should -BeExactly 'STA'
        $window = Open-TestQuotaWindowXaml
        try {
            $style = $window.Resources['QuotaFocusButton']
            $style | Should -BeOfType ([Windows.Style])
            $style.TargetType | Should -Be ([Windows.Controls.Button])

            $button = [Windows.Controls.Button]::new()
            $button.Style = $style
            $button.ApplyTemplate() | Should -BeTrue
            $button.Measure([Windows.Size]::new(28, 28))
            $button.Arrange([Windows.Rect]::new(0, 0, 28, 28))
            $button.UpdateLayout()

            $button.Width | Should -Be 28
            $button.Height | Should -Be 28
            $button.BorderThickness.Left | Should -Be 0
            $button.BorderBrush.ToString() | Should -BeExactly '#00FFFFFF'
            [Windows.Media.VisualTreeHelper]::GetChildrenCount($button) | Should -Be 1
            $root = [Windows.Media.VisualTreeHelper]::GetChild($button, 0)
            $root | Should -BeOfType ([Windows.Controls.Grid])
            $root.Width | Should -Be 28
            $root.Height | Should -Be 28
            $root.ActualWidth | Should -Be 28
            $root.ActualHeight | Should -Be 28

            $surface = $button.Template.FindName('QuotaFocusSurface', $button)
            $surface | Should -BeOfType ([Windows.Controls.Border])
            $surface.Width | Should -Be 24
            $surface.Height | Should -Be 24
            $surface.ActualWidth | Should -Be 24
            $surface.ActualHeight | Should -Be 24
            $surface.CornerRadius.TopLeft | Should -Be 12

            $focusStyle = $button.FocusVisualStyle
            $focusStyle | Should -BeOfType ([Windows.Style])
            $focusTemplateSetters = @($focusStyle.Setters | Where-Object {
                $_.Property -eq [Windows.Controls.Control]::TemplateProperty
            })
            $focusTemplateSetters.Count | Should -Be 1
            $focusVisual = $focusTemplateSetters[0].Value.LoadContent()
            $focusVisual | Should -BeOfType ([Windows.Shapes.Ellipse])
            $focusVisual.Width | Should -Be 24
            $focusVisual.Height | Should -Be 24
            $focusVisual.StrokeThickness | Should -Be 1
            $focusVisual.Opacity | Should -Be 0.75
            $focusVisual.SnapsToDevicePixels | Should -BeTrue
            $strokeReference = $focusVisual.ReadLocalValue([Windows.Shapes.Shape]::StrokeProperty)
            $strokeReference.ResourceKey | Should -BeExactly 'QuotaFocusRingBrush'
        }
        finally {
            $window.Close()
        }
    }

    It 'orders quota focus triggers with the correct dynamic resources and disabled opacity' {
        $window = Open-TestQuotaWindowXaml
        try {
            $style = $window.Resources['QuotaFocusButton']
            $templateSetters = @($style.Setters | Where-Object {
                $_.Property -eq [Windows.Controls.Control]::TemplateProperty
            })
            $templateSetters.Count | Should -Be 1
            $triggers = @($templateSetters[0].Value.Triggers)

            @($triggers.Property.Name) | Should -Be @('IsMouseOver', 'IsPressed', 'IsEnabled') `
                -Because 'pressed must follow hover so its surface brush wins when both states are active'
            @($triggers.Value) | Should -Be @($true, $true, $false)

            $hoverForeground = @($triggers[0].Setters | Where-Object {
                $_.Property.Name -eq 'Foreground' -and [string]::IsNullOrEmpty($_.TargetName)
            })
            $hoverSurface = @($triggers[0].Setters | Where-Object {
                $_.Property.Name -eq 'Background' -and $_.TargetName -eq 'QuotaFocusSurface'
            })
            $pressedForeground = @($triggers[1].Setters | Where-Object {
                $_.Property.Name -eq 'Foreground' -and [string]::IsNullOrEmpty($_.TargetName)
            })
            $pressedSurface = @($triggers[1].Setters | Where-Object {
                $_.Property.Name -eq 'Background' -and $_.TargetName -eq 'QuotaFocusSurface'
            })
            foreach ($setter in @($hoverForeground[0], $hoverSurface[0], $pressedForeground[0], $pressedSurface[0])) {
                $setter | Should -Not -BeNullOrEmpty
                $setter.Value | Should -BeOfType ([Windows.DynamicResourceExtension])
            }
            $hoverForeground[0].Value.ResourceKey | Should -BeExactly 'QuotaFocusRingBrush'
            $hoverSurface[0].Value.ResourceKey | Should -BeExactly 'QuotaFocusHoverBrush'
            $pressedForeground[0].Value.ResourceKey | Should -BeExactly 'QuotaFocusRingBrush'
            $pressedSurface[0].Value.ResourceKey | Should -BeExactly 'QuotaFocusPressedBrush'

            $disabledOpacity = @($triggers[2].Setters | Where-Object {
                $_.Property.Name -eq 'Opacity' -and [string]::IsNullOrEmpty($_.TargetName)
            })
            $disabledOpacity.Count | Should -Be 1
            $disabledOpacity[0].Value | Should -Be 0.45

            $button = [Windows.Controls.Button]::new()
            $button.Style = $style
            $button.IsEnabled = $false
            $button.ApplyTemplate() | Out-Null
            $button.Opacity | Should -Be 0.45
        }
        finally {
            $window.Close()
        }
    }

    It 'updates quota focus resources for the <Theme> theme' -ForEach @(
        @{
            Theme = 'Light'
            Ring = '#FF4DADB3'
            Hover = '#244DADB3'
            Pressed = '#3D4DADB3'
        }
        @{
            Theme = 'Dark'
            Ring = '#FF58C2C7'
            Hover = '#2458C2C7'
            Pressed = '#3D58C2C7'
        }
    ) {
        $window = Open-TestQuotaWindowXaml
        try {
            $controls = @{}
            foreach ($name in @('RootBorder', 'TitleText', 'FreshnessText', 'ConnectionDot')) {
                $controls[$name] = $window.FindName($name)
                $controls[$name] | Should -Not -BeNullOrEmpty
            }

            $palette = Set-MonitorWindowTheme -Window $window -Controls $controls -Theme $Theme

            $palette.Accent | Should -BeExactly $Ring
            $palette.AccentSoft | Should -BeExactly $Hover
            $palette.AccentPressed | Should -BeExactly $Pressed
            $window.Resources['QuotaFocusRingBrush'].ToString() | Should -BeExactly $Ring
            $window.Resources['QuotaFocusHoverBrush'].ToString() | Should -BeExactly $Hover
            $window.Resources['QuotaFocusPressedBrush'].ToString() | Should -BeExactly $Pressed
        }
        finally {
            $window.Close()
        }
    }

    It 'returns false when blur cannot be applied' {
        Enable-MonitorWindowBlur -WindowHandle ([IntPtr]::Zero) | Should -BeFalse
        {
            $result = Enable-MonitorWindowBlur -WindowHandle ([IntPtr]::new(1)) -ApplyDwm {
                throw 'DWM unavailable'
            }
            $result | Should -BeFalse
        } | Should -Not -Throw
    }
}
