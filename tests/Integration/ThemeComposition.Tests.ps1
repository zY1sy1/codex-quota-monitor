BeforeAll {
    $script:ThemePath = Join-Path $PSScriptRoot '..\..\companion\Private\Theme.ps1'
    $script:XamlPath = Join-Path $PSScriptRoot '..\..\companion\UI\MainWindow.xaml'
    if (Test-Path -LiteralPath $script:ThemePath -PathType Leaf) {
        . $script:ThemePath
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
            'Track', 'Separator', 'Shadow', 'Warning', 'Danger'
        )
    }

    It 'uses transparent cohesive surfaces without opaque white borders' {
        $light = Get-MonitorThemePalette -Theme Light
        $dark = Get-MonitorThemePalette -Theme Dark

        $light.Surface | Should -BeExactly '#E6F4EFEA'
        $light.SurfaceStrong | Should -BeExactly '#D9EEE7E1'
        $light.TextPrimary | Should -BeExactly '#FF201F1D'
        $light.TextSecondary | Should -BeExactly '#FF6F6B67'
        $light.Accent | Should -BeExactly '#FF4DADB3'
        $dark.Surface | Should -BeExactly '#E6323A4C'
        $dark.SurfaceStrong | Should -BeExactly '#D93A4358'
        $dark.TextPrimary | Should -BeExactly '#FFF4F3F1'
        $dark.TextSecondary | Should -BeExactly '#FFAFB8CB'
        $dark.Accent | Should -BeExactly '#FF58C2C7'
        ($light.Values -join '|') | Should -Not -Match '#FFFFFFFF|#00FFFFFF'
        ($dark.Values -join '|') | Should -Not -Match '#FFFFFFFF|#00FFFFFF'
    }

    It 'keeps XAML free of hard white surfaces and decorative progress segments' {
        $xaml = Get-Content -LiteralPath $XamlPath -Raw

        $xaml | Should -Not -Match '(?i)(Background|BorderBrush)\s*=\s*"#FFFFFFFF"'
        $xaml | Should -Not -Match '(?i)x:Name\s*=\s*"[^\"]*(Segment|Separator)[^\"]*"'
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
