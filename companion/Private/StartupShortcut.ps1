function Test-MonitorPwshExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateRange(100, 30000)]
        [int]$TimeoutMilliseconds = 5000,

        [Parameter(DontShow)]
        [AllowNull()]
        [string]$ProbeCommand
    )

    if (
        [string]::IsNullOrWhiteSpace($Path) -or
        -not [IO.Path]::IsPathFullyQualified($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)
    ) {
        return $false
    }

    $process = $null
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    try {
        $probeMarker = 'CODEX_QUOTA_MONITOR_PWSH_CORE_7'
        if ([string]::IsNullOrEmpty($ProbeCommand)) {
            $ProbeCommand = @"
if (`$PSVersionTable.PSEdition -eq 'Core' -and `$PSVersionTable.PSVersion.Major -ge 7) {
    [Console]::Out.Write('$probeMarker')
    exit 0
}
exit 17
"@
        }

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = [IO.Path]::GetFullPath($Path)
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.ArgumentList.Add('-NoLogo')
        $startInfo.ArgumentList.Add('-NoProfile')
        $startInfo.ArgumentList.Add('-Command')
        $startInfo.ArgumentList.Add($ProbeCommand)

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            return $false
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $remaining = $TimeoutMilliseconds - [int]$deadline.ElapsedMilliseconds
        if ($remaining -le 0 -or -not $process.WaitForExit($remaining)) {
            try {
                $process.Kill($true)
            }
            catch {
            }
            return $false
        }

        $remaining = $TimeoutMilliseconds - [int]$deadline.ElapsedMilliseconds
        $drainTask = [Threading.Tasks.Task]::WhenAll(
            [Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)
        )
        $drained = $false
        if ($remaining -gt 0) {
            try {
                $drained = $drainTask.Wait($remaining)
            }
            catch {
                $drained = $false
            }
        }
        if (-not $drained) {
            try {
                # Kill(true) also terminates descendants that still own inherited
                # pipe handles, even when the candidate itself has already exited.
                $process.Kill($true)
            }
            catch {
            }
            return $false
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()
        return $process.ExitCode -eq 0 -and $stdout -ceq $probeMarker
    }
    catch {
        return $false
    }
    finally {
        $deadline.Stop()
        if ($null -ne $process) {
            try {
                $process.StandardOutput.Dispose()
            }
            catch {
            }
            try {
                $process.StandardError.Dispose()
            }
            catch {
            }
            $process.Dispose()
        }
    }
}

function Resolve-MonitorPwshPath {
    [CmdletBinding()]
    param(
        [string]$LocalAppData = $env:LOCALAPPDATA,

        [ValidateRange(100, 30000)]
        [int]$ProbeTimeoutMilliseconds = 5000
    )

    $candidates = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($LocalAppData)) {
        $candidates.Add((Join-Path $LocalAppData 'Microsoft\WindowsApps\pwsh.exe'))
    }

    foreach ($command in @(Get-Command pwsh -CommandType Application -All -ErrorAction SilentlyContinue)) {
        $path = if ($null -ne $command.PSObject.Properties['Path']) {
            [string]$command.Path
        }
        elseif ($null -ne $command.PSObject.Properties['Source']) {
            [string]$command.Source
        }
        else {
            [string]$command.Definition
        }

        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $candidates.Add($path)
        }
    }

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        try {
            if (-not [IO.Path]::IsPathFullyQualified($candidate)) {
                continue
            }
            $fullPath = [IO.Path]::GetFullPath($candidate)
        }
        catch {
            continue
        }

        if (-not $seen.Add($fullPath)) {
            continue
        }
        if (Test-MonitorPwshExecutable -Path $fullPath -TimeoutMilliseconds $ProbeTimeoutMilliseconds) {
            return $fullPath
        }
    }

    throw [InvalidOperationException]::new('No launchable PowerShell 7 application was found for the current user.')
}

function Resolve-MonitorWscriptPath {
    [CmdletBinding()]
    param()

    $path = Join-Path ([Environment]::SystemDirectory) 'wscript.exe'
    if (-not [IO.Path]::IsPathFullyQualified($path) -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw [InvalidOperationException]::new(
            'The Windows Script Host executable required for console-free launch was not found.'
        )
    }

    return [IO.Path]::GetFullPath($path)
}

function New-MonitorStartupShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ShortcutPath,

        [Parameter(Mandatory)]
        [string]$EntryScript,

        [string]$PwshPath = (Resolve-MonitorPwshPath),

        [string]$LauncherScript,

        [AllowNull()]
        [string]$IconPath,

        [string]$Description = 'Codex quota monitor'
    )

    if (-not [IO.Path]::IsPathFullyQualified($ShortcutPath)) {
        throw [ArgumentException]::new('ShortcutPath must be an absolute path.', 'ShortcutPath')
    }
    if (-not $ShortcutPath.EndsWith('.lnk', [StringComparison]::OrdinalIgnoreCase)) {
        throw [ArgumentException]::new('ShortcutPath must end in .lnk.', 'ShortcutPath')
    }
    if (-not [IO.Path]::IsPathFullyQualified($EntryScript) -or -not (Test-Path -LiteralPath $EntryScript -PathType Leaf)) {
        throw [ArgumentException]::new('EntryScript must identify an existing absolute script path.', 'EntryScript')
    }
    if ([string]::IsNullOrWhiteSpace($LauncherScript)) {
        $LauncherScript = Join-Path (Split-Path -Parent $EntryScript) 'Start-CodexQuotaMonitor.vbs'
    }
    if (-not [IO.Path]::IsPathFullyQualified($LauncherScript) -or
        -not (Test-Path -LiteralPath $LauncherScript -PathType Leaf)) {
        throw [ArgumentException]::new(
            'LauncherScript must identify an existing absolute VBScript path.',
            'LauncherScript'
        )
    }
    if (
        -not [IO.Path]::IsPathFullyQualified($PwshPath) -or
        -not (Test-Path -LiteralPath $PwshPath -PathType Leaf) -or
        -not (Test-MonitorPwshExecutable -Path $PwshPath -TimeoutMilliseconds 5000)
    ) {
        throw [ArgumentException]::new('PwshPath must identify a launchable absolute PowerShell 7 path.', 'PwshPath')
    }

    $fullShortcutPath = [IO.Path]::GetFullPath($ShortcutPath)
    $fullEntryScript = [IO.Path]::GetFullPath($EntryScript)
    $fullLauncherScript = [IO.Path]::GetFullPath($LauncherScript)
    $fullPwshPath = [IO.Path]::GetFullPath($PwshPath)
    $fullIconPath = $null
    if (-not [string]::IsNullOrWhiteSpace($IconPath)) {
        if (-not [IO.Path]::IsPathFullyQualified($IconPath) -or
            -not (Test-Path -LiteralPath $IconPath -PathType Leaf)) {
            throw [ArgumentException]::new(
                'IconPath must identify an existing absolute icon path.',
                'IconPath'
            )
        }
        $fullIconPath = [IO.Path]::GetFullPath($IconPath)
    }
    $fullWscriptPath = Resolve-MonitorWscriptPath
    $arguments = "//B //NoLogo `"$fullLauncherScript`" `"$fullPwshPath`" `"$fullEntryScript`""
    $shortcutDirectory = Split-Path -Parent $fullShortcutPath
    $workingDirectory = Split-Path -Parent $fullEntryScript
    $null = New-Item -ItemType Directory -Path $shortcutDirectory -Force

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($fullShortcutPath)
        $shortcut.TargetPath = $fullWscriptPath
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $workingDirectory
        $shortcut.Description = $Description
        if ($null -ne $fullIconPath) {
            $shortcut.IconLocation = "$fullIconPath,0"
        }
        $shortcut.Save()
    }
    finally {
        if ($null -ne $shortcut) {
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
        }
        if ($null -ne $shell) {
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
        }
    }

    return [pscustomobject]@{
        ShortcutPath = $fullShortcutPath
        WscriptPath = $fullWscriptPath
        PwshPath = $fullPwshPath
        LauncherScript = $fullLauncherScript
        EntryScript = $fullEntryScript
        Arguments = $arguments
        WorkingDirectory = $workingDirectory
        Description = $Description
        IconPath = $fullIconPath
    }
}

function Remove-MonitorStartupShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ShortcutPath
    )

    if (Test-Path -LiteralPath $ShortcutPath -PathType Container) {
        throw [IOException]::new("Startup shortcut path '$ShortcutPath' identifies a directory.")
    }
    if (Test-Path -LiteralPath $ShortcutPath -PathType Leaf) {
        Remove-Item -LiteralPath $ShortcutPath -Force
    }
}
