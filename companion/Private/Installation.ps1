$script:MonitorInstallationSourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Test-MonitorPathWithinRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [switch]$AllowRoot
    )

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    if ($AllowRoot -and $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $rootPrefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Remove-MonitorManagedItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [switch]$AllowRoot
    )

    if (-not (Test-MonitorPathWithinRoot -Path $Path -Root $Root -AllowRoot:$AllowRoot)) {
        throw [InvalidOperationException]::new('Refusing to remove a path outside the monitor installation root.')
    }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
}

function Get-MonitorManagementMutexName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $normalized = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ).ToUpperInvariant()
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    return 'Local\CodexQuotaMonitor.Management.' + $hash.Substring(0, 32)
}

function Enter-MonitorManagementMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    $name = Get-MonitorManagementMutexName -Root $Root
    $created = New-MonitorInstanceMutex -Name $name
    $mutex = $created.Handle
    $acquired = [bool]$created.CreatedNew
    try {
        if (-not $acquired) {
            try {
                $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
            }
            catch [Threading.AbandonedMutexException] {
                $acquired = $true
            }
        }
        if (-not $acquired) {
            throw [TimeoutException]::new('Another quota monitor management operation is still running.')
        }

        return [pscustomobject]@{
            Handle = $mutex
            Acquired = $true
        }
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-MonitorManagementMutex {
    [CmdletBinding()]
    param([AllowNull()][object]$Lease)

    if ($null -eq $Lease) {
        return
    }
    try {
        if ([bool]$Lease.Acquired) {
            $Lease.Handle.ReleaseMutex()
        }
    }
    finally {
        $Lease.Handle.Dispose()
    }
}

function Get-CodexQuotaMonitorStatus {
    [CmdletBinding()]
    param(
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$Startup = [Environment]::GetFolderPath('Startup'),
        [AllowNull()][string]$ProgramRoot,
        [ValidateNotNullOrEmpty()][string]$InstancePrefix = 'Local\CodexQuotaMonitor'
    )

    $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup -ProgramRoot $ProgramRoot
    $installed = Test-MonitorInstalledLayout -Paths $paths
    $running = $false
    try {
        $running = Test-MonitorInstanceRunning -InstancePrefix $InstancePrefix
    }
    catch {
        $running = $false
    }
    $startupEnabled = Test-Path -LiteralPath $paths.StartupShortcut -PathType Leaf
    $health = Read-MonitorHealthSnapshot -Path $paths.Health

    $status = if (-not $installed) {
        'NotInstalled'
    }
    elseif (-not $running) {
        'Stopped'
    }
    elseif (-not $health.Valid) {
        'Starting'
    }
    else {
        $health.Status
    }
    $errorCategory = if ($health.Present -and -not $health.Valid) {
        'HealthInvalid'
    }
    elseif (-not $health.Present -and $running) {
        'HealthMissing'
    }
    else {
        $health.LastErrorCategory
    }
    $errorMessage = if ($health.Present -and -not $health.Valid) {
        'The monitor health file is invalid.'
    }
    elseif (-not $health.Present -and $running) {
        'The running monitor has not published health yet.'
    }
    else {
        $health.LastErrorMessage
    }

    [pscustomobject][ordered]@{
        Installed = [bool]$installed
        Running = [bool]$running
        StartupEnabled = [bool]$startupEnabled
        Status = $status
        SchemaVersion = if ($health.Valid) { [int]$health.SchemaVersion } else { $null }
        PlanType = if ($health.Valid) { $health.PlanType } else { $null }
        QuotaWindowCount = if ($health.Valid) { [int]$health.QuotaWindowCount } else { [int]0 }
        LastSuccessAt = if ($health.Valid) { $health.LastSuccessAt } else { $null }
        LastErrorCategory = $errorCategory
        LastErrorMessage = $errorMessage
        ProcessId = if ($health.Valid) { $health.ProcessId } else { $null }
        UpdatedAt = if ($health.Valid) { $health.UpdatedAt } else { $null }
        RelayProviderCount = if ($health.Valid) { [int]$health.RelayProviderCount } else { [int]0 }
        RelayLiveCount = if ($health.Valid) { [int]$health.RelayLiveCount } else { [int]0 }
        RelayStaleCount = if ($health.Valid) { [int]$health.RelayStaleCount } else { [int]0 }
        RelayInvalidCount = if ($health.Valid) { [int]$health.RelayInvalidCount } else { [int]0 }
        RelayHostState = if ($health.Valid) { $health.RelayHostState } else { $null }
        DisplayMode = if ($health.Valid) { $health.DisplayMode } else { $null }
        Theme = if ($health.Valid) { $health.Theme } else { $null }
        Root = $paths.Root
        ProgramRoot = $paths.ProgramRoot
        AppPath = $paths.App
        SettingsPath = $paths.Settings
        HealthPath = $paths.Health
        LogDirectory = $paths.Logs
        ShortcutPath = $paths.StartupShortcut
    }
}

function Test-CodexQuotaMonitorHealth {
    [CmdletBinding()]
    param(
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$Startup = [Environment]::GetFolderPath('Startup'),
        [AllowNull()][string]$ProgramRoot,
        [ValidateNotNullOrEmpty()][string]$InstancePrefix = 'Local\CodexQuotaMonitor',
        [switch]$Live,
        [ValidateRange(1, 3600)][int]$MaximumAgeSeconds = 120
    )

    $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup -ProgramRoot $ProgramRoot
    $status = Get-CodexQuotaMonitorStatus `
        -LocalAppData $LocalAppData `
        -Startup $Startup `
        -ProgramRoot $ProgramRoot `
        -InstancePrefix $InstancePrefix
    $health = Read-MonitorHealthSnapshot -Path $paths.Health
    $fresh = $false
    if ($health.Valid) {
        $age = ([DateTimeOffset]::UtcNow - $health.UpdatedAtValue).TotalSeconds
        $fresh = $age -ge -300 -and $age -le $MaximumAgeSeconds
    }

    $healthy = $status.Installed -and $status.Running -and $health.Valid -and $fresh -and
        $health.Status -ne 'Error'
    if ($Live) {
        $healthy = $healthy -and $health.Status -eq 'Live' -and $health.QuotaWindowCount -gt 0
    }
    $reason = if (-not $status.Installed) {
        'NotInstalled'
    }
    elseif (-not $status.Running) {
        'NotRunning'
    }
    elseif (-not $health.Present) {
        'MissingHealth'
    }
    elseif (-not $health.Valid) {
        'InvalidHealth'
    }
    elseif (-not $fresh) {
        'StaleHealth'
    }
    elseif ($health.Status -eq 'Error') {
        'RuntimeError'
    }
    elseif ($Live -and ($health.Status -ne 'Live' -or $health.QuotaWindowCount -le 0)) {
        'NotLive'
    }
    else {
        'Healthy'
    }

    [pscustomobject][ordered]@{
        Healthy = [bool]$healthy
        LiveRequired = [bool]$Live
        Installed = [bool]$status.Installed
        Running = [bool]$status.Running
        HealthPresent = [bool]$health.Present
        HealthFresh = [bool]$fresh
        Status = $status.Status
        Reason = $reason
        SchemaVersion = if ($health.Valid) { [int]$health.SchemaVersion } else { $null }
        PlanType = if ($health.Valid) { $health.PlanType } else { $null }
        QuotaWindowCount = if ($health.Valid) { [int]$health.QuotaWindowCount } else { [int]0 }
        LastErrorCategory = $status.LastErrorCategory
        LastErrorMessage = $status.LastErrorMessage
        ProcessId = if ($health.Valid) { $health.ProcessId } else { $null }
        UpdatedAt = if ($health.Valid) { $health.UpdatedAt } else { $null }
        RelayProviderCount = if ($health.Valid) { [int]$health.RelayProviderCount } else { [int]0 }
        RelayLiveCount = if ($health.Valid) { [int]$health.RelayLiveCount } else { [int]0 }
        RelayStaleCount = if ($health.Valid) { [int]$health.RelayStaleCount } else { [int]0 }
        RelayInvalidCount = if ($health.Valid) { [int]$health.RelayInvalidCount } else { [int]0 }
        RelayHostState = if ($health.Valid) { $health.RelayHostState } else { $null }
        DisplayMode = if ($health.Valid) { $health.DisplayMode } else { $null }
        Theme = if ($health.Valid) { $health.Theme } else { $null }
    }
}

function Invoke-CodexQuotaMonitorInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Install', 'Repair')][string]$Operation,
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$LocalAppData,
        [string]$Startup,
        [AllowNull()][string]$ProgramRoot,
        [Parameter(Mandatory)][string]$InstancePrefix,
        [AllowNull()][string]$PwshPath,
        [ValidateRange(1, 120)][int]$TimeoutSeconds,
        [switch]$SkipStart,
        [AllowNull()][scriptblock]$ProcessStarter,
        [AllowNull()][scriptblock]$RollbackProcessStarter
    )

    $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup -ProgramRoot $ProgramRoot
    if ([string]::IsNullOrWhiteSpace($PwshPath)) {
        $PwshPath = Resolve-MonitorPwshPath -LocalAppData $LocalAppData
    }
    Assert-MonitorDesktopPrerequisites -PwshPath $PwshPath
    $source = Assert-MonitorSourceLayout -SourcePath $SourcePath -TargetRoot $paths.ProgramRoot

    $lease = Enter-MonitorManagementMutex -Root $paths.Root -TimeoutSeconds $TimeoutSeconds
    $publishState = $null
    $wasRunning = $false
    $shortcutWasPresent = Test-Path -LiteralPath $paths.StartupShortcut -PathType Leaf
    try {
        [IO.Directory]::CreateDirectory($paths.Root) | Out-Null
        [IO.Directory]::CreateDirectory($paths.ProgramRoot) | Out-Null
        [IO.Directory]::CreateDirectory($paths.Data) | Out-Null
        [IO.Directory]::CreateDirectory($paths.Logs) | Out-Null
        if (-not (Test-Path -LiteralPath $paths.Settings -PathType Leaf)) {
            Write-MonitorSettings -Path $paths.Settings -Settings (New-DefaultSettings)
        }
        $settings = Read-MonitorSettings -Path $paths.Settings

        $wasRunning = Invoke-MonitorInstanceSignal `
            -InstancePrefix $InstancePrefix `
            -Signal Exit
        if ($wasRunning) {
            Wait-MonitorInstanceStopped `
                -InstancePrefix $InstancePrefix `
                -TimeoutSeconds $TimeoutSeconds
        }

        $publishState = Publish-MonitorApplication -SourcePath $source -Paths $paths
        $entryScript = Join-Path $paths.App 'Start-CodexQuotaMonitor.ps1'
        Set-MonitorStartupPreference `
            -Enabled ([bool]$settings.Startup) `
            -Paths $paths `
            -RuntimeScriptPath $entryScript `
            -PwshPath $PwshPath `
            -LauncherScript (Join-Path $paths.App 'Start-CodexQuotaMonitor.vbs')

        if (-not $SkipStart) {
            Start-MonitorInstalledRuntime `
                -Paths $paths `
                -PwshPath $PwshPath `
                -InstancePrefix $InstancePrefix `
                -TimeoutSeconds $TimeoutSeconds `
                -ProcessStarter $ProcessStarter
        }

        $status = Get-CodexQuotaMonitorStatus `
            -LocalAppData $LocalAppData `
            -Startup $Startup `
            -ProgramRoot $ProgramRoot `
            -InstancePrefix $InstancePrefix
        $result = New-MonitorOperationResult `
            -Operation $Operation `
            -Changed $true `
            -Status $status `
            -Additional $null
        if (-not $SkipStart -and
            -not $paths.LegacyApp.Equals($paths.App, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $paths.LegacyApp -PathType Container)) {
            Remove-MonitorManagedItem -Path $paths.LegacyApp -Root $paths.Root
        }
        Complete-MonitorPublishedApplication -Paths $paths -PublishState $publishState
        return $result
    }
    catch {
        $failure = $_
        $rollbackErrors = [Collections.Generic.List[Exception]]::new()
        if ($null -ne $publishState -and -not $SkipStart) {
            try {
                if (Invoke-MonitorInstanceSignal -InstancePrefix $InstancePrefix -Signal Exit) {
                    Wait-MonitorInstanceStopped `
                        -InstancePrefix $InstancePrefix `
                        -TimeoutSeconds $TimeoutSeconds
                }
            }
            catch {
                $rollbackErrors.Add($_.Exception)
            }
        }
        $applicationRestored = $null -eq $publishState -and
            (Test-MonitorInstalledLayout -Paths $paths)
        if ($null -ne $publishState) {
            try {
                Restore-MonitorPublishedApplication -Paths $paths -PublishState $publishState
                $applicationRestored = $true
            }
            catch {
                $rollbackErrors.Add($_.Exception)
            }
        }
        try {
            $restoredEntry = Join-Path $paths.App 'Start-CodexQuotaMonitor.ps1'
            if ($shortcutWasPresent -and (Test-Path -LiteralPath $restoredEntry -PathType Leaf)) {
                Set-MonitorStartupPreference `
                    -Enabled $true `
                    -Paths $paths `
                    -RuntimeScriptPath $restoredEntry `
                    -PwshPath $PwshPath
            }
            else {
                Set-MonitorStartupPreference `
                    -Enabled $false `
                    -Paths $paths `
                    -RuntimeScriptPath $restoredEntry `
                    -PwshPath $PwshPath
            }
        }
        catch {
            $rollbackErrors.Add($_.Exception)
        }
        if ($wasRunning -and $applicationRestored) {
            try {
                Start-MonitorInstalledRuntime `
                    -Paths $paths `
                    -PwshPath $PwshPath `
                    -InstancePrefix $InstancePrefix `
                    -TimeoutSeconds $TimeoutSeconds `
                    -ProcessStarter $RollbackProcessStarter
            }
            catch {
                $rollbackErrors.Add($_.Exception)
            }
        }

        if ($rollbackErrors.Count -gt 0) {
            $allErrors = [Collections.Generic.List[Exception]]::new()
            $allErrors.Add($failure.Exception)
            foreach ($rollbackError in $rollbackErrors) {
                $allErrors.Add($rollbackError)
            }
            throw [AggregateException]::new(
                "Codex quota monitor $Operation failed and rollback was incomplete.",
                $allErrors
            )
        }
        throw [InvalidOperationException]::new(
            "Codex quota monitor $Operation failed and was rolled back.",
            $failure.Exception
        )
    }
    finally {
        Exit-MonitorManagementMutex -Lease $lease
    }
}

function Install-CodexQuotaMonitor {
    [CmdletBinding()]
    param(
        [string]$SourcePath = $script:MonitorInstallationSourceRoot,
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$Startup = [Environment]::GetFolderPath('Startup'),
        [AllowNull()][string]$ProgramRoot,
        [ValidateNotNullOrEmpty()][string]$InstancePrefix = 'Local\CodexQuotaMonitor',
        [AllowNull()][string]$PwshPath,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15,
        [Parameter(DontShow)][switch]$SkipStart,
        [Parameter(DontShow)][AllowNull()][scriptblock]$ProcessStarter,
        [Parameter(DontShow)][AllowNull()][scriptblock]$RollbackProcessStarter
    )

    Invoke-CodexQuotaMonitorInstall `
        -Operation Install `
        -SourcePath $SourcePath `
        -LocalAppData $LocalAppData `
        -Startup $Startup `
        -ProgramRoot $ProgramRoot `
        -InstancePrefix $InstancePrefix `
        -PwshPath $PwshPath `
        -TimeoutSeconds $TimeoutSeconds `
        -SkipStart:$SkipStart `
        -ProcessStarter $ProcessStarter `
        -RollbackProcessStarter $RollbackProcessStarter
}

function Repair-CodexQuotaMonitor {
    [CmdletBinding()]
    param(
        [string]$SourcePath = $script:MonitorInstallationSourceRoot,
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$Startup = [Environment]::GetFolderPath('Startup'),
        [AllowNull()][string]$ProgramRoot,
        [ValidateNotNullOrEmpty()][string]$InstancePrefix = 'Local\CodexQuotaMonitor',
        [AllowNull()][string]$PwshPath,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15,
        [Parameter(DontShow)][switch]$SkipStart,
        [Parameter(DontShow)][AllowNull()][scriptblock]$ProcessStarter,
        [Parameter(DontShow)][AllowNull()][scriptblock]$RollbackProcessStarter
    )

    Invoke-CodexQuotaMonitorInstall `
        -Operation Repair `
        -SourcePath $SourcePath `
        -LocalAppData $LocalAppData `
        -Startup $Startup `
        -ProgramRoot $ProgramRoot `
        -InstancePrefix $InstancePrefix `
        -PwshPath $PwshPath `
        -TimeoutSeconds $TimeoutSeconds `
        -SkipStart:$SkipStart `
        -ProcessStarter $ProcessStarter `
        -RollbackProcessStarter $RollbackProcessStarter
}

function Start-CodexQuotaMonitor {
    [CmdletBinding()]
    param(
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$Startup = [Environment]::GetFolderPath('Startup'),
        [AllowNull()][string]$ProgramRoot,
        [ValidateNotNullOrEmpty()][string]$InstancePrefix = 'Local\CodexQuotaMonitor',
        [AllowNull()][string]$PwshPath,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15,
        [Parameter(DontShow)][AllowNull()][scriptblock]$ProcessStarter
    )

    $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup -ProgramRoot $ProgramRoot
    $lease = Enter-MonitorManagementMutex -Root $paths.Root -TimeoutSeconds $TimeoutSeconds
    try {
        if (-not (Test-MonitorInstalledLayout -Paths $paths)) {
            throw [InvalidOperationException]::new('Codex quota monitor is not installed.')
        }
        if (Invoke-MonitorInstanceSignal -InstancePrefix $InstancePrefix -Signal Activate) {
            $status = Get-CodexQuotaMonitorStatus `
                -LocalAppData $LocalAppData `
                -Startup $Startup `
                -ProgramRoot $ProgramRoot `
                -InstancePrefix $InstancePrefix
            return New-MonitorOperationResult `
                -Operation Start `
                -Changed $false `
                -Status $status `
                -Additional ([ordered]@{ SignalSent = $true })
        }

        if ([string]::IsNullOrWhiteSpace($PwshPath)) {
            $PwshPath = Resolve-MonitorPwshPath -LocalAppData $LocalAppData
        }
        Assert-MonitorDesktopPrerequisites -PwshPath $PwshPath
        Start-MonitorInstalledRuntime `
            -Paths $paths `
            -PwshPath $PwshPath `
            -InstancePrefix $InstancePrefix `
            -TimeoutSeconds $TimeoutSeconds `
            -ProcessStarter $ProcessStarter
        $status = Get-CodexQuotaMonitorStatus `
            -LocalAppData $LocalAppData `
            -Startup $Startup `
            -ProgramRoot $ProgramRoot `
            -InstancePrefix $InstancePrefix
        return New-MonitorOperationResult `
            -Operation Start `
            -Changed $true `
            -Status $status `
            -Additional ([ordered]@{ SignalSent = $false })
    }
    finally {
        Exit-MonitorManagementMutex -Lease $lease
    }
}

function Stop-CodexQuotaMonitor {
    [CmdletBinding()]
    param(
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$Startup = [Environment]::GetFolderPath('Startup'),
        [AllowNull()][string]$ProgramRoot,
        [ValidateNotNullOrEmpty()][string]$InstancePrefix = 'Local\CodexQuotaMonitor',
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15,
        [Parameter(DontShow)][switch]$Wait
    )

    $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup -ProgramRoot $ProgramRoot
    $lease = Enter-MonitorManagementMutex -Root $paths.Root -TimeoutSeconds $TimeoutSeconds
    try {
        $signalSent = Invoke-MonitorInstanceSignal `
            -InstancePrefix $InstancePrefix `
            -Signal Exit
        if ($signalSent -and $Wait) {
            Wait-MonitorInstanceStopped `
                -InstancePrefix $InstancePrefix `
                -TimeoutSeconds $TimeoutSeconds
        }
        $status = Get-CodexQuotaMonitorStatus `
            -LocalAppData $LocalAppData `
            -Startup $Startup `
            -ProgramRoot $ProgramRoot `
            -InstancePrefix $InstancePrefix
        return New-MonitorOperationResult `
            -Operation Stop `
            -Changed ([bool]$signalSent) `
            -Status $status `
            -Additional ([ordered]@{ SignalSent = [bool]$signalSent })
    }
    finally {
        Exit-MonitorManagementMutex -Lease $lease
    }
}

function Uninstall-CodexQuotaMonitor {
    [CmdletBinding()]
    param(
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$Startup = [Environment]::GetFolderPath('Startup'),
        [AllowNull()][string]$ProgramRoot,
        [ValidateNotNullOrEmpty()][string]$InstancePrefix = 'Local\CodexQuotaMonitor',
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15,
        [switch]$PreserveData,
        [Parameter(DontShow)][switch]$PreserveProgramFiles
    )

    $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup -ProgramRoot $ProgramRoot
    $lease = Enter-MonitorManagementMutex -Root $paths.Root -TimeoutSeconds $TimeoutSeconds
    try {
        $hadRoot = Test-Path -LiteralPath $paths.Root
        $hadProgramRoot = Test-Path -LiteralPath $paths.ProgramRoot
        $hadShortcut = Test-Path -LiteralPath $paths.StartupShortcut
        $signalSent = Invoke-MonitorInstanceSignal `
            -InstancePrefix $InstancePrefix `
            -Signal Exit
        if ($signalSent) {
            Wait-MonitorInstanceStopped `
                -InstancePrefix $InstancePrefix `
                -TimeoutSeconds $TimeoutSeconds
        }
        Remove-MonitorStartupShortcut -ShortcutPath $paths.StartupShortcut

        $separateProgramRoot = -not $paths.ProgramRoot.Equals(
            $paths.Root,
            [StringComparison]::OrdinalIgnoreCase
        )
        if (-not $PreserveProgramFiles -and $separateProgramRoot -and
            (Test-Path -LiteralPath $paths.ProgramRoot)) {
            Remove-MonitorManagedItem `
                -Path $paths.ProgramRoot `
                -Root $paths.ProgramRoot `
                -AllowRoot
        }

        if ($PreserveData) {
            if (Test-Path -LiteralPath $paths.Root -PathType Container) {
                foreach ($item in @(Get-ChildItem -LiteralPath $paths.Root -Force)) {
                    if ($item.Name -notin @('data', 'logs') -and
                        -not ($PreserveProgramFiles -and
                            $item.FullName.Equals($paths.App, [StringComparison]::OrdinalIgnoreCase))) {
                        Remove-MonitorManagedItem -Path $item.FullName -Root $paths.Root
                    }
                }
            }
        }
        elseif (Test-Path -LiteralPath $paths.Root) {
            Remove-MonitorManagedItem -Path $paths.Root -Root $paths.Root -AllowRoot
        }

        return [pscustomobject][ordered]@{
            Operation = 'Uninstall'
            Changed = [bool]($hadRoot -or $hadProgramRoot -or $hadShortcut -or $signalSent)
            Installed = $false
            Running = $false
            StartupEnabled = $false
            PreservedData = [bool]$PreserveData
            PreservedProgramFiles = [bool]$PreserveProgramFiles
            Root = $paths.Root
            DataPath = $paths.Data
            LogDirectory = $paths.Logs
            ShortcutPath = $paths.StartupShortcut
        }
    }
    finally {
        Exit-MonitorManagementMutex -Lease $lease
    }
}
