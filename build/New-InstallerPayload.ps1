#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..'),
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$Version,
    [AllowNull()][string]$GitCommit,
    [switch]$Dirty
)

$ErrorActionPreference = 'Stop'
$repoFullPath = [IO.Path]::GetFullPath($RepoRoot)
$runtimeFullPath = [IO.Path]::GetFullPath($RuntimeRoot)
$destinationFullPath = [IO.Path]::GetFullPath($Destination)
$companionRoot = Join-Path $repoFullPath 'companion'
$installerScripts = Join-Path $repoFullPath 'installer\scripts'
$iconPath = Join-Path $repoFullPath 'assets\codex-quota-monitor-white-blue.ico'

foreach ($required in @(
        $companionRoot,
        $installerScripts,
        $runtimeFullPath,
        (Join-Path $runtimeFullPath 'pwsh.exe'),
        (Join-Path $runtimeFullPath 'LICENSE.txt'),
        $iconPath
    )) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw [IO.InvalidDataException]::new('The installer payload source is incomplete.')
    }
}

if (Test-Path -LiteralPath $destinationFullPath) {
    Remove-Item -LiteralPath $destinationFullPath -Recurse -Force
}
$payloadPath = Join-Path $destinationFullPath 'payload'
$runtimeDestination = Join-Path $destinationFullPath 'runtime\pwsh'
$assetsPath = Join-Path $destinationFullPath 'assets'
$installerPath = Join-Path $destinationFullPath 'installer'
$licensesPath = Join-Path $destinationFullPath 'licenses'
$null = New-Item -ItemType Directory -Path @(
    $payloadPath, $runtimeDestination, $assetsPath, $installerPath, $licensesPath
) -Force

foreach ($item in @(Get-ChildItem -LiteralPath $companionRoot -Force)) {
    Copy-Item -LiteralPath $item.FullName -Destination $payloadPath -Recurse -Force
}
foreach ($item in @(Get-ChildItem -LiteralPath $runtimeFullPath -Force)) {
    Copy-Item -LiteralPath $item.FullName -Destination $runtimeDestination -Recurse -Force
}
foreach ($item in @(Get-ChildItem -LiteralPath $installerScripts -Force)) {
    Copy-Item -LiteralPath $item.FullName -Destination $installerPath -Recurse -Force
}
Copy-Item -LiteralPath $iconPath -Destination (Join-Path $assetsPath 'CodexQuotaMonitor.ico') -Force
Copy-Item -LiteralPath (Join-Path $runtimeFullPath 'LICENSE.txt') `
    -Destination (Join-Path $licensesPath 'PowerShell-LICENSE.txt') -Force

$relayExe = Join-Path $payloadPath 'Bin\relay-quota-host.exe'
$relayManifest = Join-Path $payloadPath 'Bin\relay-quota-host.sha256'
if (-not (Test-Path -LiteralPath $relayExe -PathType Leaf) -or
    -not (Test-Path -LiteralPath $relayManifest -PathType Leaf)) {
    throw [IO.InvalidDataException]::new('The packaged relay host is missing.')
}
$expectedRelayHash = [IO.File]::ReadAllText($relayManifest).Trim()
$actualRelayHash = (Get-FileHash -LiteralPath $relayExe -Algorithm SHA256).Hash
if ($expectedRelayHash -notmatch '^[0-9A-F]{64}$' -or $actualRelayHash -cne $expectedRelayHash) {
    throw [IO.InvalidDataException]::new('The packaged relay host integrity check failed.')
}

$forbidden = @(Get-ChildItem -LiteralPath $destinationFullPath -Recurse -Force | Where-Object {
        $_.Name -in @('.git', '.superpowers', 'tests', 'outputs', 'work') -or
        $_.Name -match '^(settings|health|relay-providers|relay-cache)\.json$' -or
        $_.Extension -eq '.log'
    })
if ($forbidden.Count -gt 0) {
    throw [IO.InvalidDataException]::new('The installer payload contains forbidden state files.')
}

$manifest = [ordered]@{
    SchemaVersion = 1
    Version = $Version
    GitCommit = if ([string]::IsNullOrWhiteSpace($GitCommit)) { $null } else { $GitCommit }
    Dirty = [bool]$Dirty
    Architecture = 'x64'
    PowerShellVersion = '7.6.4'
    RelayHostSha256 = $actualRelayHash
    CreatedAt = [DateTimeOffset]::UtcNow.ToString('o')
}
$manifestPath = Join-Path $destinationFullPath 'installer-manifest.json'
[IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 5),
    [Text.UTF8Encoding]::new($false)
)

[pscustomobject][ordered]@{
    StagingRoot = $destinationFullPath
    PayloadPath = $payloadPath
    RuntimeRoot = $runtimeDestination
    ManifestPath = $manifestPath
    RelayHostSha256 = $actualRelayHash
}
