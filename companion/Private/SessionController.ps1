function New-SessionState {
    [pscustomobject][ordered]@{
        NextId = [int]1
        Pending = @{}
        Initialized = $false
        QuotaReadPending = $false
        Status = 'Starting'
        PlanType = $null
        QuotaWindows = @()
        LastSuccessAt = $null
        LastError = $null
        ReconnectAttempt = [int]0
        QuotaEligible = $null
        QuotaRefreshQueued = $false
        AccountRefreshQueued = $false
    }
}

function Test-SessionPendingMethod {
    param(
        [Parameter(Mandatory)]
        [object]$State,

        [Parameter(Mandatory)]
        [string]$Method
    )

    foreach ($entry in $State.Pending.GetEnumerator()) {
        if ($entry.Value.Method -eq $Method) {
            return $true
        }
    }

    return $false
}

function Remove-SessionPendingMethod {
    param(
        [Parameter(Mandatory)]
        [object]$State,

        [Parameter(Mandatory)]
        [string]$Method
    )

    $ids = @(
        foreach ($entry in $State.Pending.GetEnumerator()) {
            if ($entry.Value.Method -eq $Method) {
                $entry.Key
            }
        }
    )
    foreach ($id in $ids) {
        $State.Pending.Remove($id)
    }
}

function New-SessionRequest {
    param(
        [Parameter(Mandatory)]
        [object]$State,

        [Parameter(Mandatory)]
        [string]$Method,

        [AllowNull()]
        $Params,

        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    $id = [int]$State.NextId
    $State.NextId = [int]($id + 1)
    $State.Pending[$id] = [pscustomobject][ordered]@{
        Method = $Method
        SentAt = $Now.ToUniversalTime()
        AllowUnknownQuotaRefresh = [bool](
            $Method -eq 'account/rateLimits/read' -and $null -eq $State.QuotaEligible
        )
    }

    New-RpcRequest -Id $id -Method $Method -Params $Params
}

function Start-SessionHandshake {
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$State,

        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    if ($State.Initialized -or (Test-SessionPendingMethod -State $State -Method 'initialize')) {
        return
    }

    $params = [ordered]@{
        clientInfo = [ordered]@{
            name = 'codex_quota_monitor'
            title = 'Codex Quota Monitor'
            version = '0.1.0'
        }
    }
    New-SessionRequest -State $State -Method 'initialize' -Params $params -Now $Now
}

function ConvertTo-SessionResponseId {
    param(
        [AllowNull()]
        [object]$Id
    )

    if ($Id -is [int]) {
        return [int]$Id
    }
    if (-not (Test-IsNumericClrPrimitive -Value $Id)) {
        return $null
    }

    try {
        [decimal]$numericId = [Convert]::ToDecimal($Id, [Globalization.CultureInfo]::InvariantCulture)
        if ($numericId -ne [decimal]::Truncate($numericId) -or
            $numericId -lt [decimal]([int]::MinValue) -or
            $numericId -gt [decimal]([int]::MaxValue)) {
            return $null
        }

        return [int]$numericId
    }
    catch {
        return $null
    }
}

function Test-SessionObjectField {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $false
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return ([System.Collections.IDictionary]$InputObject).Contains($Name)
    }

    return $null -ne $InputObject.PSObject.Properties[$Name]
}

function Test-SessionStructuredObject {
    param(
        [AllowNull()]
        [object]$InputObject
    )

    return $InputObject -is [System.Collections.IDictionary] -or $InputObject -is [pscustomobject]
}

function Test-SessionResultShape {
    param(
        [Parameter(Mandatory)]
        [string]$Method,

        [AllowNull()]
        [object]$Result
    )

    if (-not (Test-SessionStructuredObject -InputObject $Result)) {
        return $false
    }

    switch ($Method) {
        'initialize' {
            return $true
        }
        'account/read' {
            if (-not (Test-SessionObjectField -InputObject $Result -Name 'account') -or
                -not (Test-SessionObjectField -InputObject $Result -Name 'requiresOpenaiAuth')) {
                return $false
            }

            $requiresOpenaiAuth = Get-ObjectField -InputObject $Result -Name 'requiresOpenaiAuth'
            if ($requiresOpenaiAuth -isnot [bool]) {
                return $false
            }

            $account = Get-ObjectField -InputObject $Result -Name 'account'
            if ($null -eq $account) {
                return $true
            }
            if (-not (Test-SessionStructuredObject -InputObject $account) -or
                -not (Test-SessionObjectField -InputObject $account -Name 'type')) {
                return $false
            }

            $accountType = Get-ObjectField -InputObject $account -Name 'type'
            return $accountType -is [string] -and -not [string]::IsNullOrWhiteSpace($accountType)
        }
        'account/rateLimits/read' {
            foreach ($name in @('rateLimits', 'rateLimitsByLimitId')) {
                if (Test-SessionObjectField -InputObject $Result -Name $name) {
                    $rateLimits = Get-ObjectField -InputObject $Result -Name $name
                    if (Test-SessionStructuredObject -InputObject $rateLimits) {
                        return $true
                    }
                }
            }

            return $false
        }
        default {
            return $false
        }
    }
}

function Clear-SessionQuotaState {
    param(
        [Parameter(Mandatory)]
        [object]$State
    )

    $State.PlanType = $null
    $State.QuotaWindows = @()
    $State.QuotaReadPending = $false
    $State.QuotaEligible = $false
    $State.QuotaRefreshQueued = $false
    Remove-SessionPendingMethod -State $State -Method 'account/rateLimits/read'
}

function Set-SessionRequestFailure {
    param(
        [Parameter(Mandatory)]
        [object]$State,

        [Parameter(Mandatory)]
        [string]$Method
    )

    $State.Status = 'Error'
    $State.ReconnectAttempt = [int]($State.ReconnectAttempt + 1)
    switch ($Method) {
        'initialize' {
            $State.Initialized = $false
            $State.LastError = 'Codex App Server initialization failed.'
        }
        'account/read' {
            $State.AccountRefreshQueued = $false
            $State.LastError = 'Unable to read the Codex account state.'
        }
        'account/rateLimits/read' {
            $State.QuotaReadPending = $false
            $State.QuotaRefreshQueued = $false
            $State.LastError = 'Unable to read ChatGPT quota from Codex App Server.'
        }
        default {
            $State.LastError = 'A Codex App Server request failed.'
        }
    }
}

function Test-ChatGptBackedAccountType {
    param(
        [AllowNull()]
        [string]$AccountType
    )

    if ([string]::IsNullOrWhiteSpace($AccountType)) {
        return $false
    }

    return $AccountType.ToLowerInvariant() -in @(
        'chatgpt',
        'chatgptauthtokens',
        'agentidentity',
        'personalaccesstoken'
    )
}

function Get-SessionAccountPlanType {
    param(
        [AllowNull()]
        [object]$Account
    )

    $planType = [string](Get-ObjectField -InputObject $Account -Name 'planType')
    if ([string]::IsNullOrWhiteSpace($planType)) {
        $planType = [string](Get-ObjectField -InputObject $Account -Name 'chatgptPlanType')
    }
    if ([string]::IsNullOrWhiteSpace($planType)) {
        return $null
    }

    return $planType
}

function Get-SessionRateLimitPlanType {
    param(
        [AllowNull()]
        [object]$RateLimitResult
    )

    $planType = [string](Get-ObjectField -InputObject $RateLimitResult -Name 'planType')
    if ([string]::IsNullOrWhiteSpace($planType)) {
        return $null
    }

    return $planType
}

function Update-SessionFromAccountResult {
    param(
        [Parameter(Mandatory)]
        [object]$State,

        [AllowNull()]
        [object]$Result,

        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    $account = Get-ObjectField -InputObject $Result -Name 'account'
    $requiresOpenaiAuth = Get-ObjectField -InputObject $Result -Name 'requiresOpenaiAuth'
    if ($null -eq $account) {
        Clear-SessionQuotaState -State $State
        if ($requiresOpenaiAuth -eq $true) {
            $State.Status = 'AuthRequired'
            $State.LastError = 'ChatGPT authentication is required to monitor Codex quota.'
        }
        else {
            $State.Status = 'Unavailable'
            $State.LastError = 'ChatGPT quota is not applicable to the active Codex provider.'
        }

        return
    }

    $accountType = [string](Get-ObjectField -InputObject $account -Name 'type')
    switch ($accountType.ToLowerInvariant()) {
        'apikey' {
            Clear-SessionQuotaState -State $State
            $State.Status = 'AuthRequired'
            $State.LastError = 'OpenAI API billing is distinct from ChatGPT quota; sign in with a ChatGPT-backed Codex account to monitor quota.'
            return
        }
        'amazonbedrock' {
            Clear-SessionQuotaState -State $State
            $State.Status = 'Unavailable'
            $State.LastError = 'ChatGPT quota is not applicable when Codex uses Amazon Bedrock.'
            return
        }
    }

    if (-not (Test-ChatGptBackedAccountType -AccountType $accountType)) {
        Clear-SessionQuotaState -State $State
        $State.Status = 'Unavailable'
        $State.LastError = 'ChatGPT quota is not applicable to the active Codex account type.'
        return
    }

    $planType = Get-SessionAccountPlanType -Account $account
    $State.QuotaEligible = $true
    if ($null -ne $planType) {
        $State.PlanType = $planType
    }
    if ($State.Status -ne 'Live') {
        $State.Status = 'Starting'
    }
    $State.LastError = $null

    if ($State.Initialized -and -not $State.QuotaReadPending) {
        $State.QuotaReadPending = $true
        New-SessionRequest -State $State -Method 'account/rateLimits/read' -Params $null -Now $Now
    }
}

function Update-SessionFromQuotaResult {
    param(
        [Parameter(Mandatory)]
        [object]$State,

        [AllowNull()]
        [object]$Result,

        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    if ($State.QuotaEligible -eq $false) {
        $State.QuotaReadPending = $false
        $State.QuotaRefreshQueued = $false
        return
    }

    $State.QuotaWindows = @(ConvertTo-QuotaWindow -RateLimitResult $Result)
    $planType = Get-SessionRateLimitPlanType -RateLimitResult $Result
    if ($null -ne $planType) {
        $State.PlanType = $planType
    }
    $State.Status = 'Live'
    $State.QuotaReadPending = $false
    $State.QuotaRefreshQueued = $false
    $State.LastSuccessAt = $Now.ToUniversalTime()
    $State.LastError = $null
    $State.ReconnectAttempt = [int]0
}

function Update-SessionFromNotification {
    param(
        [Parameter(Mandatory)]
        [object]$State,

        [Parameter(Mandatory)]
        [string]$Method,

        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    switch ($Method) {
        'account/rateLimits/updated' {
            if (-not $State.Initialized -or $State.QuotaEligible -eq $false) {
                return
            }
            if ($State.QuotaReadPending) {
                $canQueueRefresh = $State.QuotaEligible -eq $true
                if (-not $canQueueRefresh -and $null -eq $State.QuotaEligible) {
                    foreach ($entry in $State.Pending.GetEnumerator()) {
                        if ($entry.Value.Method -eq 'account/rateLimits/read') {
                            $canQueueRefresh = $entry.Value.AllowUnknownQuotaRefresh -eq $true
                            break
                        }
                    }
                }
                if ($canQueueRefresh) {
                    $State.QuotaRefreshQueued = $true
                }
                return
            }
            if ($State.QuotaEligible -eq $true) {
                $State.QuotaReadPending = $true
                New-SessionRequest -State $State -Method 'account/rateLimits/read' -Params $null -Now $Now
            }
        }
        'account/updated' {
            $State.PlanType = $null
            $State.QuotaEligible = $null
            if (-not $State.Initialized) {
                return
            }
            if (Test-SessionPendingMethod -State $State -Method 'account/read') {
                $State.AccountRefreshQueued = $true
                return
            }

            New-SessionRequest -State $State -Method 'account/read' -Params ([ordered]@{}) -Now $Now
        }
    }
}

function Update-SessionFromMessage {
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$State,

        [Parameter(Mandatory, Position = 1)]
        [AllowNull()]
        [object]$Message,

        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )

    if ($null -eq $Message) {
        return
    }

    $method = Get-ObjectField -InputObject $Message -Name 'method'
    if ($null -ne $method) {
        Update-SessionFromNotification -State $State -Method ([string]$method) -Now $Now
        return
    }

    $responseId = ConvertTo-SessionResponseId -Id (Get-ObjectField -InputObject $Message -Name 'id')
    if ($null -eq $responseId -or -not $State.Pending.Contains($responseId)) {
        return
    }

    $pending = $State.Pending[$responseId]
    $State.Pending.Remove($responseId)

    if ($pending.Method -eq 'account/read' -and $State.AccountRefreshQueued) {
        $State.AccountRefreshQueued = $false
        New-SessionRequest -State $State -Method 'account/read' -Params ([ordered]@{}) -Now $Now
        return
    }
    if ($pending.Method -eq 'account/rateLimits/read') {
        if ($State.QuotaEligible -eq $false) {
            $State.QuotaReadPending = $false
            $State.QuotaRefreshQueued = $false
            return
        }
        if ($State.QuotaRefreshQueued) {
            $State.QuotaRefreshQueued = $false
            $State.QuotaReadPending = $true
            New-SessionRequest -State $State -Method 'account/rateLimits/read' -Params $null -Now $Now
            return
        }
    }

    $errorObject = Get-ObjectField -InputObject $Message -Name 'error'
    if ($null -ne $errorObject) {
        Set-SessionRequestFailure -State $State -Method $pending.Method
        return
    }

    if (-not (Test-SessionObjectField -InputObject $Message -Name 'result')) {
        Set-SessionRequestFailure -State $State -Method $pending.Method
        return
    }
    $result = Get-ObjectField -InputObject $Message -Name 'result'
    if (-not (Test-SessionResultShape -Method $pending.Method -Result $result)) {
        Set-SessionRequestFailure -State $State -Method $pending.Method
        return
    }

    switch ($pending.Method) {
        'initialize' {
            $State.Initialized = $true
            $State.Status = 'Starting'
            $State.LastError = $null

            New-RpcNotification -Method 'initialized' -Params $null
            New-SessionRequest -State $State -Method 'account/read' -Params ([ordered]@{}) -Now $Now
            $State.QuotaReadPending = $true
            New-SessionRequest -State $State -Method 'account/rateLimits/read' -Params $null -Now $Now
        }
        'account/read' {
            Update-SessionFromAccountResult -State $State -Result $result -Now $Now
        }
        'account/rateLimits/read' {
            Update-SessionFromQuotaResult -State $State -Result $result -Now $Now
        }
    }
}

function Get-ReconnectDelaySeconds {
    param(
        [Parameter(Mandatory, Position = 0)]
        [int]$Attempt
    )

    $delays = @(2, 5, 15, 30, 60)
    if ($Attempt -lt 0) {
        $Attempt = 0
    }
    if ($Attempt -ge $delays.Count) {
        return [int]$delays[-1]
    }

    return [int]$delays[$Attempt]
}

function Test-RequestExpired {
    param(
        [Parameter(Mandatory, Position = 0)]
        [datetimeoffset]$SentAt,

        [Parameter(Mandatory, Position = 1)]
        [datetimeoffset]$Now,

        [int]$TimeoutSeconds = 10
    )

    return ($Now.ToUniversalTime() - $SentAt.ToUniversalTime()).TotalSeconds -ge $TimeoutSeconds
}
