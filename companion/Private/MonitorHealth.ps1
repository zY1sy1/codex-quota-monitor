function Write-MonitorRuntimeHealthFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [Collections.IDictionary]$Health
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = "$fullPath.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    $utf8WithoutBom = [Text.UTF8Encoding]::new($false)
    try {
        $json = ($Health | ConvertTo-Json -Depth 8) + [Environment]::NewLine
        [IO.File]::WriteAllText($temporaryPath, $json, $utf8WithoutBom)
        [IO.File]::Move($temporaryPath, $fullPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

$script:MonitorRuntimeStatuses = @(
    'Starting'
    'Live'
    'Reconnecting'
    'AuthRequired'
    'Unavailable'
    'Error'
)

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
