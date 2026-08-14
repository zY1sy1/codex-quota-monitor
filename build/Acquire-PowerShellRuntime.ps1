#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$LockPath = (Join-Path $PSScriptRoot '..\installer\runtime-lock.json'),
    [string]$CacheRoot = (Join-Path $PSScriptRoot '..\outputs\cache\powershell'),
    [Parameter(Mandatory)][string]$Destination
)

$ErrorActionPreference = 'Stop'

$lockFullPath = [IO.Path]::GetFullPath($LockPath)
$cacheFullPath = [IO.Path]::GetFullPath($CacheRoot)
$destinationFullPath = [IO.Path]::GetFullPath($Destination)
if (-not (Test-Path -LiteralPath $lockFullPath -PathType Leaf)) {
    throw [IO.FileNotFoundException]::new('The PowerShell runtime lock file is missing.')
}

$lock = Get-Content -LiteralPath $lockFullPath -Raw | ConvertFrom-Json
if ($lock.SchemaVersion -ne 1 -or
    [string]$lock.Version -notmatch '^\d+\.\d+\.\d+$' -or
    [string]$lock.Architecture -cne 'x64' -or
    [string]$lock.ArchiveName -notmatch '^PowerShell-[0-9.]+-win-x64\.zip$' -or
    [string]$lock.AssetUrl -notmatch '^https://github\.com/PowerShell/PowerShell/releases/download/' -or
    [string]$lock.ArchiveSha256 -notmatch '^[0-9A-F]{64}$' -or
    [string]::IsNullOrWhiteSpace([string]$lock.LicenseFile)) {
    throw [IO.InvalidDataException]::new('The PowerShell runtime lock file is invalid.')
}

$null = New-Item -ItemType Directory -Path $cacheFullPath -Force
$archivePath = Join-Path $cacheFullPath ([string]$lock.ArchiveName)
$archiveValid = $false
if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
    $archiveValid = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ceq
        [string]$lock.ArchiveSha256
}
if (-not $archiveValid) {
    $downloadPath = $archivePath + '.download'
    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $curl) {
        throw [PlatformNotSupportedException]::new('curl.exe is required to acquire PowerShell.')
    }
    & $curl.Source `
        --location `
        --fail `
        --silent `
        --show-error `
        --retry 3 `
        --retry-delay 2 `
        --connect-timeout 30 `
        --max-time 900 `
        --continue-at - `
        --output $downloadPath `
        ([string]$lock.AssetUrl)
    if ($LASTEXITCODE -ne 0) {
        throw [IO.IOException]::new('The PowerShell archive download failed.')
    }
    $downloadHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
    if ($downloadHash -cne [string]$lock.ArchiveSha256) {
        Remove-Item -LiteralPath $downloadPath -Force
        throw [IO.InvalidDataException]::new('The downloaded PowerShell archive hash is invalid.')
    }
    Move-Item -LiteralPath $downloadPath -Destination $archivePath -Force
}

if (Test-Path -LiteralPath $destinationFullPath) {
    Remove-Item -LiteralPath $destinationFullPath -Recurse -Force
}
$null = New-Item -ItemType Directory -Path $destinationFullPath -Force
Expand-Archive -LiteralPath $archivePath -DestinationPath $destinationFullPath -Force

$pwshPath = Join-Path $destinationFullPath 'pwsh.exe'
$licensePath = Join-Path $destinationFullPath ([string]$lock.LicenseFile)
if (-not (Test-Path -LiteralPath $pwshPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
    throw [IO.InvalidDataException]::new('The extracted PowerShell runtime is incomplete.')
}

$probeText = & $pwshPath -NoLogo -NoProfile -NonInteractive -Command `
    '[pscustomobject]@{Version=$PSVersionTable.PSVersion.ToString();Architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()} | ConvertTo-Json -Compress'
if ($LASTEXITCODE -ne 0) {
    throw [IO.InvalidDataException]::new('The extracted PowerShell runtime could not be executed.')
}
$probe = $probeText | ConvertFrom-Json
if ([string]$probe.Version -cne [string]$lock.Version -or
    [string]$probe.Architecture -cne 'X64') {
    throw [IO.InvalidDataException]::new('The extracted PowerShell runtime identity is invalid.')
}

[pscustomobject][ordered]@{
    Version = [string]$lock.Version
    Architecture = [string]$lock.Architecture
    ArchivePath = $archivePath
    ArchiveSha256 = [string]$lock.ArchiveSha256
    RuntimeRoot = $destinationFullPath
    PwshPath = $pwshPath
    LicensePath = $licensePath
}
