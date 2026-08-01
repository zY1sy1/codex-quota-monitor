#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex 额度监控.lnk'),
    [string]$IconSourcePath = (Join-Path $PSScriptRoot '..\assets\codex-quota-monitor-white-blue.ico'),
    [string]$LocalAppData = $env:LOCALAPPDATA
)

$ErrorActionPreference = 'Stop'

$script:RequiredIcoSizes = @(16, 24, 32, 48, 64, 128, 256)

function Get-IcoSizes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 6) {
        throw [IO.InvalidDataException]::new('The ICO file is too short to contain a header.')
    }

    $reserved = [BitConverter]::ToUInt16($bytes, 0)
    $type = [BitConverter]::ToUInt16($bytes, 2)
    $entryCount = [BitConverter]::ToUInt16($bytes, 4)
    if ($reserved -ne 0 -or $type -ne 1) {
        throw [IO.InvalidDataException]::new('The source icon is not a valid ICO file.')
    }
    if ($entryCount -eq 0) {
        throw [IO.InvalidDataException]::new('The ICO file contains no image entries.')
    }

    $directoryLength = 6 + (16 * [int]$entryCount)
    if ($directoryLength -gt $bytes.Length) {
        throw [IO.InvalidDataException]::new('The ICO file directory is incomplete.')
    }

    $sizes = foreach ($entryIndex in 0..($entryCount - 1)) {
        $entryOffset = 6 + (16 * $entryIndex)
        $width = if ($bytes[$entryOffset] -eq 0) { 256 } else { [int]$bytes[$entryOffset] }
        $height = if ($bytes[$entryOffset + 1] -eq 0) { 256 } else { [int]$bytes[$entryOffset + 1] }
        $payloadLength = [BitConverter]::ToUInt32($bytes, $entryOffset + 8)
        $payloadOffset = [BitConverter]::ToUInt32($bytes, $entryOffset + 12)
        $payloadEnd = [UInt64]$payloadOffset + [UInt64]$payloadLength

        if ($width -ne $height) {
            throw [IO.InvalidDataException]::new('The ICO file contains a non-square image entry.')
        }
        if ($payloadLength -eq 0) {
            throw [IO.InvalidDataException]::new('The ICO file contains an empty image entry.')
        }
        if ($payloadOffset -lt $directoryLength -or $payloadEnd -gt [UInt64]$bytes.Length) {
            throw [IO.InvalidDataException]::new('The ICO file contains an image entry outside the file.')
        }

        $width
    }

    return @($sizes | Sort-Object -Unique)
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
    if ($sizes.Count -ne $script:RequiredIcoSizes.Count -or
        (Compare-Object -ReferenceObject $script:RequiredIcoSizes -DifferenceObject $sizes)) {
        throw [IO.InvalidDataException]::new(
            "The source icon must contain exactly these sizes: $($script:RequiredIcoSizes -join ', ')."
        )
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
$shortcutBackupPath = "$fullShortcutPath.$transactionId.backup"
$temporaryIconOwned = $false
$priorIconBackupOwned = $false
$iconRestoreOwned = $false
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

    $shortcutBackupOwned = $true
    [IO.File]::Copy($fullShortcutPath, $shortcutBackupPath, $false)
    if ((Get-FileSha256 -Path $shortcutBackupPath) -cne $shortcutOriginalHash) {
        throw [IO.InvalidDataException]::new('The shortcut rollback backup does not match the original shortcut.')
    }
    $shortcutBackedUp = $true
    $newIconLocation = "$installedIconPath,0"
    Set-ShortcutIconLocation -Path $fullShortcutPath -IconLocation $newIconLocation

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
                    [IO.File]::Replace($iconRestorePath, $installedIconPath, $null, $true)
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
