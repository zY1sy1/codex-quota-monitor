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
    It 'prefers the stable current-user WindowsApps alias when valid and otherwise returns a valid fallback' {
        $expected = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'

        $resolved = Resolve-MonitorPwshPath -ProbeTimeoutMilliseconds 5000

        if (Test-MonitorPwshExecutable -Path $expected -TimeoutMilliseconds 5000) {
            $resolved | Should -BeExactly ([IO.Path]::GetFullPath($expected))
        }
        else {
            [IO.Path]::IsPathFullyQualified($resolved) | Should -BeTrue
        }
        Test-MonitorPwshExecutable -Path $resolved -TimeoutMilliseconds 5000 | Should -BeTrue
    }

    It 'falls back to a probed absolute Get-Command application path' {
        $missingLocalAppData = Join-Path $TestDrive 'no alias here'

        $resolved = Resolve-MonitorPwshPath -LocalAppData $missingLocalAppData -ProbeTimeoutMilliseconds 5000

        [IO.Path]::IsPathFullyQualified($resolved) | Should -BeTrue
        Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue
        Test-MonitorPwshExecutable -Path $resolved -TimeoutMilliseconds 5000 | Should -BeTrue
    }

    It 'rejects Windows PowerShell 5.1 even when that host exits successfully' {
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 is unavailable on this host.'
            return
        }

        Test-MonitorPwshExecutable -Path $windowsPowerShell -TimeoutMilliseconds 5000 | Should -BeFalse
    }

    It 'bounds the whole probe when a descendant inherits redirected output handles' {
        $pwshPath = (Get-Process -Id $PID).Path
        $childPidPath = Join-Path $TestDrive 'inherited-output-child.pid'
        $escapedPidPath = $childPidPath.Replace("'", "''")
        $probeMarker = 'CODEX_QUOTA_MONITOR_PWSH_CORE_7'
        $probeCommand = @"
`$childStart = [Diagnostics.ProcessStartInfo]::new()
`$childStart.FileName = (Get-Process -Id `$PID).Path
`$childStart.UseShellExecute = `$false
`$childStart.CreateNoWindow = `$true
`$childStart.ArgumentList.Add('-NoLogo')
`$childStart.ArgumentList.Add('-NoProfile')
`$childStart.ArgumentList.Add('-Command')
`$childStart.ArgumentList.Add('Start-Sleep -Seconds 30')
`$child = [Diagnostics.Process]::Start(`$childStart)
[IO.File]::WriteAllText('$escapedPidPath', `$child.Id.ToString([Globalization.CultureInfo]::InvariantCulture))
[Console]::Out.Write('$probeMarker')
exit 0
"@

        $childPid = $null
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $result = Test-MonitorPwshExecutable `
                -Path $pwshPath `
                -TimeoutMilliseconds 500 `
                -ProbeCommand $probeCommand
            $stopwatch.Stop()

            $result | Should -BeFalse
            $stopwatch.ElapsedMilliseconds | Should -BeLessThan 3000
            Test-Path -LiteralPath $childPidPath -PathType Leaf | Should -BeTrue
            $childPid = [int][IO.File]::ReadAllText($childPidPath)

            $child = Get-Process -Id $childPid -ErrorAction SilentlyContinue
            if ($null -ne $child) {
                try {
                    $child.WaitForExit(5000) | Should -BeTrue
                }
                finally {
                    $child.Dispose()
                }
            }
            Get-Process -Id $childPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
        finally {
            $stopwatch.Stop()
            if ($null -ne $childPid) {
                Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'console-free launcher' {
    It 'detaches a hidden PowerShell monitor from the GUI launcher' {
        $wscriptPath = Join-Path ([Environment]::SystemDirectory) 'wscript.exe'
        $pwshPath = (Get-Process -Id $PID).Path
        $directory = Join-Path $TestDrive '启动 项目 & quota monitor'
        $launcherPath = Join-Path $PSScriptRoot '..\..\companion\Start-CodexQuotaMonitor.vbs'
        $entryPath = Join-Path $directory '启动 Codex & monitor.ps1'
        $markerPath = Join-Path $directory '子进程 pid.txt'
        $escapedMarkerPath = $markerPath.Replace("'", "''")
        $null = New-Item -ItemType Directory -Path $directory -Force
        $entryContent = @"
[IO.File]::WriteAllText('$escapedMarkerPath', `$PID.ToString([Globalization.CultureInfo]::InvariantCulture), [Text.UTF8Encoding]::new(`$false))
Start-Sleep -Seconds 30
"@
        [IO.File]::WriteAllText($entryPath, $entryContent, [Text.UTF8Encoding]::new($false))

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $wscriptPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        foreach ($argument in @(
                '//B'
                '//NoLogo'
                $launcherPath
                $pwshPath
                $entryPath
            )) {
            $startInfo.ArgumentList.Add([string]$argument)
        }

        $launcher = $null
        $childPid = $null
        $waiter = [Threading.ManualResetEventSlim]::new($false)
        try {
            $launcher = [Diagnostics.Process]::Start($startInfo)
            $launcher.WaitForExit(5000) | Should -BeTrue

            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
            while (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -and
                [DateTimeOffset]::UtcNow -lt $deadline) {
                $null = $waiter.Wait(20)
            }

            Test-Path -LiteralPath $markerPath -PathType Leaf | Should -BeTrue
            $childPid = [int][IO.File]::ReadAllText($markerPath)
            $child = Get-Process -Id $childPid -ErrorAction SilentlyContinue
            $child | Should -Not -BeNullOrEmpty
            try {
                $child.MainWindowHandle | Should -Be 0
            }
            finally {
                $child.Dispose()
            }
        }
        finally {
            $waiter.Dispose()
            if ($null -ne $launcher) {
                $launcher.Dispose()
            }
            if ($null -ne $childPid) {
                Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue
            }
        }
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
        $launcherScript = Join-Path $entryDirectory 'Start-CodexQuotaMonitor.vbs'
        $wscriptPath = [IO.Path]::GetFullPath((Join-Path ([Environment]::SystemDirectory) 'wscript.exe'))
        $null = New-Item -ItemType Directory -Path $entryDirectory -Force
        [IO.File]::WriteAllText($firstEntry, '# first', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($secondEntry, '# second', [Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\companion\Start-CodexQuotaMonitor.vbs') `
            -Destination $launcherScript

        $created = New-MonitorStartupShortcut `
            -ShortcutPath $shortcutPath `
            -EntryScript $firstEntry `
            -PwshPath $pwshPath

        $created.ShortcutPath | Should -BeExactly ([IO.Path]::GetFullPath($shortcutPath))
        $created.PwshPath | Should -BeExactly ([IO.Path]::GetFullPath($pwshPath))
        $created.WscriptPath | Should -BeExactly $wscriptPath
        $created.LauncherScript | Should -BeExactly ([IO.Path]::GetFullPath($launcherScript))
        Test-Path -LiteralPath $shortcutPath -PathType Leaf | Should -BeTrue

        $first = Read-TestShortcut -Path $shortcutPath
        $first.TargetPath | Should -Be $wscriptPath
        $first.Arguments | Should -BeExactly "//B //NoLogo `"$([IO.Path]::GetFullPath($launcherScript))`" `"$([IO.Path]::GetFullPath($pwshPath))`" `"$([IO.Path]::GetFullPath($firstEntry))`""
        $first.Arguments | Should -Not -Match '(?i)ExecutionPolicy'
        $first.WorkingDirectory | Should -BeExactly ([IO.Path]::GetFullPath($entryDirectory))
        $first.Description | Should -BeExactly 'Codex quota monitor'

        $updated = New-MonitorStartupShortcut `
            -ShortcutPath $shortcutPath `
            -EntryScript $secondEntry `
            -PwshPath $pwshPath
        $updated.ShortcutPath | Should -BeExactly ([IO.Path]::GetFullPath($shortcutPath))
        $updated.WscriptPath | Should -BeExactly $wscriptPath
        $updated.LauncherScript | Should -BeExactly ([IO.Path]::GetFullPath($launcherScript))

        $second = Read-TestShortcut -Path $shortcutPath
        $second.TargetPath | Should -Be $wscriptPath
        $second.Arguments | Should -BeExactly "//B //NoLogo `"$([IO.Path]::GetFullPath($launcherScript))`" `"$([IO.Path]::GetFullPath($pwshPath))`" `"$([IO.Path]::GetFullPath($secondEntry))`""
        $second.WorkingDirectory | Should -BeExactly ([IO.Path]::GetFullPath($entryDirectory))

        Remove-MonitorStartupShortcut -ShortcutPath $shortcutPath
        Test-Path -LiteralPath $shortcutPath | Should -BeFalse
        Remove-MonitorStartupShortcut -ShortcutPath $shortcutPath
    }
}
