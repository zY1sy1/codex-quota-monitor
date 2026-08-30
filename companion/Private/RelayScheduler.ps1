function Get-RelaySchedulerValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [Collections.IDictionary]) {
        return ([Collections.IDictionary]$InputObject)[$Name]
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }
    return $null
}

function New-RelaySchedulerProviderEntry {
    param(
        [Parameter(Mandatory)][string]$ProviderId,
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter(Mandatory)][int]$IntervalMinutes,
        [Parameter(Mandatory)][bool]$InFlight,
        [Parameter(Mandatory)][DateTimeOffset]$NextDueAt,
        [Parameter(Mandatory)][int]$ConsecutiveFailures,
        [AllowNull()][object]$PauseReason
    )
    [pscustomobject][ordered]@{
        ProviderId = $ProviderId
        Enabled = $Enabled
        IntervalMinutes = $IntervalMinutes
        InFlight = $InFlight
        NextDueAt = $NextDueAt.ToUniversalTime()
        ConsecutiveFailures = $ConsecutiveFailures
        PauseReason = $PauseReason
    }
}

function Copy-RelaySchedulerProviderEntry {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [AllowNull()][hashtable]$Changes = $null
    )
    $values = @{
        ProviderId = [string]$Entry.ProviderId
        Enabled = [bool]$Entry.Enabled
        IntervalMinutes = [int]$Entry.IntervalMinutes
        InFlight = [bool]$Entry.InFlight
        NextDueAt = [DateTimeOffset]$Entry.NextDueAt
        ConsecutiveFailures = [int]$Entry.ConsecutiveFailures
        PauseReason = $Entry.PauseReason
    }
    if ($null -ne $Changes) {
        foreach ($change in $Changes.GetEnumerator()) {
            $values[$change.Key] = $change.Value
        }
    }
    New-RelaySchedulerProviderEntry @values
}

function New-RelaySchedulerStateObject {
    param(
        [Parameter(Mandatory)][int]$MaximumConcurrency,
        [AllowEmptyCollection()][object[]]$Providers = @()
    )
    [pscustomobject][ordered]@{
        MaximumConcurrency = $MaximumConcurrency
        Providers = [object[]]@($Providers)
    }
}

function New-RelaySchedulerState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Providers,
        [Parameter(Position = 1)][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [ValidateRange(1, 16)][int]$MaximumConcurrency = 2
    )
    $nowUtc = $Now.ToUniversalTime()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($provider in @($Providers)) {
        $providerId = [string](Get-RelaySchedulerValue $provider 'Id')
        $enabled = [bool](Get-RelaySchedulerValue $provider 'Enabled')
        $interval = [int](Get-RelaySchedulerValue $provider 'IntervalMinutes')
        if ([string]::IsNullOrWhiteSpace($providerId) -or -not $seen.Add($providerId)) {
            throw [ArgumentException]::new('Relay scheduler provider is invalid.')
        }
        if ($interval -lt 0 -or $interval -gt 1440) {
            throw [ArgumentException]::new('Relay scheduler provider interval must be between 0 and 1440 minutes.')
        }
        $nextDueAt = if ($enabled -and $interval -gt 0) {
            $nowUtc
        }
        else {
            [DateTimeOffset]::MaxValue
        }
        $pauseReason = if ($enabled) { $null } else { 'Disabled' }
        $entries.Add((New-RelaySchedulerProviderEntry -ProviderId $providerId `
            -Enabled $enabled -IntervalMinutes $interval -InFlight $false `
            -NextDueAt $nextDueAt -ConsecutiveFailures 0 -PauseReason $pauseReason))
    }
    New-RelaySchedulerStateObject -MaximumConcurrency $MaximumConcurrency `
        -Providers ([object[]]$entries.ToArray())
}

function Get-RelaySchedulerActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Position = 1)][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [switch]$ManualRefresh
    )
    $nowUtc = $Now.ToUniversalTime()
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($State.Providers)) {
        $entries.Add((Copy-RelaySchedulerProviderEntry $entry))
    }
    $inFlightCount = @($entries | Where-Object InFlight).Count
    $remainingCapacity = [Math]::Max(0, [int]$State.MaximumConcurrency - $inFlightCount)
    $actions = [Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt $entries.Count -and $remainingCapacity -gt 0; $index++) {
        $entry = $entries[$index]
        if (-not $entry.Enabled -or $entry.InFlight) {
            continue
        }
        $trustBlocked = $entry.PauseReason -eq 'DestinationTrustRequired'
        $shouldStart = if ($ManualRefresh) {
            -not $trustBlocked
        }
        else {
            $entry.IntervalMinutes -gt 0 -and $null -eq $entry.PauseReason -and
            $entry.NextDueAt -le $nowUtc
        }
        if (-not $shouldStart) {
            continue
        }

        $entries[$index] = Copy-RelaySchedulerProviderEntry $entry @{
            InFlight = $true
            PauseReason = $null
        }
        $actions.Add([pscustomobject][ordered]@{
            Kind = 'StartQuery'
            ProviderId = $entry.ProviderId
            Reason = if ($ManualRefresh) { 'Manual' } else { 'Due' }
        })
        $remainingCapacity--
    }

    [pscustomobject][ordered]@{
        State = New-RelaySchedulerStateObject -MaximumConcurrency ([int]$State.MaximumConcurrency) `
            -Providers ([object[]]$entries.ToArray())
        Actions = [object[]]$actions.ToArray()
    }
}

function Get-RelaySchedulerFailurePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [AllowNull()][object]$HttpStatus = $null
    )
    if ($Category -in @('Authentication', 'AuthRequired', 'Http401', 'Http403')) {
        return 'Authentication'
    }
    if ($Category -eq 'DestinationTrustRequired') {
        return 'TrustRequired'
    }
    if ($Category -eq 'RateLimit') {
        return 'RateLimit'
    }
    if ($Category -eq 'HttpStatus') {
        if ($HttpStatus -in @(401, 403)) { return 'Authentication' }
        if ($HttpStatus -eq 429) { return 'RateLimit' }
        if ($HttpStatus -ge 500 -and $HttpStatus -le 599) { return 'Retry' }
        return 'InvalidScript'
    }
    if ($Category -in @(
        'Dns',
        'Connectivity',
        'Tls',
        'Timeout',
        'ResponseTooLarge',
        'InvalidJson',
        'SidecarLifecycle'
    )) {
        return 'Retry'
    }
    if ($Category -in @(
        'Protocol',
        'Script',
        'Configuration',
        'ScriptSyntax',
        'ScriptTimeout',
        'ScriptMemory',
        'RequestValidation',
        'RequestTooLarge',
        'DestinationValidation',
        'EndpointNotFound',
        'ExtractorExecution',
        'ResultValidation'
    )) {
        return 'InvalidScript'
    }
    return 'Retry'
}

function Get-RelaySchedulerBackoffMinutes {
    param([Parameter(Mandatory)][int]$ConsecutiveFailures)
    $delays = @(1, 2, 5, 10, 30, 60)
    $index = [Math]::Min([Math]::Max(0, $ConsecutiveFailures - 1), $delays.Count - 1)
    return $delays[$index]
}

function Test-RelaySchedulerPositiveInteger {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value -is [bool] -or $Value.GetType().IsEnum -or
        [Type]::GetTypeCode($Value.GetType()) -notin @(
            [TypeCode]::SByte,
            [TypeCode]::Byte,
            [TypeCode]::Int16,
            [TypeCode]::UInt16,
            [TypeCode]::Int32,
            [TypeCode]::UInt32,
            [TypeCode]::Int64
        )) {
        return $false
    }
    return [long]$Value -gt 0
}

function Complete-RelaySchedulerAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$ProviderId,
        [Parameter(Mandatory)][ValidateSet('Success', 'Failure')][string]$Outcome,
        [AllowNull()][string]$Category = $null,
        [AllowNull()][object]$HttpStatus = $null,
        [AllowNull()][object]$RetryAfterSeconds = $null,
        [Parameter(Position = 3)][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    $nowUtc = $Now.ToUniversalTime()
    $entries = [Collections.Generic.List[object]]::new()
    $found = $false
    foreach ($entry in @($State.Providers)) {
        if ($entry.ProviderId -ine $ProviderId) {
            $entries.Add((Copy-RelaySchedulerProviderEntry $entry))
            continue
        }
        $found = $true
        if (-not $entry.Enabled) {
            $entries.Add((Copy-RelaySchedulerProviderEntry $entry @{
                InFlight = $false
                NextDueAt = [DateTimeOffset]::MaxValue
                PauseReason = 'Disabled'
            }))
            continue
        }
        if ($Outcome -eq 'Success') {
            $nextDueAt = if ($entry.IntervalMinutes -gt 0) {
                $nowUtc.AddMinutes($entry.IntervalMinutes)
            }
            else {
                [DateTimeOffset]::MaxValue
            }
            $entries.Add((Copy-RelaySchedulerProviderEntry $entry @{
                InFlight = $false
                NextDueAt = $nextDueAt
                ConsecutiveFailures = 0
                PauseReason = $null
            }))
            continue
        }

        if ([string]::IsNullOrWhiteSpace($Category)) {
            throw [ArgumentException]::new('Relay scheduler failure category is required.')
        }
        $failureCount = [int]$entry.ConsecutiveFailures + 1
        $policy = Get-RelaySchedulerFailurePolicy -Category $Category -HttpStatus $HttpStatus
        $nextDueAt = [DateTimeOffset]::MaxValue
        $pauseReason = $null
        switch ($policy) {
            'Authentication' {
                $pauseReason = 'Authentication'
            }
            'InvalidScript' {
                $pauseReason = 'InvalidScript'
            }
            'TrustRequired' {
                $pauseReason = 'DestinationTrustRequired'
            }
            default {
                $delaySeconds = $null
                if ($policy -eq 'RateLimit' -and
                    (Test-RelaySchedulerPositiveInteger $RetryAfterSeconds)) {
                    $delaySeconds = [Math]::Min(3600, [long]$RetryAfterSeconds)
                }
                if ($null -ne $delaySeconds) {
                    $nextDueAt = $nowUtc.AddSeconds($delaySeconds)
                }
                else {
                    $nextDueAt = $nowUtc.AddMinutes((Get-RelaySchedulerBackoffMinutes $failureCount))
                }
            }
        }
        $entries.Add((Copy-RelaySchedulerProviderEntry $entry @{
            InFlight = $false
            NextDueAt = $nextDueAt
            ConsecutiveFailures = $failureCount
            PauseReason = $pauseReason
        }))
    }
    if (-not $found) {
        throw [ArgumentException]::new('Relay scheduler provider was not found.')
    }
    New-RelaySchedulerStateObject -MaximumConcurrency ([int]$State.MaximumConcurrency) `
        -Providers ([object[]]$entries.ToArray())
}
