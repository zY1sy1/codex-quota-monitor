function Test-MonitorLogScalarValue {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $true
    }
    if ($Value -is [string] -or $Value -is [char] -or
        $Value -is [DateTimeOffset] -or $Value -is [Guid]) {
        return $true
    }
    if ($Value.GetType().IsEnum) {
        return $false
    }

    $typeCode = [Type]::GetTypeCode($Value.GetType())
    if ($typeCode -in @(
        [TypeCode]::Boolean,
        [TypeCode]::SByte,
        [TypeCode]::Byte,
        [TypeCode]::Int16,
        [TypeCode]::UInt16,
        [TypeCode]::Int32,
        [TypeCode]::UInt32,
        [TypeCode]::Int64,
        [TypeCode]::UInt64,
        [TypeCode]::Decimal,
        [TypeCode]::DateTime
    )) {
        return $true
    }
    if ($typeCode -in @([TypeCode]::Single, [TypeCode]::Double)) {
        $number = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
        return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
    }

    return $false
}

function Get-MonitorLogMutexName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    $normalizedPath = [IO.Path]::GetFullPath($Path).ToUpperInvariant()
    $pathBytes = [Text.UTF8Encoding]::new($false).GetBytes($normalizedPath)
    $hashBytes = [Security.Cryptography.SHA256]::HashData($pathBytes)
    return 'Local\CodexQuotaMonitor.Log.' + [Convert]::ToHexString($hashBytes)
}

function Enter-MonitorLogMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Position = 1)]
        [ValidateRange(1, 60000)]
        [int]$TimeoutMilliseconds = 10000
    )

    $mutex = [Threading.Mutex]::new($false, (Get-MonitorLogMutexName -Path $Path))
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if (-not $acquired) {
            throw [TimeoutException]::new('Timed out waiting for monitor log persistence.')
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

function Exit-MonitorLogMutex {
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

function Remove-MonitorLogTemporaryFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    [IO.File]::Delete($Path)
}

function Remove-MonitorLogBackupFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    [IO.File]::Delete($Path)
}

function Write-MonitorLogTemporaryBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [byte[]]$Bytes
    )

    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        4096,
        [IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Copy-MonitorLogTemporaryFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$SourcePath,

        [Parameter(Mandatory, Position = 1)]
        [string]$TemporaryPath
    )

    $source = [IO.FileStream]::new(
        $SourcePath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $temporary = [IO.FileStream]::new(
            $TemporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $source.CopyTo($temporary)
            $temporary.Flush($true)
        }
        finally {
            $temporary.Dispose()
        }
    }
    finally {
        $source.Dispose()
    }
}

function Complete-MonitorLogAtomicFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$TemporaryPath,

        [Parameter(Mandatory, Position = 1)]
        [string]$DestinationPath,

        [Parameter(Mandatory, Position = 2)]
        [string]$BackupPath
    )

    if ([IO.File]::Exists($DestinationPath)) {
        [IO.File]::Replace($TemporaryPath, $DestinationPath, $BackupPath, $true)
    }
    else {
        [IO.File]::Move($TemporaryPath, $DestinationPath)
    }
}

function Copy-MonitorLogFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$SourcePath,

        [Parameter(Mandatory, Position = 1)]
        [string]$DestinationPath
    )

    $directory = [IO.Path]::GetDirectoryName($DestinationPath)
    $fileName = [IO.Path]::GetFileName($DestinationPath)
    $temporaryId = [Guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $directory ".$fileName.$temporaryId.tmp"
    $backupPath = Join-Path $directory ".$fileName.$temporaryId.backup.tmp"
    try {
        Copy-MonitorLogTemporaryFile -SourcePath $SourcePath -TemporaryPath $temporaryPath
        Complete-MonitorLogAtomicFile -TemporaryPath $temporaryPath -DestinationPath $DestinationPath -BackupPath $backupPath
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            try {
                Remove-MonitorLogTemporaryFile -Path $temporaryPath
            }
            catch {
                # Temporary cleanup is best effort; the source was never removed.
            }
        }
        if ([IO.File]::Exists($backupPath)) {
            try {
                Remove-MonitorLogBackupFile -Path $backupPath
            }
            catch {
                # A committed target remains authoritative if backup cleanup fails.
            }
        }
    }
}

function Write-MonitorLogFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [byte[]]$Bytes
    )

    $directory = [IO.Path]::GetDirectoryName($Path)
    $fileName = [IO.Path]::GetFileName($Path)
    $temporaryId = [Guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $directory ".$fileName.$temporaryId.tmp"
    $backupPath = Join-Path $directory ".$fileName.$temporaryId.backup.tmp"
    try {
        Write-MonitorLogTemporaryBytes -Path $temporaryPath -Bytes $Bytes
        Complete-MonitorLogAtomicFile -TemporaryPath $temporaryPath -DestinationPath $Path -BackupPath $backupPath
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            try {
                Remove-MonitorLogTemporaryFile -Path $temporaryPath
            }
            catch {
                # Temporary cleanup is best effort; the previous target remains authoritative.
            }
        }
        if ([IO.File]::Exists($backupPath)) {
            try {
                Remove-MonitorLogBackupFile -Path $backupPath
            }
            catch {
                # A committed target remains authoritative if backup cleanup fails.
            }
        }
    }
}

function Invoke-MonitorLogRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$LogDirectory,

        [Parameter(Mandatory, Position = 1)]
        [int]$RetainedFiles
    )

    if ($RetainedFiles -eq 0) {
        return
    }

    for ($index = $RetainedFiles - 1; $index -ge 1; $index--) {
        $source = Join-Path $LogDirectory "monitor.$index.log"
        if (-not [IO.File]::Exists($source)) {
            continue
        }

        $destination = Join-Path $LogDirectory "monitor.$($index + 1).log"
        Copy-MonitorLogFileAtomic -SourcePath $source -DestinationPath $destination
    }

    $currentPath = Join-Path $LogDirectory 'monitor.log'
    if ([IO.File]::Exists($currentPath)) {
        $firstRotatedPath = Join-Path $LogDirectory 'monitor.1.log'
        Copy-MonitorLogFileAtomic -SourcePath $currentPath -DestinationPath $firstRotatedPath
    }
}

function Write-MonitorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$LogDirectory,

        [Parameter(Mandatory, Position = 1)]
        [string]$Level,

        [Parameter(Mandatory, Position = 2)]
        [string]$Event,

        [Parameter(Position = 3)]
        [AllowNull()]
        [object]$Data = $null,

        [Parameter(Position = 4)]
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,

        [Parameter(Position = 5)]
        [long]$MaximumBytes = 1MB,

        [Parameter(Position = 6)]
        [int]$RetainedFiles = 5
    )

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        throw [ArgumentException]::new('A log directory is required.')
    }
    if ([string]::IsNullOrWhiteSpace($Level) -or [string]::IsNullOrWhiteSpace($Event)) {
        throw [ArgumentException]::new('Log level and event are required.')
    }
    if ($MaximumBytes -le 0) {
        throw [ArgumentOutOfRangeException]::new('MaximumBytes', 'MaximumBytes must be positive.')
    }
    if ($RetainedFiles -lt 0) {
        throw [ArgumentOutOfRangeException]::new('RetainedFiles', 'RetainedFiles cannot be negative.')
    }

    $snapshot = [Collections.Generic.List[Collections.DictionaryEntry]]::new()
    if ($null -ne $Data) {
        if ($Data -isnot [System.Collections.IDictionary]) {
            throw [ArgumentException]::new('Log data must be a flat dictionary.')
        }

        $enumerator = $null
        try {
            $enumerator = ([System.Collections.IDictionary]$Data).GetEnumerator()
            while ($enumerator.MoveNext()) {
                $entry = $enumerator.Entry
                $null = $snapshot.Add(
                    [Collections.DictionaryEntry]::new($entry.Key, $entry.Value)
                )
            }
        }
        catch {
            throw [ArgumentException]::new('Log data must be a flat dictionary.')
        }
        finally {
            if ($enumerator -is [IDisposable]) {
                $enumerator.Dispose()
            }
        }
    }

    $seenNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $safeData = [ordered]@{}
    foreach ($entry in $snapshot) {
        if ($entry.Key -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$entry.Key)) {
            throw [ArgumentException]::new('Log data field names must be unique nonempty strings.')
        }

        $key = [string]$entry.Key
        if (-not $seenNames.Add($key)) {
            throw [ArgumentException]::new('Log data field names must be unique nonempty strings.')
        }
        if ($key -match '(?i)token|authorization|cookie|email|raw') {
            throw [ArgumentException]::new('Log data contains a prohibited field name.')
        }

        $value = $entry.Value
        if (-not (Test-MonitorLogScalarValue -Value $value)) {
            throw [ArgumentException]::new('Log data values must be flat scalar values.')
        }

        $safeData[$key] = $value
    }

    $payload = [ordered]@{
        Timestamp = $Now.ToUniversalTime().ToString(
            'yyyy-MM-ddTHH:mm:ss.fffffffZ',
            [Globalization.CultureInfo]::InvariantCulture
        )
        Level = $Level
        Event = $Event
        Data = $safeData
    }
    $json = $payload | ConvertTo-Json -Depth 4 -Compress -ErrorAction Stop
    $encoding = [Text.UTF8Encoding]::new($false)
    $lineBytes = $encoding.GetBytes($json + "`n")

    $fullDirectory = [IO.Path]::GetFullPath($LogDirectory)
    $null = [IO.Directory]::CreateDirectory($fullDirectory)
    $currentPath = Join-Path $fullDirectory 'monitor.log'
    $mutex = Enter-MonitorLogMutex -Path $currentPath
    try {
        try {
            $rotate = $false
            if ([IO.File]::Exists($currentPath)) {
                $currentLength = ([IO.FileInfo]$currentPath).Length
                $rotate = $lineBytes.LongLength -gt ($MaximumBytes - $currentLength)
            }

            if ($rotate) {
                Invoke-MonitorLogRotation -LogDirectory $fullDirectory -RetainedFiles $RetainedFiles
                Write-MonitorLogFileAtomic -Path $currentPath -Bytes $lineBytes
                return
            }

            $stream = [IO.FileStream]::new(
                $currentPath,
                [IO.FileMode]::Append,
                [IO.FileAccess]::Write,
                [IO.FileShare]::Read,
                4096,
                [IO.FileOptions]::WriteThrough
            )
            try {
                $stream.Write($lineBytes, 0, $lineBytes.Length)
                $stream.Flush($true)
            }
            finally {
                $stream.Dispose()
            }
        }
        catch {
            throw [IO.IOException]::new('Failed to persist monitor log entry.')
        }
    }
    finally {
        Exit-MonitorLogMutex -Mutex $mutex
    }
}
