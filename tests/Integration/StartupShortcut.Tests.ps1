BeforeAll {
    $script:StartupShortcutPath = Join-Path $PSScriptRoot '..\..\companion\Private\StartupShortcut.ps1'
    if (Test-Path -LiteralPath $script:StartupShortcutPath -PathType Leaf) {
        . $script:StartupShortcutPath
    }

    function Read-TestShortcut {
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        $shell = $null
        $shortcut = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($Path)
            return [pscustomobject]@{
                TargetPath = [string]$shortcut.TargetPath
                Arguments = [string]$shortcut.Arguments
                WorkingDirectory = [string]$shortcut.WorkingDirectory
                Description = [string]$shortcut.Description
            }
        }
        finally {
            if ($null -ne $shortcut) {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
            }
            if ($null -ne $shell) {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
            }
        }
    }
}

Describe 'PowerShell executable resolution' {
    It 'probes and prefers the stable current-user WindowsApps alias' {
        $expected = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
        Test-Path -LiteralPath $expected -PathType Leaf | Should -BeTrue

        $resolved = Resolve-MonitorPwshPath -ProbeTimeoutMilliseconds 5000

        $resolved | Should -BeExactly ([IO.Path]::GetFullPath($expected))
        Test-MonitorPwshExecutable -Path $resolved -TimeoutMilliseconds 5000 | Should -BeTrue
    }

    It 'falls back to a probed absolute Get-Command application path' {
        $missingLocalAppData = Join-Path $TestDrive 'no alias here'

        $resolved = Resolve-MonitorPwshPath -LocalAppData $missingLocalAppData -ProbeTimeoutMilliseconds 5000

        [IO.Path]::IsPathFullyQualified($resolved) | Should -BeTrue
        Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue
        Test-MonitorPwshExecutable -Path $resolved -TimeoutMilliseconds 5000 | Should -BeTrue
    }
}

Describe 'current-user Startup shortcut' {
    It 'creates, reopens, overwrites, and removes a real shortcut without retaining COM locks' {
        $pwshPath = Resolve-MonitorPwshPath -ProbeTimeoutMilliseconds 5000
        $directory = Join-Path $TestDrive '启动 项目 & quota monitor'
        $entryDirectory = Join-Path $directory '应用 & scripts'
        $shortcutPath = Join-Path $directory 'Codex 额度监视器.lnk'
        $firstEntry = Join-Path $entryDirectory '启动 Codex & monitor.ps1'
        $secondEntry = Join-Path $entryDirectory '修复 Codex & monitor.ps1'
        $null = New-Item -ItemType Directory -Path $entryDirectory -Force
        [IO.File]::WriteAllText($firstEntry, '# first', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($secondEntry, '# second', [Text.UTF8Encoding]::new($false))

        $created = New-MonitorStartupShortcut `
            -ShortcutPath $shortcutPath `
            -EntryScript $firstEntry `
            -PwshPath $pwshPath

        $created.ShortcutPath | Should -BeExactly ([IO.Path]::GetFullPath($shortcutPath))
        $created.PwshPath | Should -BeExactly ([IO.Path]::GetFullPath($pwshPath))
        Test-Path -LiteralPath $shortcutPath -PathType Leaf | Should -BeTrue

        $first = Read-TestShortcut -Path $shortcutPath
        $first.TargetPath | Should -BeExactly ([IO.Path]::GetFullPath($pwshPath))
        $first.Arguments | Should -BeExactly "-NoLogo -NoProfile -NonInteractive -Sta -WindowStyle Hidden -File `"$([IO.Path]::GetFullPath($firstEntry))`""
        $first.Arguments | Should -Not -Match '(?i)ExecutionPolicy'
        $first.WorkingDirectory | Should -BeExactly ([IO.Path]::GetFullPath($entryDirectory))
        $first.Description | Should -BeExactly 'Codex quota monitor'

        $updated = New-MonitorStartupShortcut `
            -ShortcutPath $shortcutPath `
            -EntryScript $secondEntry `
            -PwshPath $pwshPath
        $updated.ShortcutPath | Should -BeExactly ([IO.Path]::GetFullPath($shortcutPath))

        $second = Read-TestShortcut -Path $shortcutPath
        $second.Arguments | Should -BeExactly "-NoLogo -NoProfile -NonInteractive -Sta -WindowStyle Hidden -File `"$([IO.Path]::GetFullPath($secondEntry))`""
        $second.WorkingDirectory | Should -BeExactly ([IO.Path]::GetFullPath($entryDirectory))

        Remove-MonitorStartupShortcut -ShortcutPath $shortcutPath
        Test-Path -LiteralPath $shortcutPath | Should -BeFalse
        Remove-MonitorStartupShortcut -ShortcutPath $shortcutPath
    }
}
