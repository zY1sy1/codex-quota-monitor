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

Test-RequiredIcoSizes -Path $fullIconSourcePath
$before = Get-ShortcutState -Path $fullShortcutPath

$installRoot = Join-Path ([IO.Path]::GetFullPath($LocalAppData)) 'CodexQuotaMonitor'
$assetsDirectory = Join-Path $installRoot 'assets'
$installedIconPath = Join-Path $assetsDirectory 'CodexQuotaMonitor.ico'
$transactionId = [Guid]::NewGuid().ToString('N')
$temporaryIconPath = "$installedIconPath.$transactionId.tmp"
$priorIconBackupPath = "$installedIconPath.$transactionId.prior"
$shortcutBackupPath = "$fullShortcutPath.$transactionId.backup"
$hadInstalledIcon = $false
$shortcutBackedUp = $false
$iconBackedUp = $false

try {
    New-Item -ItemType Directory -Path $assetsDirectory -Force | Out-Null
    Copy-Item -LiteralPath $fullIconSourcePath -Destination $temporaryIconPath -Force
    Test-RequiredIcoSizes -Path $temporaryIconPath

    $hadInstalledIcon = Test-Path -LiteralPath $installedIconPath -PathType Leaf
    if ($hadInstalledIcon) {
        Copy-Item -LiteralPath $installedIconPath -Destination $priorIconBackupPath -Force
        $iconBackedUp = $true
    }
    Copy-Item -LiteralPath $temporaryIconPath -Destination $installedIconPath -Force

    Copy-Item -LiteralPath $fullShortcutPath -Destination $shortcutBackupPath -Force
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

    [pscustomobject]@{
        ShortcutPath       = $fullShortcutPath
        InstalledIconPath  = $installedIconPath
        PreviousIconLocation = $before.IconLocation
        IconLocation       = $after.IconLocation
        TargetPath         = $after.TargetPath
        Arguments          = $after.Arguments
        WorkingDirectory   = $after.WorkingDirectory
    }
}
catch {
    $failure = $_
    if ($shortcutBackedUp -and (Test-Path -LiteralPath $shortcutBackupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $shortcutBackupPath -Destination $fullShortcutPath -Force
    }
    if ($iconBackedUp -and (Test-Path -LiteralPath $priorIconBackupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $priorIconBackupPath -Destination $installedIconPath -Force
    }
    elseif (-not $hadInstalledIcon -and (Test-Path -LiteralPath $installedIconPath -PathType Leaf)) {
        Remove-Item -LiteralPath $installedIconPath -Force
    }
    throw $failure
}
finally {
    foreach ($path in $temporaryIconPath, $priorIconBackupPath, $shortcutBackupPath) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}
