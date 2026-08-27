function New-RelayProviderStateObject {
    param(
        [Parameter(Mandatory)][string]$ProviderId,
        [Parameter(Mandatory)][string]$Status,
        [AllowEmptyCollection()][object[]]$Results = @(),
        [AllowNull()][object]$LastSuccessAt = $null,
        [AllowNull()][object]$LastAttemptAt = $null,
        [AllowNull()][string]$LastErrorCategory = $null,
        [DateTimeOffset]$NextDueAt = [DateTimeOffset]::MinValue,
        [int]$ConsecutiveFailures = 0,
        [AllowNull()][object]$RetryAfterSeconds = $null,
        [bool]$InFlight = $false
    )
    [pscustomobject][ordered]@{
        ProviderId = $ProviderId
        Status = $Status
        Results = [object[]]@($Results)
        LastSuccessAt = $LastSuccessAt
        LastAttemptAt = $LastAttemptAt
        LastErrorCategory = $LastErrorCategory
        NextDueAt = $NextDueAt
        ConsecutiveFailures = [int]$ConsecutiveFailures
        RetryAfterSeconds = $RetryAfterSeconds
        InFlight = [bool]$InFlight
    }
}

function Copy-RelayProviderState {
    param(
        [Parameter(Mandatory)][object]$State,
        [AllowNull()][hashtable]$Changes
    )
    $values = @{
        ProviderId = [string]$State.ProviderId
        Status = [string]$State.Status
        Results = [object[]]@($State.Results)
        LastSuccessAt = $State.LastSuccessAt
        LastAttemptAt = $State.LastAttemptAt
        LastErrorCategory = $State.LastErrorCategory
        NextDueAt = [DateTimeOffset]$State.NextDueAt
        ConsecutiveFailures = [int]$State.ConsecutiveFailures
        RetryAfterSeconds = $State.RetryAfterSeconds
        InFlight = [bool]$State.InFlight
    }
    if ($null -ne $Changes) {
        foreach ($entry in $Changes.GetEnumerator()) {
            $values[$entry.Key] = $entry.Value
        }
    }
    New-RelayProviderStateObject @values
}

function New-RelayProviderState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$ProviderId,
        [Parameter(Mandatory, Position = 1)][bool]$Enabled,
        [AllowEmptyCollection()][object[]]$CachedResults = @(),
        [AllowNull()][object]$CachedAt = $null
    )
    $results = [object[]]@($CachedResults)
    $lastSuccessAt = if ($results.Count -gt 0 -and $null -ne $CachedAt) {
        ([DateTimeOffset]$CachedAt).ToUniversalTime()
    }
    else {
        $null
    }
    $status = if (-not $Enabled) {
        'Disabled'
    }
    elseif ($results.Count -gt 0) {
        'Stale'
    }
    else {
        'Starting'
    }
    $parameters = @{
        ProviderId = $ProviderId
        Status = $status
        Results = $results
        LastSuccessAt = $lastSuccessAt
    }
    New-RelayProviderStateObject @parameters
}

function Start-RelayProviderAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][object]$State,
        [Parameter(Position = 1)][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    if ($State.Status -eq 'Disabled') {
        return Copy-RelayProviderState $State
    }
    Copy-RelayProviderState $State @{
        LastAttemptAt = $Now.ToUniversalTime()
        InFlight = $true
    }
}

function Complete-RelayProviderSuccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][object]$State,
        [Parameter(Mandatory, Position = 1)][object[]]$Results,
        [Parameter(Position = 2)][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    if ($State.Status -eq 'Disabled') {
        return Copy-RelayProviderState $State
    }
    $resultItems = [object[]]@($Results)
    if ($resultItems.Count -eq 0) {
        throw [ArgumentException]::new('Relay success requires at least one normalized result.')
    }
    $allInvalid = @($resultItems | Where-Object { $_.IsValid -ne $false }).Count -eq 0
    if ($allInvalid) {
        return Copy-RelayProviderState $State @{
            Status = 'AuthRequired'
            LastAttemptAt = $Now.ToUniversalTime()
            LastErrorCategory = 'Authentication'
            ConsecutiveFailures = [int]$State.ConsecutiveFailures + 1
            RetryAfterSeconds = $null
            InFlight = $false
        }
    }
    Copy-RelayProviderState $State @{
        Status = 'Live'
        Results = $resultItems
        LastSuccessAt = $Now.ToUniversalTime()
        LastAttemptAt = $Now.ToUniversalTime()
        LastErrorCategory = $null
        ConsecutiveFailures = 0
        RetryAfterSeconds = $null
        InFlight = $false
    }
}

function Get-RelayProviderFailureStatus {
    param(
        [Parameter(Mandatory)][string]$Category,
        [bool]$HasLastGood
    )
    if ($Category -in @('Authentication', 'AuthRequired', 'Http401', 'Http403')) {
        return 'AuthRequired'
    }
    if ($Category -in @(
        'Script',
        'Configuration',
        'ScriptSyntax',
        'ScriptTimeout',
        'ScriptMemory',
        'RequestValidation',
        'RequestTooLarge',
        'DestinationValidation',
        'DestinationTrustRequired',
        'EndpointNotFound',
        'ExtractorExecution',
        'ResultValidation'
    )) {
        return 'InvalidScript'
    }
    if ($HasLastGood) {
        return 'Stale'
    }
    return 'Unavailable'
}

function Complete-RelayProviderFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][object]$State,
        [Parameter(Mandatory, Position = 1)][string]$Category,
        [Parameter(Position = 2)][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [AllowNull()][object]$RetryAfterSeconds = $null
    )
    if ($State.Status -eq 'Disabled') {
        return Copy-RelayProviderState $State
    }
    $results = [object[]]@($State.Results)
    $status = Get-RelayProviderFailureStatus -Category $Category -HasLastGood ($results.Count -gt 0)
    $retry = if ($null -eq $RetryAfterSeconds) {
        $null
    }
    else {
        [int]$RetryAfterSeconds
    }
    Copy-RelayProviderState $State @{
        Status = $status
        LastAttemptAt = $Now.ToUniversalTime()
        LastErrorCategory = $Category
        ConsecutiveFailures = [int]$State.ConsecutiveFailures + 1
        RetryAfterSeconds = $retry
        InFlight = $false
    }
}

function Set-RelayProviderEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][object]$State,
        [Parameter(Mandatory, Position = 1)][bool]$Enabled
    )
    $results = [object[]]@($State.Results)
    $status = if (-not $Enabled) {
        'Disabled'
    }
    elseif ($results.Count -gt 0) {
        'Stale'
    }
    else {
        'Starting'
    }
    Copy-RelayProviderState $State @{
        Status = $status
        LastErrorCategory = $null
        ConsecutiveFailures = 0
        RetryAfterSeconds = $null
        InFlight = $false
        NextDueAt = [DateTimeOffset]::MinValue
    }
}
