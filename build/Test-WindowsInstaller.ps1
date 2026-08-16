#requires -Version 7.4
[CmdletBinding()]
param([AllowNull()][string]$SetupPath)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$requiredSources = @(
    'installer\CodexQuotaMonitor.iss'
    'installer\runtime-lock.json'
    'installer\scripts\Install-Package.ps1'
    'installer\scripts\Stop-Package.ps1'
    'installer\scripts\Prepare-Uninstall.ps1'
    'build\Acquire-PowerShellRuntime.ps1'
    'build\New-InstallerPayload.ps1'
    'build\Build-WindowsInstaller.ps1'
)
foreach ($relativePath in $requiredSources) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $relativePath) -PathType Leaf)) {
        throw [IO.InvalidDataException]::new('The Windows installer source set is incomplete.')
    }
}

$lock = Get-Content -LiteralPath (Join-Path $repoRoot 'installer\runtime-lock.json') -Raw |
    ConvertFrom-Json
if ([string]$lock.Version -cne '7.6.4' -or
    [string]$lock.Architecture -cne 'x64' -or
    [string]$lock.ArchiveSha256 -notmatch '^[0-9A-F]{64}$') {
    throw [IO.InvalidDataException]::new('The private PowerShell runtime lock is invalid.')
}

$iss = Get-Content -LiteralPath (Join-Path $repoRoot 'installer\CodexQuotaMonitor.iss') -Raw
foreach ($pattern in @(
        'AppId=\{\{7B0B5FCB-62F5-4D3C-AF28-0EE1CA930D47\}',
        'PrivilegesRequired=lowest',
        'PrivilegesRequiredOverridesAllowed=\s*(?:\r?\n)',
        'ArchitecturesAllowed=x64compatible',
        'PrepareToInstall',
        'CurStepChanged',
        'CurUninstallStepChanged'
    )) {
    if ($iss -notmatch $pattern) {
        throw [IO.InvalidDataException]::new('The Inno Setup source contract is invalid.')
    }
}

$result = [ordered]@{
    SourcesValid = $true
    SetupValidated = $false
    SetupPath = $null
    SetupSha256 = $null
}
if (-not [string]::IsNullOrWhiteSpace($SetupPath)) {
    $setupFullPath = [IO.Path]::GetFullPath($SetupPath)
    if (-not (Test-Path -LiteralPath $setupFullPath -PathType Leaf) -or
        [IO.Path]::GetFileName($setupFullPath) -notmatch '^CodexQuotaMonitor-Setup-.+-x64\.exe$') {
        throw [IO.InvalidDataException]::new('The compiled setup path or file name is invalid.')
    }
    $hashPath = $setupFullPath + '.sha256'
    $manifestPath = Join-Path (Split-Path -Parent $setupFullPath) 'manifest.json'
    if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw [IO.InvalidDataException]::new('The setup hash or distribution manifest is missing.')
    }
    $actualHash = (Get-FileHash -LiteralPath $setupFullPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $hashText = [IO.File]::ReadAllText($hashPath)
    $expectedLine = "$actualHash  $([IO.Path]::GetFileName($setupFullPath))"
    if ($hashText.TrimEnd("`r", "`n") -cne $expectedLine) {
        throw [IO.InvalidDataException]::new('The setup SHA-256 file does not match the executable.')
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string]$manifest.SetupSha256 -cne $actualHash -or
        [string]$manifest.SetupFileName -cne [IO.Path]::GetFileName($setupFullPath) -or
        [string]$manifest.SigningStatus -notin @('Unsigned', 'Signed')) {
        throw [IO.InvalidDataException]::new('The distribution manifest does not match the setup executable.')
    }
    $result.SetupValidated = $true
    $result.SetupPath = $setupFullPath
    $result.SetupSha256 = $actualHash
}

[pscustomobject]$result
