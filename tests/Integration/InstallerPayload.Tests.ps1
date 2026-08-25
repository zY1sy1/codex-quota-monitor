BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:PayloadScript = Join-Path $script:RepoRoot 'build\New-InstallerPayload.ps1'
}

Describe 'installer payload staging' {
    It 'copies only the approved application distribution files' {
        Test-Path -LiteralPath $PayloadScript -PathType Leaf | Should -BeTrue
        $runtime = Join-Path $TestDrive 'runtime'
        $destination = Join-Path $TestDrive 'staging'
        $null = New-Item -ItemType Directory -Path $runtime -Force
        [IO.File]::WriteAllBytes((Join-Path $runtime 'pwsh.exe'), [byte[]](0x4d, 0x5a))
        [IO.File]::WriteAllText((Join-Path $runtime 'LICENSE.txt'), 'PowerShell license')

        $result = & $PayloadScript `
            -RepoRoot $RepoRoot `
            -RuntimeRoot $runtime `
            -Destination $destination `
            -Version '0.1.0-test' `
            -GitCommit ('a' * 40) `
            -Dirty

        Test-Path (Join-Path $destination 'payload\CodexQuotaMonitor.psd1') | Should -BeTrue
        Test-Path (Join-Path $destination 'runtime\pwsh\pwsh.exe') | Should -BeTrue
        Test-Path (Join-Path $destination 'assets\CodexQuotaMonitor.ico') | Should -BeTrue
        Test-Path (Join-Path $destination 'installer\Install-Package.ps1') | Should -BeTrue
        Test-Path (Join-Path $destination 'licenses\PowerShell-LICENSE.txt') | Should -BeTrue
        Test-Path (Join-Path $destination '.git') | Should -BeFalse
        Test-Path (Join-Path $destination 'tests') | Should -BeFalse
        Test-Path (Join-Path $destination 'outputs') | Should -BeFalse

        $manifest = Get-Content (Join-Path $destination 'installer-manifest.json') -Raw |
            ConvertFrom-Json
        $manifest.Version | Should -BeExactly '0.1.0-test'
        $manifest.GitCommit | Should -BeExactly ('a' * 40)
        $manifest.Dirty | Should -BeTrue
        $manifest.RelayHostSha256 | Should -Match '^[0-9A-F]{64}$'
        $result.StagingRoot | Should -BeExactly ([IO.Path]::GetFullPath($destination))

        @(Get-ChildItem $destination -Recurse -File | Where-Object {
                $_.Name -match '^(settings|health|relay-providers|relay-cache)\.json$' -or
                $_.Extension -eq '.log'
            }).Count | Should -Be 0
    }
}
