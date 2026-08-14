BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:CompanionRoot = Join-Path $script:RepoRoot 'companion'
    $script:InstallScript = Join-Path $script:RepoRoot 'installer\scripts\Install-Package.ps1'
    $script:UninstallScript = Join-Path $script:RepoRoot 'installer\scripts\Prepare-Uninstall.ps1'
}

Describe 'installer package support scripts' {
    It 'installs a staged payload with sanitized JSON output' {
        Test-Path -LiteralPath $InstallScript -PathType Leaf | Should -BeTrue
        $localAppData = Join-Path $TestDrive 'LocalAppData'
        $startup = Join-Path $TestDrive 'Startup'
        $programRoot = Join-Path $localAppData 'Programs\CodexQuotaMonitor'
        $payload = Join-Path $programRoot 'payload'
        $null = New-Item -ItemType Directory -Path $programRoot, $startup -Force
        Copy-Item -LiteralPath $CompanionRoot -Destination $payload -Recurse

        $output = & (Get-Process -Id $PID).Path `
            -NoLogo -NoProfile -NonInteractive `
            -File $InstallScript `
            -ProgramRoot $programRoot `
            -LocalAppData $localAppData `
            -Startup $startup `
            -PwshPath (Get-Process -Id $PID).Path `
            -SkipStart
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json

        $result.Operation | Should -BeExactly 'Install'
        $result.AppPath | Should -BeExactly (Join-Path $programRoot 'app')
        ($output -join "`n") | Should -Not -Match '(?i)token|authorization|cookie|raw|relay-providers'
    }

    It 'prepares uninstall while leaving program files for Inno' {
        Test-Path -LiteralPath $UninstallScript -PathType Leaf | Should -BeTrue
        $localAppData = Join-Path $TestDrive 'Uninstall LocalAppData'
        $startup = Join-Path $TestDrive 'Uninstall Startup'
        $programRoot = Join-Path $localAppData 'Programs\CodexQuotaMonitor'
        $payload = Join-Path $programRoot 'payload'
        $null = New-Item -ItemType Directory -Path $programRoot, $startup -Force
        Copy-Item -LiteralPath $CompanionRoot -Destination $payload -Recurse
        $null = & (Get-Process -Id $PID).Path `
            -NoLogo -NoProfile -NonInteractive `
            -File $InstallScript `
            -ProgramRoot $programRoot `
            -LocalAppData $localAppData `
            -Startup $startup `
            -PwshPath (Get-Process -Id $PID).Path `
            -SkipStart

        $output = & (Get-Process -Id $PID).Path `
            -NoLogo -NoProfile -NonInteractive `
            -File $UninstallScript `
            -ProgramRoot $programRoot `
            -LocalAppData $localAppData `
            -Startup $startup `
            -PreserveData
        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json

        $result.Operation | Should -BeExactly 'Uninstall'
        $result.PreservedProgramFiles | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $programRoot 'app\CodexQuotaMonitor.psd1') |
            Should -BeTrue
    }
}
