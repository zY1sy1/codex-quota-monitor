Describe 'test harness' {
    It 'runs under PowerShell 7 in STA on Windows' {
        $PSVersionTable.PSVersion.Major | Should -BeGreaterOrEqual 7
        $IsWindows | Should -BeTrue
        [Threading.Thread]::CurrentThread.GetApartmentState().ToString() | Should -Be 'STA'
    }
}
