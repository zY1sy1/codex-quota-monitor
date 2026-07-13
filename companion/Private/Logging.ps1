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

function Invoke-MonitorLogRotation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$LogDirectory,

        [Parameter(Mandatory, Position = 1)]
        [int]$RetainedFiles
    )

    $currentPath = Join-Path $LogDirectory 'monitor.log'
    if ($RetainedFiles -eq 0) {
        if ([IO.File]::Exists($currentPath)) {
            [IO.File]::Delete($currentPath)
        }

        return
    }

    $oldestPath = Join-Path $LogDirectory "monitor.$RetainedFiles.log"
    if ([IO.File]::Exists($oldestPath)) {
        [IO.File]::Delete($oldestPath)
    }

    for ($index = $RetainedFiles - 1; $index -ge 1; $index--) {
        $source = Join-Path $LogDirectory "monitor.$index.log"
        if (-not [IO.File]::Exists($source)) {
            continue
        }

        $destination = Join-Path $LogDirectory "monitor.$($index + 1).log"
        if ([IO.File]::Exists($destination)) {
            [IO.File]::Delete($destination)
        }
        [IO.File]::Move($source, $destination)
    }

    if ([IO.File]::Exists($currentPath)) {
        $firstRotatedPath = Join-Path $LogDirectory 'monitor.1.log'
        if ([IO.File]::Exists($firstRotatedPath)) {
            [IO.File]::Delete($firstRotatedPath)
        }
        [IO.File]::Move($currentPath, $firstRotatedPath)
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
    if ([IO.File]::Exists($currentPath)) {
        $currentLength = ([IO.FileInfo]$currentPath).Length
        if ($lineBytes.LongLength -gt ($MaximumBytes - $currentLength)) {
            Invoke-MonitorLogRotation -LogDirectory $fullDirectory -RetainedFiles $RetainedFiles
        }
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
