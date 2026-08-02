function New-EmptyRelayProviderDocument {
    [CmdletBinding()]
    param()

    [ordered]@{
        SchemaVersion = [int]1
        Providers = [object[]]@()
    }
}

function Test-RelayProviderObject {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    return $null -ne $Value -and (
        $Value -is [Collections.IDictionary] -or
        $Value -is [pscustomobject]
    )
}

function Get-RelayProviderPropertyNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$InputObject
    )

    if ($InputObject -is [Collections.IDictionary]) {
        return [string[]]@(([Collections.IDictionary]$InputObject).Keys)
    }
    return [string[]]@($InputObject.PSObject.Properties.Name)
}

function Test-RelayProviderExactFields {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string[]]$Expected
    )

    if (-not (Test-RelayProviderObject -Value $InputObject)) {
        return $false
    }
    $names = @(Get-RelayProviderPropertyNames -InputObject $InputObject)
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

function Get-RelayProviderField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name
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
        return $null
    }
    $property = $InputObject.PSObject.Properties | Where-Object Name -CEQ $Name | Select-Object -First 1
    if ($null -eq $property) {
        return $null
    }
    Write-Output -NoEnumerate -InputObject $property.Value
}

function Test-RelayProviderInteger {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory, Position = 1)]
        [int]$Minimum,

        [Parameter(Mandatory, Position = 2)]
        [int]$Maximum
    )

    if ($null -eq $Value -or $Value.GetType().IsEnum) {
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
    try {
        $number = [decimal]$Value
        return $number -ge $Minimum -and $number -le $Maximum
    }
    catch {
        return $false
    }
}

function ConvertTo-CanonicalRelayCipherText {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($Value -isnot [string]) {
        return $null
    }
    if ($Value.Length -eq 0) {
        return ''
    }
    if ($Value.Length -gt 65536) {
        return $null
    }
    [byte[]]$bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($Value)
        return [Convert]::ToBase64String($bytes)
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $bytes) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
}

function ConvertTo-CanonicalRelayProvider {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Provider
    )

    $providerFields = @(
        'Id',
        'Name',
        'Enabled',
        'BaseUrl',
        'TemplateType',
        'Script',
        'TimeoutSeconds',
        'IntervalMinutes',
        'TrustedDestination',
        'Secrets'
    )
    if (-not (Test-RelayProviderExactFields -InputObject $Provider -Expected $providerFields)) {
        return $null
    }

    $idValue = Get-RelayProviderField -InputObject $Provider -Name 'Id'
    $parsedId = [Guid]::Empty
    if ($idValue -isnot [string] -or -not [Guid]::TryParse($idValue, [ref]$parsedId) -or
        $parsedId -eq [Guid]::Empty) {
        return $null
    }

    $name = Get-RelayProviderField -InputObject $Provider -Name 'Name'
    if ($name -isnot [string]) {
        return $null
    }
    $name = $name.Trim()
    if ($name.Length -eq 0 -or $name.Length -gt 256) {
        return $null
    }

    $enabled = Get-RelayProviderField -InputObject $Provider -Name 'Enabled'
    if ($enabled -isnot [bool]) {
        return $null
    }

    $baseUrl = Get-RelayProviderField -InputObject $Provider -Name 'BaseUrl'
    if ($baseUrl -isnot [string]) {
        return $null
    }
    $baseUrl = $baseUrl.Trim()
    $parsedUrl = $null
    if ($baseUrl.Length -eq 0 -or $baseUrl.Length -gt 4096 -or
        -not [Uri]::TryCreate($baseUrl, [UriKind]::Absolute, [ref]$parsedUrl) -or
        $parsedUrl.Scheme -notin @('http', 'https') -or
        [string]::IsNullOrEmpty($parsedUrl.Host) -or
        -not [string]::IsNullOrEmpty($parsedUrl.UserInfo)) {
        return $null
    }

    $templateType = Get-RelayProviderField -InputObject $Provider -Name 'TemplateType'
    if ($templateType -isnot [string] -or
        $templateType -cnotin @('Wakaka', 'General', 'NewApi', 'Custom')) {
        return $null
    }

    $script = Get-RelayProviderField -InputObject $Provider -Name 'Script'
    if ($script -isnot [string] -or [string]::IsNullOrWhiteSpace($script) -or
        [Text.Encoding]::UTF8.GetByteCount($script) -gt 262144) {
        return $null
    }

    $timeout = Get-RelayProviderField -InputObject $Provider -Name 'TimeoutSeconds'
    $interval = Get-RelayProviderField -InputObject $Provider -Name 'IntervalMinutes'
    if (-not (Test-RelayProviderInteger -Value $timeout -Minimum 2 -Maximum 30) -or
        -not (Test-RelayProviderInteger -Value $interval -Minimum 0 -Maximum 1440)) {
        return $null
    }

    $trustedDestination = Get-RelayProviderField -InputObject $Provider -Name 'TrustedDestination'
    if ($null -ne $trustedDestination) {
        if ($trustedDestination -isnot [string]) {
            return $null
        }
        $trustedDestination = $trustedDestination.Trim()
        if ($trustedDestination.Length -eq 0 -or $trustedDestination.Length -gt 4096) {
            return $null
        }
    }

    $secrets = Get-RelayProviderField -InputObject $Provider -Name 'Secrets'
    $secretFields = @('ApiKey', 'AccessToken', 'UserId')
    if (-not (Test-RelayProviderExactFields -InputObject $secrets -Expected $secretFields)) {
        return $null
    }
    $canonicalSecrets = [ordered]@{}
    foreach ($secretName in $secretFields) {
        $cipherText = ConvertTo-CanonicalRelayCipherText (
            Get-RelayProviderField -InputObject $secrets -Name $secretName
        )
        if ($null -eq $cipherText) {
            return $null
        }
        $canonicalSecrets[$secretName] = $cipherText
    }

    $canonical = [ordered]@{
        Id = $parsedId.ToString('D')
        Name = $name
        Enabled = [bool]$enabled
        BaseUrl = $baseUrl
        TemplateType = $templateType
        Script = $script
        TimeoutSeconds = [int]$timeout
        IntervalMinutes = [int]$interval
        TrustedDestination = $trustedDestination
        Secrets = $canonicalSecrets
    }
    Write-Output -NoEnumerate -InputObject $canonical
}

function ConvertTo-CanonicalRelayProviderDocument {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Document
    )

    if (-not (Test-RelayProviderExactFields -InputObject $Document -Expected @('SchemaVersion', 'Providers'))) {
        return $null
    }
    $schemaVersion = Get-RelayProviderField -InputObject $Document -Name 'SchemaVersion'
    if (-not (Test-RelayProviderInteger -Value $schemaVersion -Minimum 1 -Maximum 1)) {
        return $null
    }
    $providers = Get-RelayProviderField -InputObject $Document -Name 'Providers'
    if ($null -eq $providers -or $providers -is [string] -or
        $providers -is [Collections.IDictionary] -or
        $providers -isnot [Collections.IEnumerable]) {
        return $null
    }
    $providerItems = @($providers)
    if ($providerItems.Count -gt 100) {
        return $null
    }

    $seenIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $canonicalProviders = [Collections.Generic.List[object]]::new()
    foreach ($provider in $providerItems) {
        $canonical = ConvertTo-CanonicalRelayProvider -Provider $provider
        if ($null -eq $canonical -or -not $seenIds.Add([string]$canonical.Id)) {
            return $null
        }
        $canonicalProviders.Add($canonical)
    }

    $canonicalDocument = [ordered]@{
        SchemaVersion = [int]1
        Providers = [object[]]$canonicalProviders.ToArray()
    }
    Write-Output -NoEnumerate -InputObject $canonicalDocument
}

function ConvertTo-RelayProviderJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$Document
    )

    return $Document | ConvertTo-Json -Depth 8 -Compress -ErrorAction Stop
}

function Write-CanonicalRelayProviderFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [object]$Document
    )

    $directory = [IO.Path]::GetDirectoryName($Path)
    $null = [IO.Directory]::CreateDirectory($directory)
    $fileName = [IO.Path]::GetFileName($Path)
    $temporaryPath = Join-Path $directory ".$fileName.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-RelayProviderJson -Document $Document
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
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

function Read-RelayProviderStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Position = 1)]
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $mutex = Enter-MonitorSettingsMutex -Path $fullPath
    try {
        if (-not [IO.File]::Exists($fullPath)) {
            return New-EmptyRelayProviderDocument
        }
        $json = [IO.File]::ReadAllText($fullPath)
        $canonical = $null
        try {
            $document = $json | ConvertFrom-Json -ErrorAction Stop
            $canonical = ConvertTo-CanonicalRelayProviderDocument -Document $document
        }
        catch {
            $canonical = $null
        }
        if ($null -eq $canonical) {
            $null = Move-CorruptMonitorSettings -Path $fullPath -Now $Now
            return New-EmptyRelayProviderDocument
        }

        if ($json -cne (ConvertTo-RelayProviderJson -Document $canonical)) {
            Write-CanonicalRelayProviderFile -Path $fullPath -Document $canonical
        }
        return $canonical
    }
    finally {
        Exit-MonitorSettingsMutex -Mutex $mutex
    }
}

function Write-RelayProviderStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [object]$Document
    )

    $canonical = ConvertTo-CanonicalRelayProviderDocument -Document $Document
    if ($null -eq $canonical) {
        throw [ArgumentException]::new(
            'Relay provider document does not match the supported schema.'
        )
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    $mutex = Enter-MonitorSettingsMutex -Path $fullPath
    try {
        Write-CanonicalRelayProviderFile -Path $fullPath -Document $canonical
    }
    finally {
        Exit-MonitorSettingsMutex -Mutex $mutex
    }
}
