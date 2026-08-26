BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\companion\Private\WindowIcon.ps1')
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
}

Describe 'Get-MonitorAppIconPath' {
    It 'resolves the development icon asset next to the repository root' {
        $path = Get-MonitorAppIconPath

        $path | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        [IO.Path]::GetExtension($path) | Should -BeExactly '.ico'
    }

    It 'prefers the installed CodexQuotaMonitor.ico when it exists beside the app' {
        $moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $programRoot = Split-Path -Parent $moduleRoot
        $installed = Join-Path $programRoot 'assets\CodexQuotaMonitor.ico'
        if (Test-Path -LiteralPath $installed -PathType Leaf) {
            Get-MonitorAppIconPath | Should -BeExactly $installed
        }
        else {
            Set-ItResult -Skipped -Because 'no installed icon layout in this workspace'
        }
    }
}

Describe 'ConvertTo-MonitorWindowIconSource' {
    It 'converts an existing icon file into a non-empty ImageSource' {
        $path = Get-MonitorAppIconPath
        $source = ConvertTo-MonitorWindowIconSource -Path $path

        $source | Should -Not -BeNullOrEmpty
        $source | Should -BeOfType ([Windows.Media.Imaging.BitmapSource])
        $source.Width | Should -BeGreaterThan 0
        $source.Height | Should -BeGreaterThan 0
    }

    It 'returns null for a missing path' {
        ConvertTo-MonitorWindowIconSource -Path (Join-Path $TestDrive 'missing.ico') | Should -BeNullOrEmpty
    }

    It 'returns null for an empty path' {
        ConvertTo-MonitorWindowIconSource -Path $null | Should -BeNullOrEmpty
        ConvertTo-MonitorWindowIconSource -Path [string]::Empty | Should -BeNullOrEmpty
    }
}
