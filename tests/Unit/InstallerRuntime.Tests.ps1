BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:LockPath = Join-Path $script:RepoRoot 'installer\runtime-lock.json'
    $script:AcquirePath = Join-Path $script:RepoRoot 'build\Acquire-PowerShellRuntime.ps1'
}

Describe 'bundled PowerShell runtime lock' {
    It 'pins the approved PowerShell 7.6.4 x64 archive and digest' {
        Test-Path -LiteralPath $LockPath -PathType Leaf | Should -BeTrue
        $lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json

        @($lock.PSObject.Properties.Name) | Should -Be @(
            'SchemaVersion', 'Version', 'Architecture', 'ArchiveName',
            'AssetUrl', 'ArchiveSha256', 'LicenseFile'
        )
        $lock.SchemaVersion | Should -Be 1
        $lock.Version | Should -BeExactly '7.6.4'
        $lock.Architecture | Should -BeExactly 'x64'
        $lock.ArchiveName | Should -BeExactly 'PowerShell-7.6.4-win-x64.zip'
        $lock.AssetUrl | Should -BeExactly 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.4/PowerShell-7.6.4-win-x64.zip'
        $lock.ArchiveSha256 | Should -BeExactly '80832551C52809301E6071C8BAC977BEB5A2F1EC953EB4DB9F94DEB953333793'
        $lock.LicenseFile | Should -BeExactly 'LICENSE.txt'
    }

    It 'ships an acquisition script with explicit cache and destination inputs' {
        Test-Path -LiteralPath $AcquirePath -PathType Leaf | Should -BeTrue
        $command = Get-Command $AcquirePath
        @($command.Parameters.Keys) | Should -Contain 'LockPath'
        @($command.Parameters.Keys) | Should -Contain 'CacheRoot'
        @($command.Parameters.Keys) | Should -Contain 'Destination'
    }

    It 'uses curl with bounded retries instead of the proxy-stalling web cmdlet' {
        $source = Get-Content -LiteralPath $AcquirePath -Raw

        $source | Should -Match 'curl\.exe'
        $source | Should -Match '--retry'
        $source | Should -Not -Match 'Invoke-WebRequest'
    }

    It 'lets the installed entry script discover its packaged program root' {
        $entrySource = Get-Content (Join-Path $RepoRoot 'companion\Start-CodexQuotaMonitor.ps1') -Raw

        $entrySource | Should -Match 'installer-manifest\.json'
        $entrySource | Should -Match '\$runtimeArguments\[''ProgramRoot''\]'
    }
}
