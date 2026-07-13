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

    if ($InputObject -is [System.Collections.IDictionary]) {
        return ([System.Collections.IDictionary]$InputObject)[$Name]
    }

    return $InputObject.PSObject.Properties[$Name].Value
}

function Test-MonitorSettingsFiniteNumber {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or $Value.GetType().IsEnum) {
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

function Test-MonitorSettingsDocument {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Settings
    )

    if (-not (Test-MonitorSettingsObject -Value $Settings)) {
        return $false
    }

    foreach ($name in @('SchemaVersion', 'Window', 'Startup')) {
        if (-not (Test-MonitorSettingsHasField -InputObject $Settings -Name $name)) {
            return $false
        }
    }

    $schemaVersion = Get-MonitorSettingsField -InputObject $Settings -Name 'SchemaVersion'
    if (-not (Test-MonitorSettingsFiniteNumber -Value $schemaVersion)) {
        return $false
    }
    try {
        if ([Convert]::ToDecimal($schemaVersion, [Globalization.CultureInfo]::InvariantCulture) -ne 1) {
            return $false
        }
    }
    catch {
        return $false
    }

    $window = Get-MonitorSettingsField -InputObject $Settings -Name 'Window'
    if (-not (Test-MonitorSettingsObject -Value $window)) {
        return $false
    }
    foreach ($name in @('Left', 'Top', 'Topmost', 'Visible')) {
        if (-not (Test-MonitorSettingsHasField -InputObject $window -Name $name)) {
            return $false
        }
    }

    foreach ($name in @('Left', 'Top')) {
        $coordinate = Get-MonitorSettingsField -InputObject $window -Name $name
        if ($null -ne $coordinate -and -not (Test-MonitorSettingsFiniteNumber -Value $coordinate)) {
            return $false
        }
    }

    foreach ($value in @(
        (Get-MonitorSettingsField -InputObject $window -Name 'Topmost'),
        (Get-MonitorSettingsField -InputObject $window -Name 'Visible'),
        (Get-MonitorSettingsField -InputObject $Settings -Name 'Startup')
    )) {
        if ($value -isnot [bool]) {
            return $false
        }
    }

    return $true
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

function Read-MonitorSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Position = 1)]
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($fullPath)) {
        return New-DefaultSettings
    }

    $json = [IO.File]::ReadAllText($fullPath)
    $settings = $null
    $valid = $false
    try {
        $settings = $json | ConvertFrom-Json -ErrorAction Stop
        $valid = Test-MonitorSettingsDocument -Settings $settings
    }
    catch {
        $valid = $false
    }

    if (-not $valid) {
        $null = Move-CorruptMonitorSettings -Path $fullPath -Now $Now
        return New-DefaultSettings
    }

    return $settings
}

function Write-MonitorSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [object]$Settings
    )

    if (-not (Test-MonitorSettingsDocument -Settings $Settings)) {
        throw [ArgumentException]::new('Settings do not match the supported schema.')
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    $null = [IO.Directory]::CreateDirectory($directory)

    $fileName = [IO.Path]::GetFileName($fullPath)
    $temporaryId = [Guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $directory ".$fileName.$temporaryId.tmp"
    $backupPath = Join-Path $directory ".$fileName.$temporaryId.backup.tmp"
    try {
        $json = $Settings | ConvertTo-Json -Depth 10 -Compress -ErrorAction Stop
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

        if ([IO.File]::Exists($fullPath)) {
            [IO.File]::Replace($temporaryPath, $fullPath, $backupPath, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $fullPath)
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if ([IO.File]::Exists($backupPath)) {
            [IO.File]::Delete($backupPath)
        }
    }
}
