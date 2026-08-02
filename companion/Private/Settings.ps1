function Get-MonitorPaths {
    [CmdletBinding()]
    param(
        [string]$LocalAppData = $env:LOCALAPPDATA,

        [string]$Startup = [Environment]::GetFolderPath('Startup')
    )

    $root = Join-Path $LocalAppData 'CodexQuotaMonitor'
    [pscustomobject][ordered]@{
        Root = $root
        App = Join-Path $root 'app'
        Data = Join-Path $root 'data'
        Logs = Join-Path $root 'logs'
        Settings = Join-Path $root 'data\settings.json'
        Health = Join-Path $root 'data\health.json'
        RelayProviders = Join-Path $root 'data\relay-providers.json'
        RelayCache = Join-Path $root 'data\relay-cache.json'
        RelayHost = Join-Path $root 'app\Bin\relay-quota-host.exe'
        RelayPresets = Join-Path $root 'app\Presets\relay-usage.json'
        StartupShortcut = Join-Path $Startup 'Codex Quota Monitor.lnk'
    }
}

function New-DefaultSettings {
    [CmdletBinding()]
    param()

    [ordered]@{
        SchemaVersion = 1
        Window = [ordered]@{
            Left = $null
            Top = $null
            Topmost = $true
            Visible = $true
        }
        Startup = $true
    }
}

function Test-MonitorSettingsObject {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    return $null -ne $Value -and (
        $Value -is [System.Collections.IDictionary] -or
        $Value -is [pscustomobject]
    )
}

function Test-MonitorSettingsHasField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        return ([System.Collections.IDictionary]$InputObject).Contains($Name)
    }

    return $null -ne $InputObject.PSObject.Properties[$Name]
}

function Get-MonitorSettingsField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name
    )

    $value = $null
    if ($InputObject -is [System.Collections.IDictionary]) {
        $value = ([System.Collections.IDictionary]$InputObject)[$Name]
    }
    else {
        $value = $InputObject.PSObject.Properties[$Name].Value
    }

    Write-Output -NoEnumerate -InputObject $value
}

function Test-MonitorSettingsCollection {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    return $null -ne $Value -and
        $Value -is [System.Collections.IEnumerable] -and
        $Value -isnot [string]
}

function Test-MonitorSettingsFiniteNumber {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or $Value.GetType().IsEnum -or
        (Test-MonitorSettingsCollection -Value $Value)) {
        return $false
    }

    $typeCode = [Type]::GetTypeCode($Value.GetType())
    if ($typeCode -notin @(
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
        return $false
    }

    try {
        $number = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return $false
    }

    return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
}

function Test-MonitorSettingsSchemaVersion {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or $Value.GetType().IsEnum -or
        (Test-MonitorSettingsCollection -Value $Value)) {
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
        return [Convert]::ToDecimal(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture
        ) -eq 1
    }
    catch {
        return $false
    }
}

function ConvertTo-CanonicalMonitorSettings {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Settings
    )

    if (-not (Test-MonitorSettingsObject -Value $Settings)) {
        return $null
    }
    foreach ($name in @('SchemaVersion', 'Window', 'Startup')) {
        if (-not (Test-MonitorSettingsHasField -InputObject $Settings -Name $name)) {
            return $null
        }
    }

    $schemaVersion = Get-MonitorSettingsField -InputObject $Settings -Name 'SchemaVersion'
    if (-not (Test-MonitorSettingsSchemaVersion -Value $schemaVersion)) {
        return $null
    }

    $window = Get-MonitorSettingsField -InputObject $Settings -Name 'Window'
    if (-not (Test-MonitorSettingsObject -Value $window)) {
        return $null
    }
    foreach ($name in @('Left', 'Top', 'Topmost', 'Visible')) {
        if (-not (Test-MonitorSettingsHasField -InputObject $window -Name $name)) {
            return $null
        }
    }

    $left = Get-MonitorSettingsField -InputObject $window -Name 'Left'
    $top = Get-MonitorSettingsField -InputObject $window -Name 'Top'
    if ($null -ne $left -and -not (Test-MonitorSettingsFiniteNumber -Value $left)) {
        return $null
    }
    if ($null -ne $top -and -not (Test-MonitorSettingsFiniteNumber -Value $top)) {
        return $null
    }

    $topmost = Get-MonitorSettingsField -InputObject $window -Name 'Topmost'
    $visible = Get-MonitorSettingsField -InputObject $window -Name 'Visible'
    $startup = Get-MonitorSettingsField -InputObject $Settings -Name 'Startup'
    if ($topmost -isnot [bool] -or $visible -isnot [bool] -or $startup -isnot [bool]) {
        return $null
    }

    $canonical = [ordered]@{
        SchemaVersion = [int]1
        Window = [ordered]@{
            Left = $left
            Top = $top
            Topmost = [bool]$topmost
            Visible = [bool]$visible
        }
        Startup = [bool]$startup
    }
    Write-Output -NoEnumerate -InputObject $canonical
}

function Test-MonitorSettingsDocument {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Settings
    )

    return $null -ne (ConvertTo-CanonicalMonitorSettings -Settings $Settings)
}

function Get-MonitorSettingsMutexName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    $normalizedPath = [IO.Path]::GetFullPath($Path).ToUpperInvariant()
    $pathBytes = [Text.UTF8Encoding]::new($false).GetBytes($normalizedPath)
    $hashBytes = [Security.Cryptography.SHA256]::HashData($pathBytes)
    return 'Local\CodexQuotaMonitor.Settings.' + [Convert]::ToHexString($hashBytes)
}

function Enter-MonitorSettingsMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Position = 1)]
        [ValidateRange(1, 60000)]
        [int]$TimeoutMilliseconds = 10000
    )

    $mutex = [Threading.Mutex]::new($false, (Get-MonitorSettingsMutexName -Path $Path))
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if (-not $acquired) {
            throw [TimeoutException]::new('Timed out waiting for monitor settings persistence.')
        }

        return $mutex
    }
    catch {
        if (-not $acquired) {
            $mutex.Dispose()
        }
        throw
    }
}

function Exit-MonitorSettingsMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [Threading.Mutex]$Mutex
    )

    try {
        $Mutex.ReleaseMutex()
    }
    finally {
        $Mutex.Dispose()
    }
}

function Move-CorruptMonitorSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [DateTimeOffset]$Now
    )

    $timestamp = $Now.ToUniversalTime().ToString(
        'yyyyMMddTHHmmssfffZ',
        [Globalization.CultureInfo]::InvariantCulture
    )
    $baseDestination = "$Path.corrupt-$timestamp"
    $destination = $baseDestination
    $suffix = 0
    while ([IO.File]::Exists($destination) -or [IO.Directory]::Exists($destination)) {
        $suffix++
        $destination = "$baseDestination.$suffix"
    }

    [IO.File]::Move($Path, $destination)
    return $destination
}

function Remove-MonitorSettingsArtifactFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    [IO.File]::Delete($Path)
}

function ConvertTo-MonitorSettingsJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$Settings
    )

    return $Settings | ConvertTo-Json -Depth 5 -Compress -ErrorAction Stop
}

function Write-CanonicalMonitorSettingsFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [object]$Settings
    )

    $directory = [IO.Path]::GetDirectoryName($Path)
    $null = [IO.Directory]::CreateDirectory($directory)
    $fileName = [IO.Path]::GetFileName($Path)
    $temporaryId = [Guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $directory ".$fileName.$temporaryId.tmp"
    try {
        $json = ConvertTo-MonitorSettingsJson -Settings $Settings
        $encoding = [Text.UTF8Encoding]::new($false)
        $bytes = $encoding.GetBytes($json)

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
            $securityDescriptor = Get-Acl -LiteralPath $Path -ErrorAction Stop
            Set-Acl -LiteralPath $temporaryPath -AclObject $securityDescriptor -ErrorAction Stop
            [IO.File]::Move($temporaryPath, $Path, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            Remove-MonitorSettingsArtifactFile -Path $temporaryPath
        }
    }
}

function Read-MonitorSettings {
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
            return New-DefaultSettings
        }

        $json = [IO.File]::ReadAllText($fullPath)
        $canonical = $null
        try {
            $settings = $json | ConvertFrom-Json -ErrorAction Stop
            $canonical = ConvertTo-CanonicalMonitorSettings -Settings $settings
        }
        catch {
            $canonical = $null
        }

        if ($null -eq $canonical) {
            $null = Move-CorruptMonitorSettings -Path $fullPath -Now $Now
            return New-DefaultSettings
        }

        $canonicalJson = ConvertTo-MonitorSettingsJson -Settings $canonical
        if ($json -cne $canonicalJson) {
            Write-CanonicalMonitorSettingsFile -Path $fullPath -Settings $canonical
        }

        return $canonical
    }
    finally {
        Exit-MonitorSettingsMutex -Mutex $mutex
    }
}

function Write-MonitorSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [object]$Settings
    )

    $canonical = ConvertTo-CanonicalMonitorSettings -Settings $Settings
    if ($null -eq $canonical) {
        throw [ArgumentException]::new('Settings do not match the supported schema.')
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    $mutex = Enter-MonitorSettingsMutex -Path $fullPath
    try {
        Write-CanonicalMonitorSettingsFile -Path $fullPath -Settings $canonical
    }
    finally {
        Exit-MonitorSettingsMutex -Mutex $mutex
    }
}
