function New-EmptyRelayImportLinkDocument {
    [CmdletBinding()]
    param()

    [pscustomobject][ordered]@{
        SchemaVersion = [int]1
        Links = [object[]]@()
    }
}

function ConvertTo-CanonicalRelayImportProviderId {
    param([AllowNull()][object]$Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse([string]$Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        return $null
    }
    return $parsed.ToString('D').ToLowerInvariant()
}

function Test-RelayImportLinkText {
    param([AllowNull()][object]$Value)
    return $Value -is [string] -and
        -not [string]::IsNullOrWhiteSpace([string]$Value) -and
        (Test-RelayProviderSafeText -Value $Value -MaximumBytes 4096)
}

function ConvertTo-CanonicalRelayImportLink {
    [CmdletBinding()]
    param([AllowNull()][object]$Link)

    if (-not (Test-RelayProviderExactFields -InputObject $Link -Expected @(
        'RelayProviderId', 'SourceKind', 'SourceProviderId', 'SourceAppType',
        'ScriptFingerprint'
    ))) {
        return $null
    }
    $relayProviderId = ConvertTo-CanonicalRelayImportProviderId (
        Get-RelayProviderField $Link 'RelayProviderId'
    )
    $sourceKind = Get-RelayProviderField $Link 'SourceKind'
    $sourceProviderId = Get-RelayProviderField $Link 'SourceProviderId'
    $sourceAppType = Get-RelayProviderField $Link 'SourceAppType'
    $fingerprint = Get-RelayProviderField $Link 'ScriptFingerprint'
    if ($null -eq $relayProviderId -or $sourceKind -isnot [string] -or
        $sourceKind -cne 'CcSwitchUsageScript' -or
        -not (Test-RelayImportLinkText $sourceProviderId) -or
        -not (Test-RelayImportLinkText $sourceAppType) -or
        $fingerprint -isnot [string] -or $fingerprint -cnotmatch '^[0-9a-f]{64}$') {
        return $null
    }
    [pscustomobject][ordered]@{
        RelayProviderId = $relayProviderId
        SourceKind = 'CcSwitchUsageScript'
        SourceProviderId = [string]$sourceProviderId
        SourceAppType = [string]$sourceAppType
        ScriptFingerprint = [string]$fingerprint
    }
}

function ConvertTo-CanonicalRelayImportLinkDocument {
    [CmdletBinding()]
    param([AllowNull()][object]$Document)

    if (-not (Test-RelayProviderExactFields -InputObject $Document -Expected @(
        'SchemaVersion', 'Links'
    ))) {
        return $null
    }
    $schemaVersion = Get-RelayProviderField $Document 'SchemaVersion'
    if (-not (Test-RelayProviderInteger -Value $schemaVersion -Minimum 1 -Maximum 1)) {
        return $null
    }
    $links = Get-RelayProviderField $Document 'Links'
    if ($null -eq $links -or $links -is [string] -or
        $links -is [Collections.IDictionary] -or
        $links -isnot [Collections.IEnumerable]) {
        return $null
    }
    $linkItems = @($links)
    if ($linkItems.Count -gt 100) {
        return $null
    }
    $seenProviderIds = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $seenSources = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $canonicalLinks = [Collections.Generic.List[object]]::new()
    foreach ($link in $linkItems) {
        $canonical = ConvertTo-CanonicalRelayImportLink $link
        if ($null -eq $canonical) {
            return $null
        }
        $sourceKey = '{0}{3}{1}{3}{2}' -f @(
            $canonical.SourceKind,
            $canonical.SourceProviderId,
            $canonical.SourceAppType,
            [char]0
        )
        if (-not $seenProviderIds.Add([string]$canonical.RelayProviderId) -or
            -not $seenSources.Add($sourceKey)) {
            return $null
        }
        $canonicalLinks.Add($canonical)
    }
    [pscustomobject][ordered]@{
        SchemaVersion = [int]1
        Links = [object[]]$canonicalLinks.ToArray()
    }
}

function ConvertTo-RelayImportLinkJson {
    param([Parameter(Mandatory)][object]$Document)
    return $Document | ConvertTo-Json -Depth 6 -Compress -ErrorAction Stop
}

function Write-CanonicalRelayImportLinkFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Document
    )
    $directory = [IO.Path]::GetDirectoryName($Path)
    $null = [IO.Directory]::CreateDirectory($directory)
    $fileName = [IO.Path]::GetFileName($Path)
    $temporaryPath = Join-Path $directory ".$fileName.$([guid]::NewGuid().ToString('N')).tmp"
    [byte[]]$bytes = $null
    try {
        $json = ConvertTo-RelayImportLinkJson $Document
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream = [IO.FileStream]::new(
            $temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough
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
        if ($null -ne $bytes) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

function Read-RelayImportLinkStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Position = 1)][DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $mutex = Enter-MonitorSettingsMutex -Path $fullPath
    try {
        if (-not [IO.File]::Exists($fullPath)) {
            return New-EmptyRelayImportLinkDocument
        }
        $json = [IO.File]::ReadAllText($fullPath)
        $canonical = $null
        try {
            $document = $json | ConvertFrom-Json -Depth 8 -ErrorAction Stop
            $canonical = ConvertTo-CanonicalRelayImportLinkDocument $document
        }
        catch {
            $canonical = $null
        }
        if ($null -eq $canonical) {
            $null = Move-CorruptMonitorSettings -Path $fullPath -Now $Now
            return New-EmptyRelayImportLinkDocument
        }
        if ($json -cne (ConvertTo-RelayImportLinkJson $canonical)) {
            Write-CanonicalRelayImportLinkFile -Path $fullPath -Document $canonical
        }
        return $canonical
    }
    finally {
        Exit-MonitorSettingsMutex -Mutex $mutex
    }
}

function Write-RelayImportLinkStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Document
    )
    $canonical = ConvertTo-CanonicalRelayImportLinkDocument $Document
    if ($null -eq $canonical) {
        throw [ArgumentException]::new('Relay import link document does not match the supported schema.')
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $mutex = Enter-MonitorSettingsMutex -Path $fullPath
    try {
        Write-CanonicalRelayImportLinkFile -Path $fullPath -Document $canonical
    }
    finally {
        Exit-MonitorSettingsMutex -Mutex $mutex
    }
}

function New-RelayImportLinkMutation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('None','Upsert','Remove')][string]$Kind,
        [AllowNull()][object]$Link = $null,
        [AllowNull()][string]$ProviderId = $null
    )
    [pscustomobject][ordered]@{
        Kind = $Kind
        Link = $Link
        ProviderId = $ProviderId
    }
}

function Test-RelayImportSourceEqual {
    param(
        [Parameter(Mandatory)][object]$Left,
        [Parameter(Mandatory)][object]$Right
    )
    return [string]::Equals(
        [string]$Left.SourceKind, [string]$Right.SourceKind,
        [StringComparison]::OrdinalIgnoreCase
    ) -and [string]::Equals(
        [string]$Left.SourceProviderId, [string]$Right.SourceProviderId,
        [StringComparison]::OrdinalIgnoreCase
    ) -and [string]::Equals(
        [string]$Left.SourceAppType, [string]$Right.SourceAppType,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Update-RelayImportLinkDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][object]$Mutation
    )
    $canonical = ConvertTo-CanonicalRelayImportLinkDocument $Document
    if ($null -eq $canonical -or -not (Test-RelayProviderExactFields $Mutation @(
        'Kind', 'Link', 'ProviderId'
    ))) {
        throw 'Relay import link store is invalid.'
    }
    $kind = Get-RelayProviderField $Mutation 'Kind'
    switch ($kind) {
        'None' {
            return $canonical
        }
        'Remove' {
            $providerId = ConvertTo-CanonicalRelayImportProviderId (
                Get-RelayProviderField $Mutation 'ProviderId'
            )
            if ($null -eq $providerId) {
                throw 'Relay import link mutation is invalid.'
            }
            $links = @($canonical.Links | Where-Object RelayProviderId -CNE $providerId)
        }
        'Upsert' {
            $link = ConvertTo-CanonicalRelayImportLink (Get-RelayProviderField $Mutation 'Link')
            if ($null -eq $link) {
                throw 'Relay import link is invalid.'
            }
            $links = @($canonical.Links | Where-Object {
                $_.RelayProviderId -cne $link.RelayProviderId -and
                    -not (Test-RelayImportSourceEqual -Left $_ -Right $link)
            }) + @($link)
        }
        default {
            throw 'Relay import link mutation is invalid.'
        }
    }
    $result = ConvertTo-CanonicalRelayImportLinkDocument ([pscustomobject][ordered]@{
        SchemaVersion = 1
        Links = [object[]]$links
    })
    if ($null -eq $result) {
        throw 'Relay import link mutation is invalid.'
    }
    return $result
}

function Restore-RelayImportTransactionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$Existed,
        [AllowNull()][byte[]]$Bytes
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $Existed) {
        if ([IO.File]::Exists($fullPath)) {
            [IO.File]::Delete($fullPath)
        }
        return
    }
    if ($null -eq $Bytes) {
        throw 'Transaction backup bytes are missing.'
    }
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $tempPath = Join-Path $directory (
        '.{0}.restore.{1}.tmp' -f [IO.Path]::GetFileName($fullPath), [guid]::NewGuid().ToString('N')
    )
    try {
        [IO.File]::WriteAllBytes($tempPath, $Bytes)
        if ([IO.File]::Exists($fullPath)) {
            $acl = Get-Acl -LiteralPath $fullPath -ErrorAction Stop
            Set-Acl -LiteralPath $tempPath -AclObject $acl -ErrorAction Stop
            [IO.File]::Move($tempPath, $fullPath, $true)
        }
        else {
            [IO.File]::Move($tempPath, $fullPath)
        }
    }
    finally {
        if ([IO.File]::Exists($tempPath)) {
            [IO.File]::Delete($tempPath)
        }
    }
}

function Write-RelayProviderImportTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProviderPath,
        [Parameter(Mandatory)][string]$LinkPath,
        [Parameter(Mandatory)][object]$ProviderDocument,
        [Parameter(Mandatory)][object]$Mutation,
        [scriptblock]$ReplaceProviderFile = ${function:Write-RelayProviderStore},
        [scriptblock]$ReplaceLinkFile = ${function:Write-RelayImportLinkStore}
    )
    $providers = ConvertTo-CanonicalRelayProviderDocument $ProviderDocument
    if ($null -eq $providers) {
        throw 'Relay provider store is invalid.'
    }
    $providerFullPath = [IO.Path]::GetFullPath($ProviderPath)
    $linkFullPath = [IO.Path]::GetFullPath($LinkPath)
    $transactionMutex = Enter-MonitorSettingsMutex -Path "$providerFullPath.import-transaction"
    try {
        $currentLinks = Read-RelayImportLinkStore -Path $linkFullPath
        $nextLinks = Update-RelayImportLinkDocument -Document $currentLinks -Mutation $Mutation
        $providerExisted = [IO.File]::Exists($providerFullPath)
        $linkExisted = [IO.File]::Exists($linkFullPath)
        [byte[]]$providerBackup = if ($providerExisted) {
            [IO.File]::ReadAllBytes($providerFullPath)
        }
        else {
            $null
        }
        [byte[]]$linkBackup = if ($linkExisted) {
            [IO.File]::ReadAllBytes($linkFullPath)
        }
        else {
            $null
        }
        try {
            & $ReplaceProviderFile -Path $providerFullPath -Document $providers
            & $ReplaceLinkFile -Path $linkFullPath -Document $nextLinks
        }
        catch {
            $writeError = $_
            $rollbackErrors = [Collections.Generic.List[Exception]]::new()
            try {
                Restore-RelayImportTransactionFile -Path $providerFullPath `
                    -Existed $providerExisted -Bytes $providerBackup
            }
            catch {
                $rollbackErrors.Add($_.Exception)
            }
            try {
                Restore-RelayImportTransactionFile -Path $linkFullPath `
                    -Existed $linkExisted -Bytes $linkBackup
            }
            catch {
                $rollbackErrors.Add($_.Exception)
            }
            if ($rollbackErrors.Count -gt 0) {
                $allErrors = [Collections.Generic.List[Exception]]::new()
                $allErrors.Add($writeError.Exception)
                foreach ($rollbackError in $rollbackErrors) {
                    $allErrors.Add($rollbackError)
                }
                throw [AggregateException]::new(
                    'Relay provider import failed and rollback was incomplete.', $allErrors
                )
            }
            throw [InvalidOperationException]::new(
                'Relay provider import transaction failed and was rolled back.',
                $writeError.Exception
            )
        }
        finally {
            if ($null -ne $providerBackup) {
                [Array]::Clear($providerBackup, 0, $providerBackup.Length)
            }
            if ($null -ne $linkBackup) {
                [Array]::Clear($linkBackup, 0, $linkBackup.Length)
            }
        }
    }
    finally {
        Exit-MonitorSettingsMutex -Mutex $transactionMutex
    }
}
