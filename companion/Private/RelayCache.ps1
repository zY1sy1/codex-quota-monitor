function New-EmptyRelayCache {
    [CmdletBinding()]
    param()

    [ordered]@{
        SchemaVersion = [int]1
        Providers = [object[]]@()
    }
}

function Test-RelayCacheObject {
    param([AllowNull()][object]$Value)
    return $null -ne $Value -and (
        $Value -is [Collections.IDictionary] -or
        $Value -is [pscustomobject]
    )
}

function Get-RelayCacheFieldNames {
    param([Parameter(Mandatory)][object]$InputObject)
    if ($InputObject -is [Collections.IDictionary]) {
        return [string[]]@(([Collections.IDictionary]$InputObject).Keys)
    }
    return [string[]]@($InputObject.PSObject.Properties.Name)
}

function Test-RelayCacheFields {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string[]]$Expected
    )
    if (-not (Test-RelayCacheObject $InputObject)) {
        return $false
    }
    $names = @(Get-RelayCacheFieldNames $InputObject)
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

function Get-RelayCacheField {
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

function Test-RelayCacheSchemaVersion {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value.GetType().IsEnum) {
        return $false
    }
    return [Type]::GetTypeCode($Value.GetType()) -in @(
        [TypeCode]::SByte,
        [TypeCode]::Byte,
        [TypeCode]::Int16,
        [TypeCode]::UInt16,
        [TypeCode]::Int32,
        [TypeCode]::UInt32,
        [TypeCode]::Int64,
        [TypeCode]::UInt64
    ) -and [decimal]$Value -eq 1
}

function ConvertTo-RelayCacheString {
    param(
        [AllowNull()][object]$Value,
        [switch]$Required
    )
    if ($null -eq $Value) {
        if ($Required) { return $null }
        return [pscustomobject]@{ Valid = $true; Value = $null }
    }
    if ($Value -isnot [string] -or $Value.Length -gt 4096) {
        return $null
    }
    $text = if ($Required) { $Value.Trim() } else { $Value }
    if ($Required -and $text.Length -eq 0) {
        return $null
    }
    return [pscustomobject]@{ Valid = $true; Value = $text }
}

function ConvertTo-RelayCacheNumber {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return [pscustomobject]@{ Valid = $true; Value = $null }
    }
    if ($Value.GetType().IsEnum -or [Type]::GetTypeCode($Value.GetType()) -notin @(
        [TypeCode]::SByte,
        [TypeCode]::Byte,
        [TypeCode]::Int16,
        [TypeCode]::UInt16,
        [TypeCode]::Int32,
        [TypeCode]::UInt32,
        [TypeCode]::Int64,
        [TypeCode]::UInt64,
        [TypeCode]::Single,
        [TypeCode]::Double,
        [TypeCode]::Decimal
    )) {
        return $null
    }
    try {
        $number = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return $null
    }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        return $null
    }
    return [pscustomobject]@{ Valid = $true; Value = [double]$number }
}

function ConvertTo-CanonicalRelayCacheResult {
    param([AllowNull()][object]$Result)
    $fields = @(
        'IsValid',
        'InvalidMessage',
        'Remaining',
        'Unit',
        'PlanName',
        'Total',
        'Used',
        'Extra'
    )
    if (-not (Test-RelayCacheFields $Result $fields)) {
        return $null
    }
    $isValid = Get-RelayCacheField $Result 'IsValid'
    if ($isValid -isnot [bool]) {
        return $null
    }

    $strings = [ordered]@{}
    foreach ($name in @('InvalidMessage', 'Unit', 'PlanName', 'Extra')) {
        $converted = ConvertTo-RelayCacheString (Get-RelayCacheField $Result $name)
        if ($null -eq $converted) {
            return $null
        }
        $strings[$name] = $converted.Value
    }

    $numbers = [ordered]@{}
    foreach ($name in @('Remaining', 'Total', 'Used')) {
        $converted = ConvertTo-RelayCacheNumber (Get-RelayCacheField $Result $name)
        if ($null -eq $converted) {
            return $null
        }
        $numbers[$name] = $converted.Value
    }

    $canonical = [ordered]@{
        IsValid = [bool]$isValid
        InvalidMessage = $strings.InvalidMessage
        Remaining = $numbers.Remaining
        Unit = $strings.Unit
        PlanName = $strings.PlanName
        Total = $numbers.Total
        Used = $numbers.Used
        Extra = $strings.Extra
    }
    Write-Output -NoEnumerate -InputObject $canonical
}

function ConvertTo-CanonicalRelayCacheProvider {
    param([AllowNull()][object]$Provider)
    if (-not (Test-RelayCacheFields $Provider @('ProviderId', 'UpdatedAt', 'Results'))) {
        return $null
    }
    $providerId = ConvertTo-RelayCacheString (Get-RelayCacheField $Provider 'ProviderId') -Required
    if ($null -eq $providerId) {
        return $null
    }
    $updatedText = Get-RelayCacheField $Provider 'UpdatedAt'
    $updatedAt = [DateTimeOffset]::MinValue
    $validTimestamp = if ($updatedText -is [DateTimeOffset]) {
        $updatedAt = [DateTimeOffset]$updatedText
        $true
    }
    elseif ($updatedText -is [DateTime]) {
        $updatedAt = [DateTimeOffset]([DateTime]$updatedText)
        $true
    }
    elseif ($updatedText -is [string]) {
        $updatedText.Length -le 4096 -and
        $updatedText -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$' -and
        [DateTimeOffset]::TryParseExact(
            $updatedText,
            "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$updatedAt
        )
    }
    else {
        $false
    }
    if (-not $validTimestamp) {
        return $null
    }

    $results = Get-RelayCacheField $Provider 'Results'
    if ($null -eq $results -or $results -is [string] -or
        $results -is [Collections.IDictionary] -or
        $results -isnot [Collections.IEnumerable]) {
        return $null
    }
    $items = @($results)
    if ($items.Count -eq 0 -or $items.Count -gt 32) {
        return $null
    }
    $canonicalResults = [Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        $canonical = ConvertTo-CanonicalRelayCacheResult $item
        if ($null -eq $canonical) {
            return $null
        }
        $canonicalResults.Add($canonical)
    }

    $canonicalProvider = [ordered]@{
        ProviderId = $providerId.Value
        UpdatedAt = $updatedAt.ToUniversalTime().ToString('o')
        Results = [object[]]$canonicalResults.ToArray()
    }
    Write-Output -NoEnumerate -InputObject $canonicalProvider
}

function ConvertTo-CanonicalRelayCache {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Cache
    )
    if (-not (Test-RelayCacheFields $Cache @('SchemaVersion', 'Providers')) -or
        -not (Test-RelayCacheSchemaVersion (Get-RelayCacheField $Cache 'SchemaVersion'))) {
        return $null
    }
    $providers = Get-RelayCacheField $Cache 'Providers'
    if ($null -eq $providers -or $providers -is [string] -or
        $providers -is [Collections.IDictionary] -or
        $providers -isnot [Collections.IEnumerable]) {
        return $null
    }
    $items = @($providers)
    if ($items.Count -gt 100) {
        return $null
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $canonicalProviders = [Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        $canonical = ConvertTo-CanonicalRelayCacheProvider $item
        if ($null -eq $canonical -or -not $seen.Add([string]$canonical.ProviderId)) {
            return $null
        }
        $canonicalProviders.Add($canonical)
    }
    $document = [ordered]@{
        SchemaVersion = [int]1
        Providers = [object[]]$canonicalProviders.ToArray()
    }
    Write-Output -NoEnumerate -InputObject $document
}

function ConvertTo-RelayCacheJson {
    param([Parameter(Mandatory)][object]$Cache)
    return $Cache | ConvertTo-Json -Depth 8 -Compress -ErrorAction Stop
}

function Write-CanonicalRelayCacheFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Cache
    )
    $directory = [IO.Path]::GetDirectoryName($Path)
    $null = [IO.Directory]::CreateDirectory($directory)
    $name = [IO.Path]::GetFileName($Path)
    $temporaryPath = Join-Path $directory ".$name.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
            (ConvertTo-RelayCacheJson $Cache)
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

function Read-RelayCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Position = 1)][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $mutex = Enter-MonitorSettingsMutex $fullPath
    try {
        if (-not [IO.File]::Exists($fullPath)) {
            return New-EmptyRelayCache
        }
        $json = [IO.File]::ReadAllText($fullPath)
        $canonical = $null
        try {
            $canonical = ConvertTo-CanonicalRelayCache (
                $json | ConvertFrom-Json -ErrorAction Stop
            )
        }
        catch {
            $canonical = $null
        }
        if ($null -eq $canonical) {
            $null = Move-CorruptMonitorSettings $fullPath $Now
            return New-EmptyRelayCache
        }
        if ($json -cne (ConvertTo-RelayCacheJson $canonical)) {
            Write-CanonicalRelayCacheFile $fullPath $canonical
        }
        return $canonical
    }
    finally {
        Exit-MonitorSettingsMutex $mutex
    }
}

function Write-RelayCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][object]$Cache
    )
    $canonical = ConvertTo-CanonicalRelayCache $Cache
    if ($null -eq $canonical) {
        throw [ArgumentException]::new('Relay cache does not match the supported schema.')
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $mutex = Enter-MonitorSettingsMutex $fullPath
    try {
        Write-CanonicalRelayCacheFile $fullPath $canonical
    }
    finally {
        Exit-MonitorSettingsMutex $mutex
    }
}
