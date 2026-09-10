function Test-MonitorWindowsSupport {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$OsVersion = $null
    )

    if ($null -eq $OsVersion) {
        $OsVersion = [Environment]::OSVersion.Version
    }
    $major = [int]$OsVersion.Major
    $build = [int]$OsVersion.Build
    $isWindows10 = $major -eq 10 -and $build -ge 19041 -and $build -lt 22000
    $isWindows11 = $major -eq 10 -and $build -ge 22000
    [pscustomobject][ordered]@{
        Supported = [bool]($isWindows10 -or $isWindows11)
        Major = [int]$major
        Build = [int]$build
        IsWindows10 = [bool]$isWindows10
        IsWindows11 = [bool]$isWindows11
    }
}

function Assert-MonitorDesktopPrerequisites {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PwshPath)

    if (-not $IsWindows -or $PSVersionTable.PSEdition -ne 'Core' -or
        $PSVersionTable.PSVersion -lt [version]'7.4') {
        throw [PlatformNotSupportedException]::new(
            'Codex quota monitor installation requires PowerShell 7.4 or later on Windows.'
        )
    }

    $osSupport = Test-MonitorWindowsSupport
    if (-not $osSupport.Supported) {
        throw [PlatformNotSupportedException]::new(
            'Codex quota monitor requires Windows 10 (build 19041 or later) or Windows 11.'
        )
    }

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    }
    catch {
        throw [PlatformNotSupportedException]::new(
            'The Windows desktop UI assemblies required by Codex quota monitor are unavailable.'
        )
    }

    $probeCommand = @'
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion -ge [version]'7.4') {
    [Console]::Out.Write('CODEX_QUOTA_MONITOR_PWSH_CORE_7')
    exit 0
}
exit 17
'@
    if (-not (Test-MonitorPwshExecutable `
            -Path $PwshPath `
            -TimeoutMilliseconds 5000 `
            -ProbeCommand $probeCommand)) {
        throw [PlatformNotSupportedException]::new(
            'A launchable PowerShell 7.4 or later executable is required.'
        )
    }
}

function Invoke-MonitorInstanceSignal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstancePrefix,
        [ValidateSet('Activate', 'Exit')][string]$Signal
    )

    $probe = Enter-MonitorInstance -Prefix $InstancePrefix -Signal $Signal
    if ($probe.IsPrimary) {
        Close-MonitorInstance -Instance $probe
        return $false
    }

    return $true
}

function Test-MonitorInstanceRunning {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstancePrefix)

    $probe = Enter-MonitorInstance -Prefix $InstancePrefix -Signal None
    if ($probe.IsPrimary) {
        Close-MonitorInstance -Instance $probe
        return $false
    }

    return $true
}

function Wait-MonitorInstanceStopped {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstancePrefix,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $waiter = [Threading.ManualResetEventSlim]::new($false)
    try {
        do {
            if (-not (Test-MonitorInstanceRunning -InstancePrefix $InstancePrefix)) {
                return
            }
            $remaining = [int][Math]::Ceiling(
                ($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds
            )
            if ($remaining -le 0) {
                break
            }
            $null = $waiter.Wait([Math]::Min(50, $remaining))
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
    }
    finally {
        $waiter.Dispose()
    }

    throw [TimeoutException]::new('The running quota monitor did not stop within the allowed time.')
}

function Set-MonitorStartupPreference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][string]$RuntimeScriptPath,
        [AllowNull()][string]$PwshPath,
        [AllowNull()][string]$LauncherScript
    )

    if ($Enabled) {
        if ([string]::IsNullOrWhiteSpace($PwshPath)) {
            $localAppData = Split-Path -Parent $Paths.Root
            $PwshPath = Resolve-MonitorPwshPath -LocalAppData $localAppData
        }
        if ([string]::IsNullOrWhiteSpace($LauncherScript)) {
            $LauncherScript = Join-Path $Paths.App 'Start-CodexQuotaMonitor.vbs'
        }
        $null = New-MonitorStartupShortcut `
            -ShortcutPath $Paths.StartupShortcut `
            -EntryScript $RuntimeScriptPath `
            -PwshPath $PwshPath `
            -LauncherScript $LauncherScript
    }
    else {
        Remove-MonitorStartupShortcut -ShortcutPath $Paths.StartupShortcut
    }
}

function New-MonitorRuntimeStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string]$InstancePrefix
    )

    $entryScript = Join-Path $Paths.App 'Start-CodexQuotaMonitor.ps1'
    $localAppData = Split-Path -Parent $Paths.Root
    $startup = Split-Path -Parent $Paths.StartupShortcut
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [IO.Path]::GetFullPath($PwshPath)
    $startInfo.WorkingDirectory = [IO.Path]::GetFullPath($Paths.App)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    foreach ($argument in @(
            '-NoLogo'
            '-NoProfile'
            '-NonInteractive'
            '-Sta'
            '-WindowStyle'
            'Hidden'
            '-File'
            $entryScript
            '-LocalAppData'
            $localAppData
            '-Startup'
            $startup
            '-ProgramRoot'
            $Paths.ProgramRoot
            '-InstancePrefix'
            $InstancePrefix
        )) {
        $startInfo.ArgumentList.Add([string]$argument)
    }

    return $startInfo
}

function Wait-MonitorRuntimeHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][string]$InstancePrefix,
        [Parameter(Mandatory)][DateTimeOffset]$StartedAt,
        [AllowNull()][object]$Process,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $waiter = [Threading.ManualResetEventSlim]::new($false)
    try {
        do {
            $health = Read-MonitorHealthSnapshot -Path $Paths.Health
            if ($health.Valid -and $health.UpdatedAtValue -ge $StartedAt.AddSeconds(-2) -and
                (Test-MonitorInstanceRunning -InstancePrefix $InstancePrefix)) {
                return $health
            }

            if ($null -ne $Process -and $null -ne $Process.PSObject.Properties['HasExited']) {
                try {
                    if ([bool]$Process.HasExited) {
                        throw [InvalidOperationException]::new(
                            'The quota monitor process exited before publishing health.'
                        )
                    }
                }
                catch [InvalidOperationException] {
                    throw
                }
                catch {
                }
            }

            $remaining = [int][Math]::Ceiling(
                ($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds
            )
            if ($remaining -le 0) {
                break
            }
            $null = $waiter.Wait([Math]::Min(100, $remaining))
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
    }
    finally {
        $waiter.Dispose()
    }

    throw [TimeoutException]::new('The quota monitor did not publish valid health in time.')
}

function Start-MonitorInstalledRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string]$InstancePrefix,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15,
        [AllowNull()][scriptblock]$ProcessStarter
    )

    if (-not (Test-MonitorInstalledLayout -Paths $Paths)) {
        throw [InvalidOperationException]::new('Codex quota monitor is not installed.')
    }
    $null = Test-PackagedRelayHostIntegrity -RootPath $Paths.App
    if (Test-Path -LiteralPath $Paths.Health) {
        Remove-MonitorManagedItem -Path $Paths.Health -Root $Paths.Root
    }

    $startedAt = [DateTimeOffset]::UtcNow
    $startInfo = New-MonitorRuntimeStartInfo `
        -Paths $Paths `
        -PwshPath $PwshPath `
        -InstancePrefix $InstancePrefix
    $process = $null
    try {
        if ($null -eq $ProcessStarter) {
            $process = [Diagnostics.Process]::Start($startInfo)
        }
        else {
            $started = @(& $ProcessStarter $startInfo $Paths $InstancePrefix)
            if ($started.Count -ne 1) {
                throw [InvalidOperationException]::new('The monitor process starter returned an invalid result.')
            }
            $process = $started[0]
        }
        if ($null -eq $process) {
            throw [InvalidOperationException]::new('The quota monitor process could not be started.')
        }

        $null = Wait-MonitorRuntimeHealth `
            -Paths $Paths `
            -InstancePrefix $InstancePrefix `
            -StartedAt $startedAt `
            -Process $process `
            -TimeoutSeconds $TimeoutSeconds
    }
    finally {
        if ($null -ne $process -and $process -is [IDisposable]) {
            $process.Dispose()
        }
    }
}

function New-MonitorOperationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][bool]$Changed,
        [Parameter(Mandatory)][object]$Status,
        [AllowNull()][Collections.IDictionary]$Additional
    )

    $result = [ordered]@{
        Operation = $Operation
        Changed = $Changed
    }
    if ($null -ne $Additional) {
        foreach ($entry in $Additional.GetEnumerator()) {
            $result[$entry.Key] = $entry.Value
        }
    }
    foreach ($property in $Status.PSObject.Properties) {
        if (-not $result.Contains($property.Name)) {
            $result[$property.Name] = $property.Value
        }
    }

    return [pscustomobject]$result
}
