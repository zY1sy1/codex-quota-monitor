#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex 额度监控.lnk'),
    [string]$IconSourcePath = (Join-Path $PSScriptRoot '..\assets\codex-quota-monitor-white-blue.ico'),
    [string]$LocalAppData = $env:LOCALAPPDATA,
    [Parameter(DontShow)]
    [AllowNull()]
    [scriptblock]$FaultInjector
)

$ErrorActionPreference = 'Stop'

$script:RequiredIcoSizes = @(16, 24, 32, 48, 64, 128, 256)
Add-Type -AssemblyName PresentationCore

function New-InvalidIcoException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()][Exception]$InnerException
    )

    $fullMessage = "The invalid ICO file: $Message"
    if ($null -eq $InnerException) {
        return [IO.InvalidDataException]::new($fullMessage)
    }
    return [IO.InvalidDataException]::new($fullMessage, $InnerException)
}

function Get-UInt32BigEndian {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$Offset
    )

    return [uint32](
        ([uint32]$Bytes[$Offset] -shl 24) -bor
        ([uint32]$Bytes[$Offset + 1] -shl 16) -bor
        ([uint32]$Bytes[$Offset + 2] -shl 8) -bor
        [uint32]$Bytes[$Offset + 3]
    )
}

function Get-PngCrc32 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][int]$Count
    )

    [uint32]$crc = [uint32]::MaxValue
    [uint32]$polynomial = [Convert]::ToUInt32('EDB88320', 16)
    for ($byteIndex = 0; $byteIndex -lt $Count; $byteIndex++) {
        $crc = [uint32]($crc -bxor [uint32]$Bytes[$Offset + $byteIndex])
        for ($bitIndex = 0; $bitIndex -lt 8; $bitIndex++) {
            if (($crc -band 1) -ne 0) {
                $crc = [uint32](($crc -shr 1) -bxor $polynomial)
            }
            else {
                $crc = [uint32]($crc -shr 1)
            }
        }
    }
    return [uint32]($crc -bxor [uint32]::MaxValue)
}

function Test-PngChunkStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$FileBytes,
        [Parameter(Mandatory)][int]$PayloadOffset,
        [Parameter(Mandatory)][int]$PayloadLength
    )

    [uint64]$payloadLimit = [uint64]$PayloadLength
    [uint64]$cursor = 8
    $chunkIndex = 0
    $sawIdat = $false
    $sawIend = $false

    while ($cursor -lt $payloadLimit) {
        if (($payloadLimit - $cursor) -lt 12) {
            throw (New-InvalidIcoException -Message 'a PNG chunk header, data, or CRC is truncated.' -InnerException $null)
        }

        $chunkHeaderOffset = [int]([uint64]$PayloadOffset + $cursor)
        [uint64]$chunkLength = Get-UInt32BigEndian -Bytes $FileBytes -Offset $chunkHeaderOffset
        [uint64]$typeOffset = $cursor + 4
        [uint64]$dataOffset = $cursor + 8
        [uint64]$crcOffset = $dataOffset + $chunkLength
        [uint64]$chunkEnd = $crcOffset + 4
        if ($crcOffset -lt $dataOffset -or $chunkEnd -lt $crcOffset -or $chunkEnd -gt $payloadLimit) {
            throw (New-InvalidIcoException -Message 'a PNG chunk declares an impossible or truncated length.' -InnerException $null)
        }

        $absoluteTypeOffset = [int]([uint64]$PayloadOffset + $typeOffset)
        $absoluteCrcOffset = [int]([uint64]$PayloadOffset + $crcOffset)
        $chunkType = [Text.Encoding]::ASCII.GetString($FileBytes, $absoluteTypeOffset, 4)
        if ($chunkIndex -eq 0 -and ($chunkType -cne 'IHDR' -or $chunkLength -ne 13)) {
            throw (New-InvalidIcoException -Message 'the first PNG chunk must be a 13-byte IHDR.' -InnerException $null)
        }
        if ($chunkIndex -gt 0 -and $chunkType -ceq 'IHDR') {
            throw (New-InvalidIcoException -Message 'a PNG payload contains more than one IHDR.' -InnerException $null)
        }

        $crcInputLength = [uint64]4 + $chunkLength
        if ($crcInputLength -gt [int]::MaxValue) {
            throw (New-InvalidIcoException -Message 'a PNG chunk is too large to validate safely.' -InnerException $null)
        }
        $expectedCrc = Get-UInt32BigEndian -Bytes $FileBytes -Offset $absoluteCrcOffset
        $actualCrc = Get-PngCrc32 `
            -Bytes $FileBytes `
            -Offset $absoluteTypeOffset `
            -Count ([int]$crcInputLength)
        if ($actualCrc -ne $expectedCrc) {
            throw (New-InvalidIcoException -Message "PNG chunk '$chunkType' has an invalid CRC." -InnerException $null)
        }

        if ($chunkType -ceq 'IDAT') {
            $sawIdat = $true
        }
        elseif ($chunkType -ceq 'IEND') {
            if ($chunkLength -ne 0) {
                throw (New-InvalidIcoException -Message 'the PNG IEND chunk must have zero length.' -InnerException $null)
            }
            $sawIend = $true
            if ($chunkEnd -ne $payloadLimit) {
                throw (New-InvalidIcoException -Message 'the PNG IEND chunk must end exactly at the payload boundary.' -InnerException $null)
            }
        }

        $cursor = $chunkEnd
        $chunkIndex++
        if ($sawIend) {
            break
        }
    }

    if (-not $sawIdat) {
        throw (New-InvalidIcoException -Message 'a PNG payload contains no IDAT chunk.' -InnerException $null)
    }
    if (-not $sawIend -or $cursor -ne $payloadLimit) {
        throw (New-InvalidIcoException -Message 'a PNG payload has no complete terminal IEND chunk.' -InnerException $null)
    }
}

function Test-PngIconPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$FileBytes,
        [Parameter(Mandatory)][int]$PayloadOffset,
        [Parameter(Mandatory)][int]$PayloadLength,
        [Parameter(Mandatory)][int]$ExpectedSize
    )

    $pngSignature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
    if ($PayloadLength -lt 33) {
        throw (New-InvalidIcoException -Message 'a PNG payload does not contain a complete IHDR.' -InnerException $null)
    }
    for ($index = 0; $index -lt $pngSignature.Count; $index++) {
        if ($FileBytes[$PayloadOffset + $index] -ne $pngSignature[$index]) {
            throw (New-InvalidIcoException -Message 'an image payload does not have a PNG signature.' -InnerException $null)
        }
    }

    Test-PngChunkStream `
        -FileBytes $FileBytes `
        -PayloadOffset $PayloadOffset `
        -PayloadLength $PayloadLength

    $ihdrLength = Get-UInt32BigEndian -Bytes $FileBytes -Offset ($PayloadOffset + 8)
    $ihdrType = [Text.Encoding]::ASCII.GetString($FileBytes, $PayloadOffset + 12, 4)
    if ($ihdrLength -ne 13 -or $ihdrType -cne 'IHDR') {
        throw (New-InvalidIcoException -Message 'a PNG payload does not start with a complete IHDR.' -InnerException $null)
    }

    $ihdrWidth = Get-UInt32BigEndian -Bytes $FileBytes -Offset ($PayloadOffset + 16)
    $ihdrHeight = Get-UInt32BigEndian -Bytes $FileBytes -Offset ($PayloadOffset + 20)
    if ($ihdrWidth -ne $ExpectedSize -or $ihdrHeight -ne $ExpectedSize) {
        throw (New-InvalidIcoException -Message 'PNG IHDR dimensions do not match the ICO directory entry.' -InnerException $null)
    }
    if ($FileBytes[$PayloadOffset + 24] -ne 8 -or $FileBytes[$PayloadOffset + 25] -ne 6) {
        throw (New-InvalidIcoException -Message 'PNG entries must use 8-bit RGBA pixels.' -InnerException $null)
    }
    if ($FileBytes[$PayloadOffset + 26] -ne 0 -or
        $FileBytes[$PayloadOffset + 27] -ne 0 -or
        $FileBytes[$PayloadOffset + 28] -notin 0, 1) {
        throw (New-InvalidIcoException -Message 'PNG compression, filter, or interlace values are invalid.' -InnerException $null)
    }

    $payload = [byte[]]::new($PayloadLength)
    [Array]::Copy($FileBytes, $PayloadOffset, $payload, 0, $PayloadLength)
    $stream = [IO.MemoryStream]::new($payload, $false)
    try {
        try {
            $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create(
                $stream,
                [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            )
            if ($decoder.Frames.Count -ne 1) {
                throw [IO.InvalidDataException]::new('The PNG payload did not decode to exactly one frame.')
            }
            $frame = $decoder.Frames[0]
            if ($frame.PixelWidth -ne $ExpectedSize -or $frame.PixelHeight -ne $ExpectedSize) {
                throw [IO.InvalidDataException]::new('Decoded PNG dimensions do not match the ICO directory entry.')
            }

            $bitsPerPixel = [int]$frame.Format.BitsPerPixel
            if ($bitsPerPixel -le 0) {
                throw [IO.InvalidDataException]::new('The decoded PNG pixel format is invalid.')
            }
            $stride = [int][Math]::Ceiling(($frame.PixelWidth * $bitsPerPixel) / 8.0)
            $decodedPixels = [byte[]]::new($stride * $frame.PixelHeight)
            $frame.CopyPixels($decodedPixels, $stride, 0)
        }
        catch {
            throw (New-InvalidIcoException -Message 'a PNG payload could not be fully decoded.' -InnerException $_.Exception)
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-IcoSizes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 6) {
        throw (New-InvalidIcoException -Message 'the header is incomplete.' -InnerException $null)
    }

    $reserved = [BitConverter]::ToUInt16($bytes, 0)
    $type = [BitConverter]::ToUInt16($bytes, 2)
    $entryCount = [BitConverter]::ToUInt16($bytes, 4)
    if ($reserved -ne 0 -or $type -ne 1) {
        throw (New-InvalidIcoException -Message 'the header signature is not valid.' -InnerException $null)
    }
    if ($entryCount -ne $script:RequiredIcoSizes.Count) {
        throw (New-InvalidIcoException -Message 'exactly seven image entries are required.' -InnerException $null)
    }

    $directoryLength = 6 + (16 * [int]$entryCount)
    if ($directoryLength -gt $bytes.Length) {
        throw (New-InvalidIcoException -Message 'the image directory is incomplete.' -InnerException $null)
    }

    $sizes = foreach ($entryIndex in 0..($entryCount - 1)) {
        $entryOffset = 6 + (16 * $entryIndex)
        $width = if ($bytes[$entryOffset] -eq 0) { 256 } else { [int]$bytes[$entryOffset] }
        $height = if ($bytes[$entryOffset + 1] -eq 0) { 256 } else { [int]$bytes[$entryOffset + 1] }
        $payloadLength = [BitConverter]::ToUInt32($bytes, $entryOffset + 8)
        $payloadOffset = [BitConverter]::ToUInt32($bytes, $entryOffset + 12)
        $payloadEnd = [UInt64]$payloadOffset + [UInt64]$payloadLength

        if ($width -ne $height) {
            throw (New-InvalidIcoException -Message 'an image directory entry is not square.' -InnerException $null)
        }
        if ($payloadLength -eq 0) {
            throw (New-InvalidIcoException -Message 'an image payload is empty.' -InnerException $null)
        }
        if ($payloadOffset -lt $directoryLength -or $payloadEnd -gt [UInt64]$bytes.Length) {
            throw (New-InvalidIcoException -Message 'an image payload lies outside the file.' -InnerException $null)
        }

        Test-PngIconPayload `
            -FileBytes $bytes `
            -PayloadOffset ([int]$payloadOffset) `
            -PayloadLength ([int]$payloadLength) `
            -ExpectedSize $width
        $width
    }

    return @($sizes | Sort-Object)
}

function Get-ShortcutState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        return [pscustomobject]@{
            TargetPath       = [string]$shortcut.TargetPath
            Arguments        = [string]$shortcut.Arguments
            WorkingDirectory = [string]$shortcut.WorkingDirectory
            Description      = [string]$shortcut.Description
            IconLocation     = [string]$shortcut.IconLocation
            WindowStyle      = [int]$shortcut.WindowStyle
            Hotkey           = [string]$shortcut.Hotkey
        }
    }
    finally {
        if ($null -ne $shortcut) {
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
        }
        if ($null -ne $shell) {
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
        }
    }
}

function Set-ShortcutIconLocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$IconLocation
    )

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.IconLocation = $IconLocation
        $shortcut.Save()
    }
    finally {
        if ($null -ne $shortcut) {
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
        }
        if ($null -ne $shell) {
            [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
        }
    }
}

function Test-RequiredIcoSizes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $sizes = @(Get-IcoSizes -Path $Path)
    if ($sizes.Count -ne $script:RequiredIcoSizes.Count) {
        throw (New-InvalidIcoException -Message 'the image entry count is not exactly seven.' -InnerException $null)
    }
    for ($index = 0; $index -lt $script:RequiredIcoSizes.Count; $index++) {
        if ($sizes[$index] -ne $script:RequiredIcoSizes[$index]) {
            throw (New-InvalidIcoException `
                -Message "the exact required sizes are $($script:RequiredIcoSizes -join ', ')." `
                -InnerException $null)
        }
    }
}

function Invoke-ShortcutIconFault {
    [CmdletBinding()]
    param(
        [AllowNull()][scriptblock]$Injector,
        [Parameter(Mandatory)]
        [ValidateSet(
            'AfterIconReplacement',
            'AfterShortcutUpdate',
            'BeforeShortcutRollback',
            'BeforeIconRollback',
            'BeforeCleanup'
        )]
        [string]$Stage,
        [Parameter(Mandatory)]$Context
    )

    if ($null -ne $Injector) {
        & $Injector $Stage $Context | Out-Null
    }
}

function Get-FileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Test-IsReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [IO.FileSystemInfo]$Item
    )

    return ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

function Assert-SafeExistingDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return
    }
    if (-not $item.PSIsContainer -or (Test-IsReparsePoint -Item $item)) {
        throw [IO.IOException]::new("The icon installation directory collides with a file or reparse point: $Path")
    }
}

function Remove-KnownTransactionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return
    }
    if ($item.PSIsContainer -or (Test-IsReparsePoint -Item $item)) {
        throw [IO.IOException]::new("Refusing to remove an unsafe transaction artifact: $Path")
    }
    Remove-Item -LiteralPath $Path -Force
}

$fullShortcutPath = [IO.Path]::GetFullPath($ShortcutPath)
$fullIconSourcePath = [IO.Path]::GetFullPath($IconSourcePath)
if (-not $fullShortcutPath.EndsWith('.lnk', [StringComparison]::OrdinalIgnoreCase) -or
    -not (Test-Path -LiteralPath $fullShortcutPath -PathType Leaf)) {
    throw [IO.FileNotFoundException]::new('The shortcut must be an existing .lnk file.', $fullShortcutPath)
}
if (-not (Test-Path -LiteralPath $fullIconSourcePath -PathType Leaf)) {
    throw [IO.FileNotFoundException]::new('The source icon does not exist.', $fullIconSourcePath)
}
if ([string]::IsNullOrWhiteSpace($LocalAppData)) {
    throw [ArgumentException]::new('LocalAppData must not be empty.', 'LocalAppData')
}

$shortcutItem = Get-Item -LiteralPath $fullShortcutPath -Force
if (Test-IsReparsePoint -Item $shortcutItem) {
    throw [IO.IOException]::new('The shortcut mutation target must not be a reparse point.')
}

$fullLocalAppData = [IO.Path]::GetFullPath($LocalAppData)
$installRoot = Join-Path $fullLocalAppData 'CodexQuotaMonitor'
$assetsDirectory = Join-Path $installRoot 'assets'
$installedIconPath = Join-Path $assetsDirectory 'CodexQuotaMonitor.ico'

$initialStableItem = Get-Item -LiteralPath $installedIconPath -Force -ErrorAction SilentlyContinue
$initialStableState = if ($null -eq $initialStableItem) {
    'Absent'
}
elseif ($initialStableItem.PSIsContainer -or (Test-IsReparsePoint -Item $initialStableItem)) {
    throw [IO.IOException]::new('The installed icon destination collides with a directory or reparse point.')
}
else {
    'ExistingLeaf'
}
$initialStableHash = if ($initialStableState -eq 'ExistingLeaf') {
    Get-FileSha256 -Path $installedIconPath
}
else {
    $null
}

Assert-SafeExistingDirectory -Path $fullLocalAppData
Assert-SafeExistingDirectory -Path $installRoot
Assert-SafeExistingDirectory -Path $assetsDirectory
Test-RequiredIcoSizes -Path $fullIconSourcePath
$before = Get-ShortcutState -Path $fullShortcutPath
$shortcutOriginalHash = Get-FileSha256 -Path $fullShortcutPath

$transactionId = [Guid]::NewGuid().ToString('N')
$temporaryIconPath = "$installedIconPath.$transactionId.tmp"
$priorIconBackupPath = "$installedIconPath.$transactionId.prior"
$iconRestorePath = "$installedIconPath.$transactionId.restore"
$displacedIconPath = "$installedIconPath.$transactionId.displaced"
$shortcutBackupPath = "$fullShortcutPath.$transactionId.backup"
$faultContext = [pscustomobject]@{
    ShortcutPath = $fullShortcutPath
    InstalledIconPath = $installedIconPath
    TemporaryIconPath = $temporaryIconPath
    PriorIconBackupPath = $priorIconBackupPath
    IconRestorePath = $iconRestorePath
    DisplacedIconPath = $displacedIconPath
    ShortcutBackupPath = $shortcutBackupPath
    CleanupArtifactPath = $null
}
$temporaryIconOwned = $false
$priorIconBackupOwned = $false
$iconRestoreOwned = $false
$displacedIconOwned = $false
$shortcutBackupOwned = $false
$stableIconWritten = $false
$shortcutBackedUp = $false
$preservePriorIconBackup = $false
$preserveShortcutBackup = $false
$operationFailure = $null
$rollbackFailures = [Collections.Generic.List[Exception]]::new()
$result = $null

try {
    New-Item -ItemType Directory -Path $assetsDirectory -Force | Out-Null
    Assert-SafeExistingDirectory -Path $assetsDirectory

    $temporaryIconOwned = $true
    [IO.File]::Copy($fullIconSourcePath, $temporaryIconPath, $false)
    Test-RequiredIcoSizes -Path $temporaryIconPath
    $stagedIconHash = Get-FileSha256 -Path $temporaryIconPath

    if ($initialStableState -eq 'ExistingLeaf') {
        $priorIconBackupOwned = $true
        [IO.File]::Replace($temporaryIconPath, $installedIconPath, $priorIconBackupPath, $true)
    }
    else {
        [IO.File]::Move($temporaryIconPath, $installedIconPath)
    }
    $temporaryIconOwned = $false
    $stableIconWritten = $true

    if ($initialStableState -eq 'ExistingLeaf') {
        $backupItem = Get-Item -LiteralPath $priorIconBackupPath -Force -ErrorAction SilentlyContinue
        if ($null -eq $backupItem -or $backupItem.PSIsContainer -or
            (Test-IsReparsePoint -Item $backupItem) -or
            (Get-FileSha256 -Path $priorIconBackupPath) -cne $initialStableHash) {
            throw [IO.InvalidDataException]::new('The prior icon backup does not match the original icon.')
        }
    }

    if (-not (Test-Path -LiteralPath $installedIconPath -PathType Leaf)) {
        throw [IO.InvalidDataException]::new('The installed icon is not a regular file after replacement.')
    }
    $installedItem = Get-Item -LiteralPath $installedIconPath -Force
    if (Test-IsReparsePoint -Item $installedItem) {
        throw [IO.InvalidDataException]::new('The installed icon became a reparse point after replacement.')
    }
    Test-RequiredIcoSizes -Path $installedIconPath
    if ((Get-FileSha256 -Path $installedIconPath) -cne $stagedIconHash) {
        throw [IO.InvalidDataException]::new('The installed icon bytes do not match the staged icon.')
    }
    Invoke-ShortcutIconFault `
        -Injector $FaultInjector `
        -Stage 'AfterIconReplacement' `
        -Context $faultContext

    $shortcutBackupOwned = $true
    [IO.File]::Copy($fullShortcutPath, $shortcutBackupPath, $false)
    if ((Get-FileSha256 -Path $shortcutBackupPath) -cne $shortcutOriginalHash) {
        throw [IO.InvalidDataException]::new('The shortcut rollback backup does not match the original shortcut.')
    }
    $shortcutBackedUp = $true
    $newIconLocation = "$installedIconPath,0"
    Set-ShortcutIconLocation -Path $fullShortcutPath -IconLocation $newIconLocation
    Invoke-ShortcutIconFault `
        -Injector $FaultInjector `
        -Stage 'AfterShortcutUpdate' `
        -Context $faultContext

    $after = Get-ShortcutState -Path $fullShortcutPath
    foreach ($property in 'TargetPath', 'Arguments', 'WorkingDirectory', 'Description', 'WindowStyle', 'Hotkey') {
        if ($after.$property -cne $before.$property) {
            throw [IO.InvalidDataException]::new("Shortcut property '$property' changed while updating its icon.")
        }
    }
    if ($after.IconLocation -cne $newIconLocation) {
        throw [IO.InvalidDataException]::new('Shortcut IconLocation was not saved exactly as requested.')
    }

    $result = [pscustomobject]@{
        ShortcutPath         = $fullShortcutPath
        InstalledIconPath    = $installedIconPath
        PreviousIconLocation = $before.IconLocation
        IconLocation         = $after.IconLocation
        TargetPath           = $after.TargetPath
        Arguments            = $after.Arguments
        WorkingDirectory     = $after.WorkingDirectory
    }
}
catch {
    $operationFailure = $_.Exception

    if ($shortcutBackedUp) {
        try {
            Invoke-ShortcutIconFault `
                -Injector $FaultInjector `
                -Stage 'BeforeShortcutRollback' `
                -Context $faultContext
            if (-not (Test-Path -LiteralPath $shortcutBackupPath -PathType Leaf)) {
                throw [IO.FileNotFoundException]::new('The shortcut rollback backup is missing.', $shortcutBackupPath)
            }
            $shortcutBackupItem = Get-Item -LiteralPath $shortcutBackupPath -Force
            if (Test-IsReparsePoint -Item $shortcutBackupItem) {
                throw [IO.IOException]::new('The shortcut rollback backup is a reparse point.')
            }
            [IO.File]::Copy($shortcutBackupPath, $fullShortcutPath, $true)
            if ((Get-FileSha256 -Path $fullShortcutPath) -cne (Get-FileSha256 -Path $shortcutBackupPath)) {
                throw [IO.InvalidDataException]::new('The restored shortcut does not match its rollback backup.')
            }
        }
        catch {
            $preserveShortcutBackup = $true
            $rollbackFailures.Add(
                [IO.IOException]::new('Shortcut rollback failed.', $_.Exception)
            )
        }
    }

    if ($stableIconWritten) {
        try {
            Invoke-ShortcutIconFault `
                -Injector $FaultInjector `
                -Stage 'BeforeIconRollback' `
                -Context $faultContext
            if ($initialStableState -eq 'ExistingLeaf') {
                if (-not (Test-Path -LiteralPath $priorIconBackupPath -PathType Leaf)) {
                    throw [IO.FileNotFoundException]::new('The icon rollback backup is missing.', $priorIconBackupPath)
                }
                $priorBackupItem = Get-Item -LiteralPath $priorIconBackupPath -Force
                if (Test-IsReparsePoint -Item $priorBackupItem) {
                    throw [IO.IOException]::new('The icon rollback backup is a reparse point.')
                }

                $iconRestoreOwned = $true
                [IO.File]::Copy($priorIconBackupPath, $iconRestorePath, $false)
                $currentStableItem = Get-Item -LiteralPath $installedIconPath -Force -ErrorAction SilentlyContinue
                if ($null -ne $currentStableItem -and -not $currentStableItem.PSIsContainer -and
                    -not (Test-IsReparsePoint -Item $currentStableItem)) {
                    $displacedIconOwned = $true
                    [IO.File]::Replace(
                        $iconRestorePath,
                        $installedIconPath,
                        $displacedIconPath,
                        $true
                    )
                }
                elseif ($null -eq $currentStableItem) {
                    [IO.File]::Move($iconRestorePath, $installedIconPath)
                }
                else {
                    throw [IO.IOException]::new('The installed icon path is unsafe during rollback.')
                }
                $iconRestoreOwned = $false
                if ((Get-FileSha256 -Path $installedIconPath) -cne $initialStableHash) {
                    throw [IO.InvalidDataException]::new('The restored icon does not match the original icon.')
                }
            }
            else {
                $currentStableItem = Get-Item -LiteralPath $installedIconPath -Force -ErrorAction SilentlyContinue
                if ($null -ne $currentStableItem) {
                    if ($currentStableItem.PSIsContainer -or
                        (Test-IsReparsePoint -Item $currentStableItem) -or
                        (Get-FileSha256 -Path $installedIconPath) -cne $stagedIconHash) {
                        throw [IO.IOException]::new('The newly installed icon path is unsafe during rollback.')
                    }
                    Remove-Item -LiteralPath $installedIconPath -Force
                }
            }
        }
        catch {
            if ($initialStableState -eq 'ExistingLeaf') {
                $preservePriorIconBackup = $true
            }
            $rollbackFailures.Add(
                [IO.IOException]::new('Installed icon rollback failed.', $_.Exception)
            )
        }
    }
}
finally {
    $cleanupPaths = @(
        [pscustomobject]@{ Path = $temporaryIconPath; Remove = $temporaryIconOwned }
        [pscustomobject]@{ Path = $iconRestorePath; Remove = $iconRestoreOwned }
        [pscustomobject]@{ Path = $displacedIconPath; Remove = $displacedIconOwned }
        [pscustomobject]@{
            Path = $priorIconBackupPath
            Remove = $priorIconBackupOwned -and -not $preservePriorIconBackup
        }
        [pscustomobject]@{
            Path = $shortcutBackupPath
            Remove = $shortcutBackupOwned -and -not $preserveShortcutBackup
        }
    )
    foreach ($artifact in $cleanupPaths) {
        if ($artifact.Remove) {
            try {
                $faultContext.CleanupArtifactPath = $artifact.Path
                Invoke-ShortcutIconFault `
                    -Injector $FaultInjector `
                    -Stage 'BeforeCleanup' `
                    -Context $faultContext
                Remove-KnownTransactionFile -Path $artifact.Path
            }
            catch {
                $cleanupFailure = [IO.IOException]::new(
                    "Transaction artifact cleanup failed: $($artifact.Path)",
                    $_.Exception
                )
                if ($null -eq $operationFailure) {
                    $operationFailure = $cleanupFailure
                }
                else {
                    $rollbackFailures.Add($cleanupFailure)
                }
            }
        }
    }
}

if ($null -ne $operationFailure) {
    if ($rollbackFailures.Count -gt 0) {
        $allFailures = [Collections.Generic.List[Exception]]::new()
        $allFailures.Add($operationFailure)
        foreach ($rollbackFailure in $rollbackFailures) {
            $allFailures.Add($rollbackFailure)
        }
        throw [AggregateException]::new(
            'Shortcut icon update failed and one or more rollback or cleanup operations also failed.',
            $allFailures
        )
    }
    throw $operationFailure
}

$result
