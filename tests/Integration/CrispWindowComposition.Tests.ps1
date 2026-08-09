Describe 'crisp transparent quota windows' {
    It 'keeps <File> free of DWM blur setup' -TestCases @(
        @{ File = 'WpfView.ps1' }
        @{ File = 'CompactBarView.ps1' }
        @{ File = 'QuotaOrbView.ps1' }
    ) {
        param($File)

        $path = Join-Path $PSScriptRoot "..\..\companion\Private\$File"
        $source = Get-Content -LiteralPath $path -Raw

        $source | Should -Not -Match 'Enable-MonitorWindowBlur|EnableBlur|SourceInitialized'
    }
}
