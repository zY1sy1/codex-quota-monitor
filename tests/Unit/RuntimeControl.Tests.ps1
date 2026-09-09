BeforeAll {
    $path = Join-Path $PSScriptRoot '..\..\companion\Private\RuntimeControl.ps1'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        . $path
    }
}

Describe 'Test-MonitorWindowsSupport' {
    It 'reports the current host' {
        $os = Test-MonitorWindowsSupport
        $os | Should -Not -BeNullOrEmpty
        $os.PSObject.Properties.Name -join ',' |
            Should -BeExactly 'Supported,Major,Build,IsWindows10,IsWindows11'
        $os.Build | Should -BeGreaterOrEqual 19041
    }

    It 'accepts Windows 10 build 19041 and up' {
        (Test-MonitorWindowsSupport -OsVersion ([version]'10.0.19041')).Supported | Should -BeTrue
        (Test-MonitorWindowsSupport -OsVersion ([version]'10.0.19045')).Supported | Should -BeTrue
        (Test-MonitorWindowsSupport -OsVersion ([version]'10.0.19045')).IsWindows10 | Should -BeTrue
    }

    It 'accepts every Windows 11 build' {
        (Test-MonitorWindowsSupport -OsVersion ([version]'10.0.22000')).Supported | Should -BeTrue
        (Test-MonitorWindowsSupport -OsVersion ([version]'10.0.22631')).Supported | Should -BeTrue
        (Test-MonitorWindowsSupport -OsVersion ([version]'10.0.22000')).IsWindows11 | Should -BeTrue
    }

    It 'rejects older Windows 10 builds before 19041' {
        (Test-MonitorWindowsSupport -OsVersion ([version]'10.0.17763')).Supported | Should -BeFalse
        (Test-MonitorWindowsSupport -OsVersion ([version]'10.0.18363')).Supported | Should -BeFalse
    }

    It 'rejects pre-Windows-10 hosts' {
        (Test-MonitorWindowsSupport -OsVersion ([version]'6.2.9200')).Supported | Should -BeFalse
        (Test-MonitorWindowsSupport -OsVersion ([version]'6.3.9600')).Supported | Should -BeFalse
    }
}
