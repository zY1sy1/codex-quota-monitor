BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:BuildScript = Join-Path $script:RepoRoot 'build\Build-WindowsInstaller.ps1'
    $script:ValidationScript = Join-Path $script:RepoRoot 'build\Test-WindowsInstaller.ps1'
    $script:TestRouter = Join-Path $script:RepoRoot 'build\Test.ps1'
}

Describe 'Windows installer build pipeline' {
    It 'ships build and validation entry points plus an Installer test suite' {
        Test-Path -LiteralPath $BuildScript -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $ValidationScript -PathType Leaf | Should -BeTrue
        (Get-Content -LiteralPath $TestRouter -Raw) | Should -Match "'Installer'"
    }

    It 'normalizes display, numeric, and output versions deterministically' {
        Test-Path -LiteralPath $BuildScript -PathType Leaf | Should -BeTrue
        if (-not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) { return }
        . $BuildScript

        $version = ConvertTo-InstallerVersion -Version '0.1.0+codex.20260801051004'

        $version.DisplayVersion | Should -BeExactly '0.1.0+codex.20260801051004'
        $version.NumericVersion | Should -BeExactly '0.1.0.51004'
        $version.OutputBaseName |
            Should -BeExactly 'CodexQuotaMonitor-Setup-0.1.0+codex.20260801051004-x64'
    }

    It 'labels dirty development manifests and rejects dirty release builds' {
        Test-Path -LiteralPath $BuildScript -PathType Leaf | Should -BeTrue
        if (-not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) { return }
        . $BuildScript

        { Assert-InstallerBuildConfiguration -Configuration Release -Dirty } |
            Should -Throw '*clean Git worktree*'

        $manifest = New-InstallerBuildManifest `
            -Version '1.2.3' `
            -NumericVersion '1.2.3.0' `
            -GitCommit '0123456789abcdef' `
            -Dirty `
            -PowerShellVersion '7.6.4' `
            -RelayHostSha256 ('A' * 64) `
            -SetupSha256 ('B' * 64) `
            -SetupFileName 'CodexQuotaMonitor-Setup-1.2.3-x64.exe'

        $manifest.Dirty | Should -BeTrue
        $manifest.SigningStatus | Should -BeExactly 'Unsigned'
    }

    It 'writes the setup digest in uppercase sha256sum format' {
        Test-Path -LiteralPath $BuildScript -PathType Leaf | Should -BeTrue
        if (-not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) { return }
        . $BuildScript
        $setupPath = Join-Path $TestDrive 'CodexQuotaMonitor-Setup-1.2.3-x64.exe'
        [IO.File]::WriteAllBytes($setupPath, [byte[]](1, 2, 3, 4))

        $result = Write-InstallerHashFile -SetupPath $setupPath
        $text = [IO.File]::ReadAllText($result.HashPath)

        $text | Should -Match '^[0-9A-F]{64}  CodexQuotaMonitor-Setup-1\.2\.3-x64\.exe\r?\n$'
        $result.Sha256 | Should -BeExactly ((Get-FileHash $setupPath -Algorithm SHA256).Hash)
    }

    It 'reports a bounded error when no Inno Setup compiler can be resolved' {
        Test-Path -LiteralPath $BuildScript -PathType Leaf | Should -BeTrue
        if (-not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) { return }
        . $BuildScript

        { Resolve-InnoCompiler `
                -ExplicitPath (Join-Path $TestDrive 'missing\ISCC.exe') `
                -PathValue '' `
                -StandardPaths @() } |
            Should -Throw '*Inno Setup 6 compiler*'
    }

    It 'prefers a cargo wrapper when command discovery returns multiple cargo shims' {
        Test-Path -LiteralPath $BuildScript -PathType Leaf | Should -BeTrue
        if (-not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) { return }
        . $BuildScript
        $exePath = Join-Path $TestDrive 'cargo.exe'
        $cmdPath = Join-Path $TestDrive 'cargo.cmd'
        $null = New-Item -ItemType File -Path $exePath, $cmdPath
        $commands = @(
            [pscustomobject]@{ Source = $cmdPath }
            [pscustomobject]@{ Source = $exePath }
        )

        Select-BuildCommandPath -Name 'Cargo' -Commands $commands -PreferWrapper |
            Should -BeExactly $cmdPath
    }
}
