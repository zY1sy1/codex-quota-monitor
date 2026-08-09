$script:MonitorInstallationSourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:MonitorRuntimeStatuses = @(
    'Starting'
    'Live'
    'Reconnecting'
    'AuthRequired'
    'Unavailable'
    'Error'
)

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

function Assert-MonitorDesktopPrerequisites {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PwshPath)

    if (-not $IsWindows -or $PSVersionTable.PSEdition -ne 'Core' -or
        $PSVersionTable.PSVersion -lt [version]'7.4') {
        throw [PlatformNotSupportedException]::new(
            'Codex quota monitor installation requires PowerShell 7.4 or later on Windows.'
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

function Test-PackagedRelayHostIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RootPath)

    $fullRoot = [IO.Path]::GetFullPath($RootPath)
    $exe = Join-Path $fullRoot 'Bin\relay-quota-host.exe'
    $manifest = Join-Path $fullRoot 'Bin\relay-quota-host.sha256'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or
        -not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw [IO.InvalidDataException]::new('Packaged relay host integrity check failed.')
    }

    $manifestText = [IO.File]::ReadAllText($manifest)
    if ($manifestText -notmatch '^[0-9A-Fa-f]{64}\r?\n?$') {
        throw [IO.InvalidDataException]::new('Packaged relay host integrity check failed.')
    }
    $expectedHash = $manifestText.Trim()
    if ($expectedHash -cne $expectedHash.ToUpperInvariant()) {
        throw [IO.InvalidDataException]::new('Packaged relay host integrity check failed.')
    }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToUpperInvariant()
    if ($actualHash -cne $expectedHash) {
        throw [IO.InvalidDataException]::new('Packaged relay host integrity check failed.')
    }

    return $true
}

function Assert-MonitorSourceLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    $fullSource = [IO.Path]::GetFullPath($SourcePath)
    if (-not (Test-Path -LiteralPath $fullSource -PathType Container)) {
        throw [ArgumentException]::new('The monitor source directory does not exist.', 'SourcePath')
    }

    foreach ($relativePath in @(
            'CodexQuotaMonitor.psd1'
            'CodexQuotaMonitor.psm1'
            'Start-CodexQuotaMonitor.ps1'
            'Start-CodexQuotaMonitor.vbs'
            'Private'
            'UI'
            'Bin\relay-quota-host.exe'
            'Bin\relay-quota-host.sha256'
            'Presets\relay-usage.json'
            'ThirdPartyNotices.txt'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $fullSource $relativePath))) {
            throw [ArgumentException]::new('The monitor source directory is incomplete.', 'SourcePath')
        }
    }

    $stagePath = [IO.Path]::GetFullPath((Join-Path $TargetRoot 'app.new'))
    $sourcePrefix = $fullSource.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if ($stagePath.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw [ArgumentException]::new(
            'The monitor source cannot contain its own installation staging directory.',
            'SourcePath'
        )
    }

    $null = Test-PackagedRelayHostIntegrity -RootPath $fullSource

    return $fullSource
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

function New-MonitorInvalidHealthSnapshot {
    [CmdletBinding()]
    param(
        [bool]$Present,
        [string]$Reason
    )

    [pscustomobject][ordered]@{
        Present = $Present
        Valid = $false
        InvalidReason = $Reason
        SchemaVersion = $null
        Status = $null
        PlanType = $null
        QuotaWindowCount = [int]0
        LastSuccessAt = $null
        LastErrorCategory = $null
        LastErrorMessage = $null
        ProcessId = $null
        UpdatedAt = $null
        UpdatedAtValue = $null
        RelayProviderCount = [int]0
        RelayLiveCount = [int]0
        RelayStaleCount = [int]0
        RelayInvalidCount = [int]0
        RelayHostState = $null
        DisplayMode = $null
        Theme = $null
    }
}

function Test-MonitorHealthField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Health,
        [Parameter(Mandatory)][string]$Name
    )

    return $null -ne $Health.PSObject.Properties[$Name]
}

function ConvertTo-MonitorHealthInteger {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value,
        [long]$Minimum,
        [long]$Maximum
    )

    if ($Value -isnot [sbyte] -and $Value -isnot [byte] -and
        $Value -isnot [int16] -and $Value -isnot [uint16] -and
        $Value -isnot [int32] -and $Value -isnot [uint32] -and
        $Value -isnot [int64] -and $Value -isnot [uint64]) {
        throw [FormatException]::new('Health integer field has an invalid type.')
    }
    try {
        $number = [decimal]$Value
    }
    catch {
        throw [FormatException]::new('Health integer field is out of range.')
    }
    if ($number -lt $Minimum -or $number -gt $Maximum) {
        throw [FormatException]::new('Health integer field is out of range.')
    }

    return [long]$number
}

function ConvertTo-MonitorHealthDate {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value,
        [switch]$AllowNull
    )

    if ($null -eq $Value) {
        if ($AllowNull) {
            return $null
        }
        throw [FormatException]::new('Health date field is missing.')
    }
    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToUniversalTime()
    }
    if ($Value -is [DateTime]) {
        return ([DateTimeOffset]([DateTime]$Value)).ToUniversalTime()
    }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw [FormatException]::new('Health date field has an invalid type.')
    }

    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        throw [FormatException]::new('Health date field has an invalid value.')
    }

    return $parsed.ToUniversalTime()
}

function ConvertTo-MonitorHealthString {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value,
        [switch]$AllowNull,
        [ValidateRange(1, 1024)][int]$MaximumLength = 512,
        [AllowNull()][string]$Pattern,
        [switch]$RejectSensitiveText
    )

    if ($null -eq $Value) {
        if ($AllowNull) {
            return $null
        }
        throw [FormatException]::new('Health string field is missing.')
    }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt $MaximumLength -or $Value -match '[\x00-\x1F]') {
        throw [FormatException]::new('Health string field has an invalid value.')
    }
    if ($null -ne $Pattern -and $Value -cnotmatch $Pattern) {
        throw [FormatException]::new('Health string field has an invalid format.')
    }
    if ($RejectSensitiveText -and
        $Value -match '(?i)(authorization|bearer|cookie|password|passwd|secret|access[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret|private[_-]?key)') {
        throw [FormatException]::new('Health string field contains disallowed text.')
    }

    return [string]$Value
}

function Read-MonitorHealthSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-MonitorInvalidHealthSnapshot -Present $false -Reason 'MissingHealth'
    }

    try {
        $health = [IO.File]::ReadAllText([IO.Path]::GetFullPath($Path)) | ConvertFrom-Json -ErrorAction Stop
        if ($health -isnot [pscustomobject]) {
            throw [FormatException]::new('Health document must be an object.')
        }
        foreach ($name in @(
                'SchemaVersion', 'Status', 'PlanType', 'QuotaWindowCount',
                'LastSuccessAt', 'LastErrorCategory', 'LastErrorMessage',
                'ProcessId', 'UpdatedAt'
            )) {
            if (-not (Test-MonitorHealthField -Health $health -Name $name)) {
                throw [FormatException]::new('Health document is missing a required field.')
            }
        }

        $schemaVersion = ConvertTo-MonitorHealthInteger `
            -Value $health.SchemaVersion -Minimum 1 -Maximum 2
        $status = ConvertTo-MonitorHealthString `
            -Value $health.Status -MaximumLength 32 -Pattern '^[A-Za-z]+$'
        if ($status -cnotin $script:MonitorRuntimeStatuses) {
            throw [FormatException]::new('Health status is unsupported.')
        }
        $planType = ConvertTo-MonitorHealthString `
            -Value $health.PlanType `
            -AllowNull `
            -MaximumLength 64 `
            -Pattern '^[A-Za-z0-9._-]+$'
        $quotaWindowCount = ConvertTo-MonitorHealthInteger `
            -Value $health.QuotaWindowCount -Minimum 0 -Maximum 1000
        $lastSuccess = ConvertTo-MonitorHealthDate -Value $health.LastSuccessAt -AllowNull
        $errorCategory = ConvertTo-MonitorHealthString `
            -Value $health.LastErrorCategory `
            -AllowNull `
            -MaximumLength 64 `
            -Pattern '^[A-Za-z0-9._-]+$'
        $errorMessage = ConvertTo-MonitorHealthString `
            -Value $health.LastErrorMessage `
            -AllowNull `
            -MaximumLength 512 `
            -RejectSensitiveText
        $processId = ConvertTo-MonitorHealthInteger `
            -Value $health.ProcessId -Minimum 1 -Maximum ([int]::MaxValue)
        $updatedAt = ConvertTo-MonitorHealthDate -Value $health.UpdatedAt

        $relayProviderCount = [int]0
        $relayLiveCount = [int]0
        $relayStaleCount = [int]0
        $relayInvalidCount = [int]0
        $relayHostState = 'Disabled'
        $displayMode = 'Full'
        $theme = 'Dark'
        if ($schemaVersion -eq 2) {
            foreach ($name in @(
                    'RelayProviderCount', 'RelayLiveCount', 'RelayStaleCount',
                    'RelayInvalidCount', 'RelayHostState', 'DisplayMode', 'Theme'
                )) {
                if (-not (Test-MonitorHealthField -Health $health -Name $name)) {
                    throw [FormatException]::new('Health document is missing a relay field.')
                }
            }
            $relayProviderCount = ConvertTo-MonitorHealthInteger `
                -Value $health.RelayProviderCount -Minimum 0 -Maximum 1000
            $relayLiveCount = ConvertTo-MonitorHealthInteger `
                -Value $health.RelayLiveCount -Minimum 0 -Maximum 1000
            $relayStaleCount = ConvertTo-MonitorHealthInteger `
                -Value $health.RelayStaleCount -Minimum 0 -Maximum 1000
            $relayInvalidCount = ConvertTo-MonitorHealthInteger `
                -Value $health.RelayInvalidCount -Minimum 0 -Maximum 1000
            $relayHostState = ConvertTo-MonitorHealthString `
                -Value $health.RelayHostState -MaximumLength 32 -Pattern '^[A-Za-z]+$'
            if ($relayHostState -notin @('Disabled', 'Starting', 'Live', 'Unavailable')) {
                throw [FormatException]::new('Relay host state is unsupported.')
            }
            $displayMode = ConvertTo-MonitorHealthString `
                -Value $health.DisplayMode -MaximumLength 32 -Pattern '^[A-Za-z]+$'
            if ($displayMode -notin @('Full', 'CompactBar', 'Orb')) {
                throw [FormatException]::new('Display mode is unsupported.')
            }
            $theme = ConvertTo-MonitorHealthString `
                -Value $health.Theme -MaximumLength 16 -Pattern '^[A-Za-z]+$'
            if ($theme -notin @('Light', 'Dark')) {
                throw [FormatException]::new('Theme is unsupported.')
            }
        }

        return [pscustomobject][ordered]@{
            Present = $true
            Valid = $true
            InvalidReason = $null
            SchemaVersion = [int]$schemaVersion
            Status = $status
            PlanType = $planType
            QuotaWindowCount = [int]$quotaWindowCount
            LastSuccessAt = if ($null -eq $lastSuccess) { $null } else { $lastSuccess.ToString('o') }
            LastErrorCategory = $errorCategory
            LastErrorMessage = $errorMessage
            ProcessId = [int]$processId
            UpdatedAt = $updatedAt.ToString('o')
            UpdatedAtValue = $updatedAt
            RelayProviderCount = [int]$relayProviderCount
            RelayLiveCount = [int]$relayLiveCount
            RelayStaleCount = [int]$relayStaleCount
            RelayInvalidCount = [int]$relayInvalidCount
            RelayHostState = $relayHostState
            DisplayMode = $displayMode
            Theme = $theme
        }
    }
    catch {
        Write-Verbose (
            'Health document rejected at validation line {0} with {1}.' -f
            $_.InvocationInfo.ScriptLineNumber,
            $_.Exception.GetType().Name
        )
        return New-MonitorInvalidHealthSnapshot -Present $true -Reason 'InvalidHealth'
    }
}

function Test-MonitorInstalledLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Paths)

    return (
        (Test-Path -LiteralPath $Paths.App -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'CodexQuotaMonitor.psd1') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'CodexQuotaMonitor.psm1') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'Start-CodexQuotaMonitor.ps1') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'Bin\relay-quota-host.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'Bin\relay-quota-host.sha256') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'Presets\relay-usage.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Paths.App 'ThirdPartyNotices.txt') -PathType Leaf)
    )
}

function Get-CodexQuotaMonitorStatus {
    [CmdletBinding()]
    param(
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$Startup = [Environment]::GetFolderPath('Startup'),
        [ValidateNotNullOrEmpty()][string]$InstancePrefix = 'Local\CodexQuotaMonitor'
    )

    $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup
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
        [ValidateNotNullOrEmpty()][string]$InstancePrefix = 'Local\CodexQuotaMonitor',
        [switch]$Live,
        [ValidateRange(1, 3600)][int]$MaximumAgeSeconds = 120
    )

    $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup
    $status = Get-CodexQuotaMonitorStatus `
        -LocalAppData $LocalAppData `
        -Startup $Startup `
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

function Repair-MonitorInterruptedPublishState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Paths)

    $stagePath = Join-Path $Paths.Root 'app.new'
    $backupPath = Join-Path $Paths.Root 'app.old'
    $failedPath = Join-Path $Paths.Root 'app.failed'
    if (Test-Path -LiteralPath $backupPath -PathType Container) {
        Restore-MonitorPublishedApplication `
            -Paths $Paths `
            -PublishState ([pscustomobject]@{
                Published = Test-Path -LiteralPath $Paths.App -PathType Container
                HadPrevious = $true
                StagePath = $stagePath
                BackupPath = $backupPath
            })
        return
    }
    if (-not (Test-Path -LiteralPath $Paths.App) -and
        (Test-Path -LiteralPath $failedPath -PathType Container)) {
        Move-Item -LiteralPath $failedPath -Destination $Paths.App -ErrorAction Stop
    }
    elseif (Test-Path -LiteralPath $failedPath) {
        Remove-MonitorManagedItem -Path $failedPath -Root $Paths.Root
    }
    if (Test-Path -LiteralPath $stagePath) {
        Remove-MonitorManagedItem -Path $stagePath -Root $Paths.Root
    }
}

function Publish-MonitorApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][object]$Paths
    )

    $stagePath = Join-Path $Paths.Root 'app.new'
    $backupPath = Join-Path $Paths.Root 'app.old'
    Repair-MonitorInterruptedPublishState -Paths $Paths
    [IO.Directory]::CreateDirectory($stagePath) | Out-Null
    try {
        foreach ($item in @(Get-ChildItem -LiteralPath $SourcePath -Force)) {
            Copy-Item `
                -LiteralPath $item.FullName `
                -Destination $stagePath `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }
        foreach ($required in @(
                'CodexQuotaMonitor.psd1'
                'CodexQuotaMonitor.psm1'
                'Start-CodexQuotaMonitor.ps1'
                'Start-CodexQuotaMonitor.vbs'
                'Private'
                'UI'
                'Bin\relay-quota-host.exe'
                'Bin\relay-quota-host.sha256'
                'Presets\relay-usage.json'
                'ThirdPartyNotices.txt'
            )) {
            if (-not (Test-Path -LiteralPath (Join-Path $stagePath $required))) {
                throw [IO.InvalidDataException]::new('The staged monitor application is incomplete.')
            }
        }
        $null = Test-PackagedRelayHostIntegrity -RootPath $stagePath

        $hadPrevious = Test-Path -LiteralPath $Paths.App -PathType Container
        if ($hadPrevious) {
            Move-Item -LiteralPath $Paths.App -Destination $backupPath -ErrorAction Stop
        }
        try {
            Move-Item -LiteralPath $stagePath -Destination $Paths.App -ErrorAction Stop
        }
        catch {
            if ($hadPrevious -and -not (Test-Path -LiteralPath $Paths.App) -and
                (Test-Path -LiteralPath $backupPath)) {
                Move-Item -LiteralPath $backupPath -Destination $Paths.App -ErrorAction Stop
            }
            throw
        }

        return [pscustomobject]@{
            Published = $true
            HadPrevious = [bool]$hadPrevious
            StagePath = $stagePath
            BackupPath = $backupPath
        }
    }
    catch {
        if (Test-Path -LiteralPath $stagePath) {
            try { Remove-MonitorManagedItem -Path $stagePath -Root $Paths.Root } catch { }
        }
        throw
    }
}

function Restore-MonitorPublishedApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][object]$PublishState
    )

    $failedPath = Join-Path $Paths.Root 'app.failed'
    if ($PublishState.HadPrevious -and
        -not (Test-Path -LiteralPath $PublishState.BackupPath -PathType Container)) {
        throw [InvalidOperationException]::new(
            'The previous monitor application backup is unavailable for rollback.'
        )
    }
    if (Test-Path -LiteralPath $failedPath) {
        Remove-MonitorManagedItem -Path $failedPath -Root $Paths.Root
    }

    $currentMoved = $false
    try {
        if ($PublishState.Published -and (Test-Path -LiteralPath $Paths.App)) {
            Move-Item -LiteralPath $Paths.App -Destination $failedPath -ErrorAction Stop
            $currentMoved = $true
        }
        if ($PublishState.HadPrevious) {
            Move-Item `
                -LiteralPath $PublishState.BackupPath `
                -Destination $Paths.App `
                -ErrorAction Stop
        }
    }
    catch {
        if ($currentMoved -and -not (Test-Path -LiteralPath $Paths.App) -and
            (Test-Path -LiteralPath $failedPath -PathType Container)) {
            try {
                Move-Item -LiteralPath $failedPath -Destination $Paths.App -ErrorAction Stop
            }
            catch {
            }
        }
        throw
    }

    if (Test-Path -LiteralPath $failedPath) {
        Remove-MonitorManagedItem -Path $failedPath -Root $Paths.Root
    }
    if (Test-Path -LiteralPath $PublishState.StagePath) {
        Remove-MonitorManagedItem -Path $PublishState.StagePath -Root $Paths.Root
    }
}

function Complete-MonitorPublishedApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][object]$PublishState
    )

    if (Test-Path -LiteralPath $PublishState.BackupPath) {
        Remove-MonitorManagedItem -Path $PublishState.BackupPath -Root $Paths.Root
    }
    if (Test-Path -LiteralPath $PublishState.StagePath) {
        Remove-MonitorManagedItem -Path $PublishState.StagePath -Root $Paths.Root
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

function Invoke-CodexQuotaMonitorInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Install', 'Repair')][string]$Operation,
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$LocalAppData,
        [string]$Startup,
        [Parameter(Mandatory)][string]$InstancePrefix,
        [AllowNull()][string]$PwshPath,
        [ValidateRange(1, 120)][int]$TimeoutSeconds,
        [switch]$SkipStart,
        [AllowNull()][scriptblock]$ProcessStarter,
        [AllowNull()][scriptblock]$RollbackProcessStarter
    )

    $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup
    if ([string]::IsNullOrWhiteSpace($PwshPath)) {
        $PwshPath = Resolve-MonitorPwshPath -LocalAppData $LocalAppData
    }
    Assert-MonitorDesktopPrerequisites -PwshPath $PwshPath
    $source = Assert-MonitorSourceLayout -SourcePath $SourcePath -TargetRoot $paths.Root

    $lease = Enter-MonitorManagementMutex -Root $paths.Root -TimeoutSeconds $TimeoutSeconds
    $publishState = $null
    $wasRunning = $false
    $shortcutWasPresent = Test-Path -LiteralPath $paths.StartupShortcut -PathType Leaf
    try {
        [IO.Directory]::CreateDirectory($paths.Root) | Out-Null
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
            -InstancePrefix $InstancePrefix
        $result = New-MonitorOperationResult `
            -Operation $Operation `
            -Changed $true `
            -Status $status `
            -Additional $null
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
        [ValidateNotNullOrEmpty()][string]$InstancePrefix = 'Local\CodexQuotaMonitor',
        [AllowNull()][string]$PwshPath,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15,
        [Parameter(DontShow)][AllowNull()][scriptblock]$ProcessStarter
    )

    $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup
    $lease = Enter-MonitorManagementMutex -Root $paths.Root -TimeoutSeconds $TimeoutSeconds
    try {
        if (-not (Test-MonitorInstalledLayout -Paths $paths)) {
            throw [InvalidOperationException]::new('Codex quota monitor is not installed.')
        }
        if (Invoke-MonitorInstanceSignal -InstancePrefix $InstancePrefix -Signal Activate) {
            $status = Get-CodexQuotaMonitorStatus `
                -LocalAppData $LocalAppData `
                -Startup $Startup `
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
        [ValidateNotNullOrEmpty()][string]$InstancePrefix = 'Local\CodexQuotaMonitor',
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15,
        [Parameter(DontShow)][switch]$Wait
    )

    $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup
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
        [ValidateNotNullOrEmpty()][string]$InstancePrefix = 'Local\CodexQuotaMonitor',
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15,
        [switch]$PreserveData
    )

    $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup
    $lease = Enter-MonitorManagementMutex -Root $paths.Root -TimeoutSeconds $TimeoutSeconds
    try {
        $hadRoot = Test-Path -LiteralPath $paths.Root
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

        if ($PreserveData) {
            if (Test-Path -LiteralPath $paths.Root -PathType Container) {
                foreach ($item in @(Get-ChildItem -LiteralPath $paths.Root -Force)) {
                    if ($item.Name -notin @('data', 'logs')) {
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
            Changed = [bool]($hadRoot -or $hadShortcut -or $signalSent)
            Installed = $false
            Running = $false
            StartupEnabled = $false
            PreservedData = [bool]$PreserveData
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
