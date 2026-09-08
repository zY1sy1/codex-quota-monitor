function New-EmptyDailySpendDocument {
    [CmdletBinding()]
    param()

    [ordered]@{
        SchemaVersion = [int]1
        Date = ''
        Providers = [ordered]@{}
    }
}

function Test-DailySpendObject {
    param([AllowNull()][object]$Value)
    return $null -ne $Value -and (
        $Value -is [Collections.IDictionary] -or
        $Value -is [pscustomobject]
    )
}

function Get-DailySpendField {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($InputObject -is [Collections.IDictionary]) {
        foreach ($key in ([Collections.IDictionary]$InputObject).Keys) {
            if ([string]$key -ceq $Name) {
                Write-Output -NoEnumerate -InputObject (
                    ([Collections.IDictionary]$InputObject)[$key]
                )
                return
            }
        }
        return
    }
    $property = $InputObject.PSObject.Properties |
        Where-Object Name -CEQ $Name |
        Select-Object -First 1
    if ($null -ne $property) {
        Write-Output -NoEnumerate -InputObject $property.Value
    }
}

function Test-DailySpendFields {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string[]]$Expected
    )
    if (-not (Test-DailySpendObject -Value $InputObject)) {
        return $false
    }
    $names = if ($InputObject -is [Collections.IDictionary]) {
        [string[]]@(([Collections.IDictionary]$InputObject).Keys)
    }
    else {
        [string[]]@($InputObject.PSObject.Properties.Name)
    }
    if ($names.Count -ne $Expected.Count) {
        return $false
    }
    foreach ($name in $Expected) {
        if ($names -cnotcontains $name) {
            return $false
        }
    }
    return $true
}

function Test-DailySpendSchemaVersion {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value.GetType().IsEnum -or $Value -is [bool]) {
        return $false
    }
    if ([Type]::GetTypeCode($Value.GetType()) -notin @(
        [TypeCode]::SByte,
        [TypeCode]::Byte,
        [TypeCode]::Int16,
        [TypeCode]::UInt16,
        [TypeCode]::Int32,
        [TypeCode]::UInt32,
        [TypeCode]::Int64,
        [TypeCode]::UInt64
    )) {
        return $false
    }
    return [decimal]$Value -eq 1
}

function ConvertTo-DailySpendPeakMap {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return [ordered]@{}
    }
    $pairs = [Collections.Generic.List[object]]::new()
    if ($Value -is [Collections.IDictionary]) {
        foreach ($entry in ([Collections.IDictionary]$Value).GetEnumerator()) {
            $pairs.Add([pscustomobject]@{ Name = [string]$entry.Key; Value = $entry.Value })
        }
    }
    elseif ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            $pairs.Add([pscustomobject]@{ Name = [string]$property.Name; Value = $property.Value })
        }
    }
    else {
        return $null
    }
    if ($pairs.Count -gt 128) {
        return $null
    }
    $result = [ordered]@{}
    foreach ($pair in $pairs) {
        $name = $pair.Name
        if ([string]::IsNullOrEmpty($name) -or $name.Length -gt 256 -or
            $name -match '[\x00-\x1f\x7f]') {
            return $null
        }
        $number = ConvertTo-InvariantFiniteDouble -Value $pair.Value
        if ($null -eq $number -or $number -lt 0) {
            return $null
        }
        $result[$name] = [double]$number
    }
    Write-Output -NoEnumerate -InputObject $result
}

function ConvertTo-CanonicalDailySpendDocument {
    param([AllowNull()][object]$Document)
    if (-not (Test-DailySpendFields $Document @('SchemaVersion', 'Date', 'Providers'))) {
        return $null
    }
    $schemaVersion = Get-DailySpendField $Document 'SchemaVersion'
    if (-not (Test-DailySpendSchemaVersion -Value $schemaVersion)) {
        return $null
    }
    $date = Get-DailySpendField $Document 'Date'
    if ($date -isnot [string] -or
        ($date -ne '' -and $date -notmatch '^\d{4}-\d{2}-\d{2}$')) {
        return $null
    }
    $providers = ConvertTo-DailySpendPeakMap (Get-DailySpendField $Document 'Providers')
    if ($null -eq $providers) {
        return $null
    }
    [ordered]@{
        SchemaVersion = [int]1
        Date = [string]$date
        Providers = $providers
    }
}

function ConvertTo-DailySpendJson {
    param([Parameter(Mandatory)][object]$Document)
    return $Document | ConvertTo-Json -Depth 8 -Compress -ErrorAction Stop
}

function Write-CanonicalDailySpendFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Document
    )
    $directory = [IO.Path]::GetDirectoryName($Path)
    $null = [IO.Directory]::CreateDirectory($directory)
    $name = [IO.Path]::GetFileName($Path)
    $temporaryPath = Join-Path $directory ".$name.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
            (ConvertTo-DailySpendJson $Document)
        )
        $stream = [IO.FileStream]::new(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
        if ([IO.File]::Exists($Path)) {
            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            Set-Acl -LiteralPath $temporaryPath -AclObject $acl -ErrorAction Stop
            [IO.File]::Move($temporaryPath, $Path, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

function Read-DailySpendStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Position = 1)][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $mutex = Enter-MonitorSettingsMutex $fullPath
    try {
        if (-not [IO.File]::Exists($fullPath)) {
            return New-EmptyDailySpendDocument
        }
        $json = [IO.File]::ReadAllText($fullPath)
        $canonical = $null
        try {
            $canonical = ConvertTo-CanonicalDailySpendDocument (
                $json | ConvertFrom-Json -ErrorAction Stop
            )
        }
        catch {
            $canonical = $null
        }
        if ($null -eq $canonical) {
            $null = Move-CorruptMonitorSettings $fullPath $Now
            return New-EmptyDailySpendDocument
        }
        if ($json -cne (ConvertTo-DailySpendJson $canonical)) {
            Write-CanonicalDailySpendFile $fullPath $canonical
        }
        return $canonical
    }
    finally {
        Exit-MonitorSettingsMutex $mutex
    }
}

function Write-DailySpendStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][object]$Document
    )
    $canonical = ConvertTo-CanonicalDailySpendDocument $Document
    if ($null -eq $canonical) {
        throw [ArgumentException]::new('Daily spend document does not match the supported schema.')
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $mutex = Enter-MonitorSettingsMutex $fullPath
    try {
        Write-CanonicalDailySpendFile $fullPath $canonical
    }
    finally {
        Exit-MonitorSettingsMutex $mutex
    }
}

# A USD result is only tracked as a drawdown wallet when it has no cap
# (`Total` is null). Capped plan counters reset on their own schedule, so the
# "peak minus live" delta would be meaningless for them.
function Get-DailySpendUsdRemaining {
    param([AllowNull()][object]$State)
    if ($null -eq $State) {
        return $null
    }
    foreach ($result in @(Get-ObjectField -InputObject $State -Name 'Results')) {
        if (-not [bool](Get-ObjectField -InputObject $result -Name 'IsValid')) {
            continue
        }
        $unit = [string](Get-ObjectField -InputObject $result -Name 'Unit')
        if ($unit -ine 'USD') {
            continue
        }
        if ($null -ne (Get-ObjectField -InputObject $result -Name 'Total')) {
            continue
        }
        $remaining = ConvertTo-InvariantFiniteDouble (
            Get-ObjectField -InputObject $result -Name 'Remaining'
        )
        if ($null -ne $remaining -and $remaining -ge 0) {
            return $remaining
        }
    }
    return $null
}

# Computes the aggregate USD burned so far today by tracking, per wallet provider,
# the highest balance observed since local midnight and subtracting the live
# balance. A recharge raises the peak and therefore resets the counter, which
# reads as "spent since the highest point today". Returns the (possibly updated)
# store plus the presentation row to show (zero or one).
function Resolve-RelayDailySpendRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$States,
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][DateTimeOffset]$Now,
        [Parameter(Mandatory)][bool]$ShowEnabled
    )

    $emptyRows = [object[]]@()
    if (-not $ShowEnabled) {
        return [pscustomobject][ordered]@{
            Rows = $emptyRows
            Store = $Document
            Changed = $false
        }
    }

    $store = ConvertTo-CanonicalDailySpendDocument $Document
    if ($null -eq $store) {
        $store = New-EmptyDailySpendDocument
    }

    $localToday = $Now.ToLocalTime().ToString('yyyy-MM-dd')
    $changed = $false
    if ([string]$store.Date -cne $localToday) {
        $store.Date = $localToday
        $store.Providers = [ordered]@{}
        $changed = $true
    }

    $totalSpend = 0.0
    $contributors = 0
    foreach ($key in @($States.Keys)) {
        $state = $States[$key]
        if ($null -eq $state -or [string](Get-ObjectField -InputObject $state -Name 'Status') -ne 'Live') {
            continue
        }
        $remaining = Get-DailySpendUsdRemaining -State $state
        if ($null -eq $remaining) {
            continue
        }
        $providerId = [string]$key
        $existingPeak = $null
        if ($store.Providers.Contains($providerId)) {
            $existingPeak = [double]$store.Providers[$providerId]
        }
        $peak = if ($null -eq $existingPeak) { $remaining } else { [Math]::Max($existingPeak, $remaining) }
        if ($null -eq $existingPeak -or $peak -gt $existingPeak) {
            $store.Providers[$providerId] = $peak
            $changed = $true
        }
        $totalSpend += [Math]::Max(0.0, $peak - $remaining)
        $contributors++
    }

    if ($contributors -eq 0) {
        return [pscustomobject][ordered]@{
            Rows = $emptyRows
            Store = $store
            Changed = $changed
        }
    }

    $row = [pscustomobject][ordered]@{
        Key = 'relay:daily-spend'
        SourceKind = 'Relay'
        SourceId = 'daily'
        SourceLabel = '今日消耗'
        GroupLabel = '中转站额度'
        Label = '今日消耗'
        ValueText = Format-RelayPresentationAmount -Value $totalSpend -Unit 'USD'
        SecondaryText = '按钱包余额下降估算'
        ProgressValue = $null
        Countdown = ''
        ResetTime = ''
        IsStale = $false
        UpdatedAt = ([DateTimeOffset]$Now).ToUniversalTime()
        State = 'Live'
    }
    [pscustomobject][ordered]@{
        Rows = [object[]]@($row)
        Store = $store
        Changed = $changed
    }
}
