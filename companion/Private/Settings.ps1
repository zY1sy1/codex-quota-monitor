function Get-MonitorPaths {
    [CmdletBinding()]
    param(
        [string]$LocalAppData = $env:LOCALAPPDATA,

        [string]$Startup = [Environment]::GetFolderPath('Startup'),

        [AllowNull()]
        [string]$ProgramRoot
    )

    $root = Join-Path $LocalAppData 'CodexQuotaMonitor'
    $legacyApp = Join-Path $root 'app'
    $resolvedProgramRoot = if ([string]::IsNullOrWhiteSpace($ProgramRoot)) {
        $root
    }
    else {
        [IO.Path]::GetFullPath($ProgramRoot)
    }
    $app = if ($resolvedProgramRoot.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        $legacyApp
    }
    else {
        Join-Path $resolvedProgramRoot 'app'
    }

    [pscustomobject][ordered]@{
        Root = $root
        ProgramRoot = $resolvedProgramRoot
        App = $app
        LegacyApp = $legacyApp
        Payload = Join-Path $resolvedProgramRoot 'payload'
        Runtime = Join-Path $resolvedProgramRoot 'runtime\pwsh'
        PrivatePwsh = Join-Path $resolvedProgramRoot 'runtime\pwsh\pwsh.exe'
        Data = Join-Path $root 'data'
        Logs = Join-Path $root 'logs'
        Settings = Join-Path $root 'data\settings.json'
        Health = Join-Path $root 'data\health.json'
        RelayProviders = Join-Path $root 'data\relay-providers.json'
        RelayImportLinks = Join-Path $root 'data\relay-import-links.json'
        RelayCache = Join-Path $root 'data\relay-cache.json'
        RelayHost = Join-Path $app 'Bin\relay-quota-host.exe'
        RelayPresets = Join-Path $app 'Presets\relay-usage.json'
        StartupShortcut = Join-Path $Startup 'Codex Quota Monitor.lnk'
    }
}

function New-DefaultSettings {
    [CmdletBinding()]
    param()

    [ordered]@{
        SchemaVersion = 2
        Appearance = [ordered]@{
            Theme = 'Dark'
            DisplayMode = 'Full'
            FullLayout = 'Overview'
            RememberLastMode = $true
        }
        Window = [ordered]@{
            Full = [ordered]@{
                Left = $null
                Top = $null
                Width = [double]420
                Height = [double]560
                Topmost = $true
                Visible = $true
            }
            CompactBar = [ordered]@{
                Left = $null
                Top = $null
            }
            Orb = [ordered]@{
                Left = $null
                Top = $null
            }
        }
        Compact = [ordered]@{
            FocusMetric = 'Auto'
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

function Get-MonitorSettingsSchemaVersion {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or $Value.GetType().IsEnum -or
        (Test-MonitorSettingsCollection -Value $Value)) {
        return $null
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
        return $null
    }

    try {
        $version = [Convert]::ToDecimal(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture
        )
        if ($version -in @(1, 2)) {
            return [int]$version
        }
        return $null
    }
    catch {
        return $null
    }
}

function ConvertTo-MonitorSettingsCoordinate {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    if (-not (Test-MonitorSettingsFiniteNumber -Value $Value)) {
        throw [ArgumentException]::new('Monitor settings coordinate is invalid.')
    }
    return [double]$Value
}

function Test-MonitorSettingsRequiredFields {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in $Names) {
        if (-not (Test-MonitorSettingsHasField -InputObject $InputObject -Name $name)) {
            return $false
        }
    }
    return $true
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
    if (-not (Test-MonitorSettingsRequiredFields -InputObject $Settings `
        -Names @('SchemaVersion', 'Window', 'Startup'))) { return $null }

    $schemaVersion = Get-MonitorSettingsField -InputObject $Settings -Name 'SchemaVersion'
    $version = Get-MonitorSettingsSchemaVersion -Value $schemaVersion
    if ($null -eq $version) {
        return $null
    }

    $window = Get-MonitorSettingsField -InputObject $Settings -Name 'Window'
    if (-not (Test-MonitorSettingsObject -Value $window)) {
        return $null
    }
    $startup = Get-MonitorSettingsField -InputObject $Settings -Name 'Startup'
    if ($startup -isnot [bool]) {
        return $null
    }

    try {
        if ($version -eq 1) {
            if (-not (Test-MonitorSettingsRequiredFields -InputObject $window `
                -Names @('Left', 'Top', 'Topmost', 'Visible'))) { return $null }
            $topmost = Get-MonitorSettingsField -InputObject $window -Name 'Topmost'
            $visible = Get-MonitorSettingsField -InputObject $window -Name 'Visible'
            if ($topmost -isnot [bool] -or $visible -isnot [bool]) { return $null }

            $migrated = New-DefaultSettings
            $migrated.Window.Full.Left = ConvertTo-MonitorSettingsCoordinate (
                Get-MonitorSettingsField -InputObject $window -Name 'Left'
            )
            $migrated.Window.Full.Top = ConvertTo-MonitorSettingsCoordinate (
                Get-MonitorSettingsField -InputObject $window -Name 'Top'
            )
            $migrated.Window.Full.Topmost = [bool]$topmost
            $migrated.Window.Full.Visible = [bool]$visible
            $migrated.Startup = [bool]$startup
            Write-Output -NoEnumerate -InputObject $migrated
            return
        }

        if (-not (Test-MonitorSettingsRequiredFields -InputObject $Settings `
            -Names @('Appearance', 'Compact'))) { return $null }
        if (-not (Test-MonitorSettingsRequiredFields -InputObject $window `
            -Names @('Full', 'CompactBar', 'Orb'))) { return $null }

        $appearance = Get-MonitorSettingsField -InputObject $Settings -Name 'Appearance'
        $compact = Get-MonitorSettingsField -InputObject $Settings -Name 'Compact'
        $full = Get-MonitorSettingsField -InputObject $window -Name 'Full'
        $compactBar = Get-MonitorSettingsField -InputObject $window -Name 'CompactBar'
        $orb = Get-MonitorSettingsField -InputObject $window -Name 'Orb'
        foreach ($node in @($appearance, $compact, $full, $compactBar, $orb)) {
            if (-not (Test-MonitorSettingsObject -Value $node)) { return $null }
        }
        if (-not (Test-MonitorSettingsRequiredFields -InputObject $appearance `
            -Names @('Theme', 'DisplayMode', 'FullLayout', 'RememberLastMode')) -or
            -not (Test-MonitorSettingsRequiredFields -InputObject $full `
            -Names @('Left', 'Top', 'Width', 'Height', 'Topmost', 'Visible')) -or
            -not (Test-MonitorSettingsRequiredFields -InputObject $compactBar `
            -Names @('Left', 'Top')) -or
            -not (Test-MonitorSettingsRequiredFields -InputObject $orb `
            -Names @('Left', 'Top')) -or
            -not (Test-MonitorSettingsRequiredFields -InputObject $compact `
            -Names @('FocusMetric'))) { return $null }

        $theme = Get-MonitorSettingsField -InputObject $appearance -Name 'Theme'
        $displayMode = Get-MonitorSettingsField -InputObject $appearance -Name 'DisplayMode'
        $fullLayout = Get-MonitorSettingsField -InputObject $appearance -Name 'FullLayout'
        $rememberLastMode = Get-MonitorSettingsField -InputObject $appearance -Name 'RememberLastMode'
        $topmost = Get-MonitorSettingsField -InputObject $full -Name 'Topmost'
        $visible = Get-MonitorSettingsField -InputObject $full -Name 'Visible'
        $focusMetric = Get-MonitorSettingsField -InputObject $compact -Name 'FocusMetric'
        if ($theme -isnot [string] -or $theme -notin @('Light', 'Dark') -or
            $displayMode -isnot [string] -or $displayMode -notin @('Full', 'CompactBar', 'Orb') -or
            $fullLayout -isnot [string] -or $fullLayout -notin @('Overview', 'Tabs') -or
            $rememberLastMode -isnot [bool] -or $topmost -isnot [bool] -or
            $visible -isnot [bool] -or $focusMetric -isnot [string] -or
            [string]::IsNullOrWhiteSpace($focusMetric) -or $focusMetric.Length -gt 4096) {
            return $null
        }

        $width = ConvertTo-MonitorSettingsCoordinate (
            Get-MonitorSettingsField -InputObject $full -Name 'Width'
        )
        $height = ConvertTo-MonitorSettingsCoordinate (
            Get-MonitorSettingsField -InputObject $full -Name 'Height'
        )
        if ($null -eq $width -or $null -eq $height -or $width -le 0 -or $height -le 0) {
            return $null
        }

        $canonical = [ordered]@{
            SchemaVersion = 2
            Appearance = [ordered]@{
                Theme = $theme
                DisplayMode = $displayMode
                FullLayout = $fullLayout
                RememberLastMode = [bool]$rememberLastMode
            }
            Window = [ordered]@{
                Full = [ordered]@{
                    Left = ConvertTo-MonitorSettingsCoordinate (
                        Get-MonitorSettingsField -InputObject $full -Name 'Left'
                    )
                    Top = ConvertTo-MonitorSettingsCoordinate (
                        Get-MonitorSettingsField -InputObject $full -Name 'Top'
                    )
                    Width = [double]$width
                    Height = [double]$height
                    Topmost = [bool]$topmost
                    Visible = [bool]$visible
                }
                CompactBar = [ordered]@{
                    Left = ConvertTo-MonitorSettingsCoordinate (
                        Get-MonitorSettingsField -InputObject $compactBar -Name 'Left'
                    )
                    Top = ConvertTo-MonitorSettingsCoordinate (
                        Get-MonitorSettingsField -InputObject $compactBar -Name 'Top'
                    )
                }
                Orb = [ordered]@{
                    Left = ConvertTo-MonitorSettingsCoordinate (
                        Get-MonitorSettingsField -InputObject $orb -Name 'Left'
                    )
                    Top = ConvertTo-MonitorSettingsCoordinate (
                        Get-MonitorSettingsField -InputObject $orb -Name 'Top'
                    )
                }
            }
            Compact = [ordered]@{ FocusMetric = $focusMetric }
            Startup = [bool]$startup
        }
        Write-Output -NoEnumerate -InputObject $canonical
    }
    catch {
        return $null
    }
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
