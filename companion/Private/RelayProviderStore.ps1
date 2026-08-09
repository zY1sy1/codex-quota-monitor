function New-EmptyRelayProviderDocument {
    [CmdletBinding()]
    param()

    [ordered]@{
        SchemaVersion = [int]2
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
    return [string[]]@(
        $InputObject.PSObject.Properties | ForEach-Object { [string]$_.Name }
    )
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

function Test-RelayProviderSafeText {
    param(
        [AllowNull()][object]$Value,
        [int]$MaximumBytes = 16384
    )
    if ($Value -isnot [string] -or [Text.Encoding]::UTF8.GetByteCount($Value) -gt $MaximumBytes) {
        return $false
    }
    return $Value -notmatch '[\x00-\x1f\x7f]'
}

function ConvertTo-CanonicalRelayStringMap {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value,
        [int]$MaximumEntries = 128,
        [int]$MaximumStringBytes = 16384
    )

    if ($null -eq $Value) {
        return [ordered]@{}
    }
    if (-not (Test-RelayProviderObject -Value $Value)) {
        return $null
    }
    $result = [ordered]@{}
    foreach ($name in @(Get-RelayProviderPropertyNames -InputObject $Value)) {
        if ($name.Length -eq 0 -or $name.Length -gt 256 -or $name -match '[\x00-\x1f\x7f]') {
            return $null
        }
        $item = Get-RelayProviderField -InputObject $Value -Name $name
        if (-not (Test-RelayProviderSafeText -Value $item -MaximumBytes $MaximumStringBytes)) {
            return $null
        }
        $result[$name] = [string]$item
    }
    if ($result.Count -gt $MaximumEntries) {
        return $null
    }
    Write-Output -NoEnumerate -InputObject $result
}

function ConvertTo-RelayOriginFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BaseUrl)

    $uri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or [string]::IsNullOrEmpty($uri.Host) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        return $null
    }
    $canonicalHost = if ($uri.HostNameType -eq [UriHostNameType]::IPv6) {
        "[$($uri.Host)]"
    }
    else {
        $uri.IdnHost
    }
    $port = if ($uri.IsDefaultPort) {
        if ($uri.Scheme -eq 'https') { 443 } else { 80 }
    }
    else {
        $uri.Port
    }
    return "$($uri.Scheme.ToLowerInvariant())://$($canonicalHost.ToLowerInvariant()):$port"
}

function ConvertTo-CanonicalRelayRequestDefinition {
    [CmdletBinding()]
    param([AllowNull()][object]$RequestDefinition)

    if (-not (Test-RelayProviderExactFields -InputObject $RequestDefinition -Expected @(
        'Method', 'Path', 'Query', 'Headers', 'Body'
    ))) {
        return $null
    }
    $methodValue = Get-RelayProviderField -InputObject $RequestDefinition -Name 'Method'
    $pathValue = Get-RelayProviderField -InputObject $RequestDefinition -Name 'Path'
    $bodyValue = Get-RelayProviderField -InputObject $RequestDefinition -Name 'Body'
    if ($methodValue -isnot [string] -or $pathValue -isnot [string]) {
        return $null
    }
    $method = $methodValue.Trim().ToUpperInvariant()
    $path = $pathValue.Trim()
    if ($method -notin @('GET', 'POST', 'PUT') -or
        [string]::IsNullOrWhiteSpace($path) -or $path.Length -gt 4096 -or
        $path -match '^(?i)(https?:|//)' -or $path -match '[?#\x00-\x1f\x7f\\]') {
        return $null
    }
    if ($null -ne $bodyValue -and -not (Test-RelayProviderSafeText -Value $bodyValue -MaximumBytes 65536)) {
        return $null
    }
    $query = ConvertTo-CanonicalRelayStringMap -Value (
        Get-RelayProviderField -InputObject $RequestDefinition -Name 'Query'
    )
    $headers = ConvertTo-CanonicalRelayStringMap -Value (
        Get-RelayProviderField -InputObject $RequestDefinition -Name 'Headers'
    )
    if ($null -eq $query -or $null -eq $headers) {
        return $null
    }
    [ordered]@{
        Method = $method
        Path = $path
        Query = $query
        Headers = $headers
        Body = if ($null -eq $bodyValue) { $null } else { [string]$bodyValue }
    }
}

function Test-RelayExtractorFunctionExpression {
    param([AllowNull()][string]$Script)
    if ([string]::IsNullOrWhiteSpace($Script)) {
        return $false
    }
    $trimmed = $Script.Trim()
    return $trimmed -match '^(?s)(?:async\s+)?function\b' -or
        $trimmed -match '^(?s)(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>'
}

function ConvertTo-CanonicalRelayProvider {
    [CmdletBinding()]
    param([AllowNull()][object]$Provider)

    $providerFields = @(
        'Id', 'Name', 'Enabled', 'ProviderKind', 'BaseUrl', 'RequestDefinition',
        'ExtractorScript', 'TimeoutSeconds', 'IntervalMinutes', 'TrustedDestination', 'Secrets'
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
        -not [string]::IsNullOrEmpty($parsedUrl.UserInfo) -or
        -not [string]::IsNullOrEmpty($parsedUrl.Fragment) -or
        -not [string]::IsNullOrEmpty($parsedUrl.Query)) {
        return $null
    }

    $providerKind = Get-RelayProviderField -InputObject $Provider -Name 'ProviderKind'
    if ($providerKind -isnot [string] -or $providerKind -cnotin @('Generic', 'Custom')) {
        return $null
    }

    $extractorScript = Get-RelayProviderField -InputObject $Provider -Name 'ExtractorScript'
    if ($extractorScript -isnot [string] -or [string]::IsNullOrWhiteSpace($extractorScript) -or
        [Text.Encoding]::UTF8.GetByteCount($extractorScript) -gt 262144) {
        return $null
    }

    $requestDefinition = $null
    if ($providerKind -ceq 'Generic') {
        if (-not (Test-RelayExtractorFunctionExpression -Script $extractorScript)) {
            return $null
        }
        $requestDefinition = ConvertTo-CanonicalRelayRequestDefinition (
            Get-RelayProviderField -InputObject $Provider -Name 'RequestDefinition'
        )
        if ($null -eq $requestDefinition) {
            return $null
        }
    }
    elseif ($null -ne (Get-RelayProviderField -InputObject $Provider -Name 'RequestDefinition')) {
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
        if ($trustedDestination -isnot [string] -or
            [string]::IsNullOrWhiteSpace($trustedDestination)) {
            return $null
        }
        $trustedDestination = ConvertTo-RelayOriginFingerprint -BaseUrl $trustedDestination.Trim()
        if ($null -eq $trustedDestination) {
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

    [ordered]@{
        Id = $parsedId.ToString('D')
        Name = $name
        Enabled = [bool]$enabled
        ProviderKind = $providerKind
        BaseUrl = $baseUrl
        RequestDefinition = $requestDefinition
        ExtractorScript = $extractorScript
        TimeoutSeconds = [int]$timeout
        IntervalMinutes = [int]$interval
        TrustedDestination = $trustedDestination
        Secrets = $canonicalSecrets
    }
}

function ConvertFrom-RelayJavascriptString {
    param([Parameter(Mandatory)][string]$Value)
    try {
        return ('"' + $Value + '"' | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        if ($Value -match '[\\\"]') {
            return $null
        }
        return $Value
    }
}

function Get-RelayLegacyStringField {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Name
    )
    $escapedName = [regex]::Escape($Name)
    $doubleQuote = [char]34
    $singleQuote = [char]39
    $doublePattern = '(?s)(?:\b' + $escapedName + '\b|' + $doubleQuote + $escapedName + $doubleQuote + '|' +
        $singleQuote + $escapedName + $singleQuote + ')\s*:\s*' + $doubleQuote +
        '(?<value>(?:\\.|[^' + $doubleQuote + ']*)*)' + $doubleQuote
    $match = [regex]::Match($Source, $doublePattern)
    if (-not $match.Success) {
        $singlePattern = '(?s)(?:\b' + $escapedName + '\b|' + $doubleQuote + $escapedName + $doubleQuote + '|' +
            $singleQuote + $escapedName + $singleQuote + ')\s*:\s*' + $singleQuote +
            '(?<value>(?:\\.|[^' + $singleQuote + ']*)*)' + $singleQuote
        $match = [regex]::Match($Source, $singlePattern)
    }
    if (-not $match.Success) { return $null }
    ConvertFrom-RelayJavascriptString -Value $match.Groups['value'].Value
}

function ConvertFrom-RelayLegacyScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$TemplateType
    )

    if ($TemplateType -eq 'Custom') { return $null }
    $requestMatch = [regex]::Match($Script, '(?s)\brequest\s*:\s*\{(?<request>.*?)\}\s*,\s*extractor\s*:')
    if (-not $requestMatch.Success) { return $null }
    $requestText = $requestMatch.Groups['request'].Value
    $url = Get-RelayLegacyStringField -Source $requestText -Name 'url'
    $method = Get-RelayLegacyStringField -Source $requestText -Name 'method'
    if ($null -eq $url -or $null -eq $method -or $url -notmatch '^\{\{baseUrl\}\}(?<path>/.*)?$') {
        return $null
    }
    $path = if ($null -eq $Matches.path -or [string]::IsNullOrEmpty($Matches.path)) { '/' } else { $Matches.path }

    $headers = [ordered]@{}
    $headersMatch = [regex]::Match(
        $requestText,
        '(?s)\bheaders\s*:\s*\{(?<headers>.*?)}\s*(?:,\s*body\s*:|$)'
    )
    if ($headersMatch.Success) {
        $doubleQuote = [char]34
        $singleQuote = [char]39
        $headerPattern = '(?s)(?:' + $doubleQuote + '(?<name>(?:\\.|[^' + $doubleQuote + ']*)*)' + $doubleQuote +
            '|(?<name>[A-Za-z0-9!#$%&*+.^_|\x60~-]+))\s*:\s*' + $doubleQuote +
            '(?<value>(?:\\.|[^' + $doubleQuote + ']*)*)' + $doubleQuote
        $singleHeaderPattern = '(?s)(?:' + $singleQuote + '(?<name>(?:\\.|[^' + $singleQuote + ']*)*)' + $singleQuote +
            '|(?<name>[A-Za-z0-9!#$%&*+.^_|\x60~-]+))\s*:\s*' + $singleQuote +
            '(?<value>(?:\\.|[^' + $singleQuote + ']*)*)' + $singleQuote
        $headersFound = [regex]::Matches($headersMatch.Groups['headers'].Value, $headerPattern)
        if ($headersFound.Count -eq 0) {
            $headersFound = [regex]::Matches($headersMatch.Groups['headers'].Value, $singleHeaderPattern)
        }
        foreach ($header in $headersFound) {
            $headerName = ConvertFrom-RelayJavascriptString -Value $header.Groups['name'].Value
            $headerValue = ConvertFrom-RelayJavascriptString -Value $header.Groups['value'].Value
            if ($null -eq $headerName -or $null -eq $headerValue) { return $null }
            $headers[$headerName] = $headerValue
        }
    }

    $body = $null
    $doubleQuote = [char]34
    $singleQuote = [char]39
    $bodyPattern = '(?s)\bbody\s*:\s*(?<body>' + $doubleQuote + '(?:\\.|[^' + $doubleQuote + '])*' + $doubleQuote +
        '|' + $singleQuote + '(?:\\.|[^' + $singleQuote + '])*' + $singleQuote + '|null|undefined)'
    $bodyMatch = [regex]::Match($requestText, $bodyPattern)
    if ($bodyMatch.Success -and $bodyMatch.Groups['body'].Value -notin @('null', 'undefined')) {
        $bodyText = $bodyMatch.Groups['body'].Value
        $body = ConvertFrom-RelayJavascriptString -Value $bodyText.Substring(1, $bodyText.Length - 2)
        if ($null -eq $body) { return $null }
    }

    $extractorIndex = $Script.IndexOf('extractor:', [StringComparison]::Ordinal)
    if ($extractorIndex -lt 0) { return $null }
    $extractor = $Script.Substring($extractorIndex + 'extractor:'.Length).Trim()
    if ($extractor.EndsWith('})')) {
        $extractor = $extractor.Substring(0, $extractor.Length - 2).Trim()
    }
    elseif ($extractor.EndsWith('}')) {
        $extractor = $extractor.Substring(0, $extractor.Length - 1).Trim()
    }
    if (-not (Test-RelayExtractorFunctionExpression $extractor)) { return $null }

    [ordered]@{
        RequestDefinition = [ordered]@{
            Method = $method
            Path = $path
            Query = [ordered]@{}
            Headers = $headers
            Body = $body
        }
        ExtractorScript = $extractor
    }
}

function ConvertTo-CanonicalRelayLegacyProvider {
    [CmdletBinding()]
    param([AllowNull()][object]$Provider)

    $expected = @('Id','Name','Enabled','BaseUrl','TemplateType','Script','TimeoutSeconds','IntervalMinutes','TrustedDestination','Secrets')
    if (-not (Test-RelayProviderExactFields -InputObject $Provider -Expected $expected)) { return $null }
    $baseUrl = [string](Get-RelayProviderField $Provider 'BaseUrl')
    $template = [string](Get-RelayProviderField $Provider 'TemplateType')
    $script = [string](Get-RelayProviderField $Provider 'Script')
    $converted = ConvertFrom-RelayLegacyScript -Script $script -BaseUrl $baseUrl -TemplateType $template
    $providerKind = 'Custom'
    $requestDefinition = $null
    $extractor = $script
    $trust = $null
    if ($null -ne $converted) {
        $providerKind = 'Generic'
        $requestDefinition = $converted.RequestDefinition
        $extractor = $converted.ExtractorScript
        $trust = Get-RelayProviderField $Provider 'TrustedDestination'
        if ([string]::IsNullOrWhiteSpace([string]$trust)) {
            $trust = ConvertTo-RelayOriginFingerprint -BaseUrl $baseUrl.Trim()
        }
    }
    [ordered]@{
        Id = Get-RelayProviderField $Provider 'Id'
        Name = Get-RelayProviderField $Provider 'Name'
        Enabled = Get-RelayProviderField $Provider 'Enabled'
        ProviderKind = $providerKind
        BaseUrl = $baseUrl
        RequestDefinition = $requestDefinition
        ExtractorScript = $extractor
        TimeoutSeconds = Get-RelayProviderField $Provider 'TimeoutSeconds'
        IntervalMinutes = Get-RelayProviderField $Provider 'IntervalMinutes'
        TrustedDestination = $trust
        Secrets = Get-RelayProviderField $Provider 'Secrets'
    }
}

function ConvertTo-CanonicalRelayProviderDocument {
    [CmdletBinding()]
    param([AllowNull()][object]$Document)

    if (-not (Test-RelayProviderExactFields -InputObject $Document -Expected @('SchemaVersion','Providers'))) {
        return $null
    }
    $schemaVersion = Get-RelayProviderField $Document 'SchemaVersion'
    if (-not (Test-RelayProviderInteger -Value $schemaVersion -Minimum 2 -Maximum 2)) {
        return $null
    }
    $providers = Get-RelayProviderField $Document 'Providers'
    if ($null -eq $providers -or $providers -is [string] -or
        $providers -is [Collections.IDictionary] -or $providers -isnot [Collections.IEnumerable]) {
        return $null
    }
    $providerItems = @($providers)
    if ($providerItems.Count -gt 100) { return $null }
    $seenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $canonicalProviders = [Collections.Generic.List[object]]::new()
    foreach ($provider in $providerItems) {
        $canonical = ConvertTo-CanonicalRelayProvider -Provider $provider
        if ($null -eq $canonical -or -not $seenIds.Add([string]$canonical.Id)) {
            return $null
        }
        $canonicalProviders.Add($canonical)
    }
    [ordered]@{
        SchemaVersion = [int]2
        Providers = [object[]]$canonicalProviders.ToArray()
    }
}

function ConvertTo-CanonicalRelayProviderDocumentFromLegacy {
    [CmdletBinding()]
    param([AllowNull()][object]$Document)

    if (-not (Test-RelayProviderExactFields -InputObject $Document -Expected @('SchemaVersion','Providers'))) {
        return $null
    }
    $schemaVersion = Get-RelayProviderField $Document 'SchemaVersion'
    if (-not (Test-RelayProviderInteger -Value $schemaVersion -Minimum 1 -Maximum 1)) { return $null }
    $providers = Get-RelayProviderField $Document 'Providers'
    if ($null -eq $providers -or $providers -is [string] -or
        $providers -is [Collections.IDictionary] -or $providers -isnot [Collections.IEnumerable]) {
        return $null
    }
    $items = @($providers)
    if ($items.Count -gt 100) { return $null }
    $seenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $canonicalProviders = [Collections.Generic.List[object]]::new()
    foreach ($provider in $items) {
        $migrated = ConvertTo-CanonicalRelayLegacyProvider -Provider $provider
        if ($null -eq $migrated) { continue }
        $canonical = ConvertTo-CanonicalRelayProvider -Provider $migrated
        if ($null -ne $canonical -and $seenIds.Add([string]$canonical.Id)) {
            $canonicalProviders.Add($canonical)
        }
    }
    [ordered]@{
        SchemaVersion = [int]2
        Providers = [object[]]$canonicalProviders.ToArray()
    }
}

function ConvertTo-RelayProviderJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Document)
    return $Document | ConvertTo-Json -Depth 12 -Compress -ErrorAction Stop
}

function Write-CanonicalRelayProviderFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Document
    )

    $directory = [IO.Path]::GetDirectoryName($Path)
    $null = [IO.Directory]::CreateDirectory($directory)
    $fileName = [IO.Path]::GetFileName($Path)
    $temporaryPath = Join-Path $directory ".$fileName.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-RelayProviderJson -Document $Document
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream = [IO.FileStream]::new(
            $temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough
        )
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) {
            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            Set-Acl -LiteralPath $temporaryPath -AclObject $acl -ErrorAction Stop
            [IO.File]::Move($temporaryPath, $Path, $true)
        }
        else { [IO.File]::Move($temporaryPath, $Path) }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

function Read-RelayProviderStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Position = 1)][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $mutex = Enter-MonitorSettingsMutex -Path $fullPath
    try {
        if (-not [IO.File]::Exists($fullPath)) { return New-EmptyRelayProviderDocument }
        $json = [IO.File]::ReadAllText($fullPath)
        $canonical = $null
        try {
            $document = $json | ConvertFrom-Json -ErrorAction Stop
            $schemaVersion = Get-RelayProviderField $document 'SchemaVersion'
            if (Test-RelayProviderInteger -Value $schemaVersion -Minimum 2 -Maximum 2) {
                $canonical = ConvertTo-CanonicalRelayProviderDocument -Document $document
            }
            elseif (Test-RelayProviderInteger -Value $schemaVersion -Minimum 1 -Maximum 1) {
                $canonical = ConvertTo-CanonicalRelayProviderDocumentFromLegacy -Document $document
            }
        }
        catch { $canonical = $null }
        if ($null -eq $canonical) {
            $null = Move-CorruptMonitorSettings -Path $fullPath -Now $Now
            return New-EmptyRelayProviderDocument
        }
        if ($json -cne (ConvertTo-RelayProviderJson -Document $canonical)) {
            Write-CanonicalRelayProviderFile -Path $fullPath -Document $canonical
        }
        return $canonical
    }
    finally { Exit-MonitorSettingsMutex -Mutex $mutex }
}

function Write-RelayProviderStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Document
    )

    $canonical = ConvertTo-CanonicalRelayProviderDocument -Document $Document
    if ($null -eq $canonical) {
        throw [ArgumentException]::new('Relay provider document does not match the supported schema.')
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $mutex = Enter-MonitorSettingsMutex -Path $fullPath
    try { Write-CanonicalRelayProviderFile -Path $fullPath -Document $canonical }
    finally { Exit-MonitorSettingsMutex -Mutex $mutex }
}
