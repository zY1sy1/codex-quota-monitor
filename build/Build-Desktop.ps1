#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $PSScriptRoot '..\companion\Desktop'),
    [string]$DotnetPath,
    [switch]$FrameworkDependent
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$gitRoot = (& git -C $repoRoot rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($gitRoot) -ne $repoRoot) { throw 'Build-Desktop must run against the canonical Git repository.' }
if ([string]::IsNullOrWhiteSpace($DotnetPath)) {
    $localSdk = Join-Path $repoRoot '.tools\dotnet\dotnet.exe'
    $DotnetPath = if (Test-Path -LiteralPath $localSdk -PathType Leaf) { $localSdk } else { (Get-Command dotnet -ErrorAction Stop).Source }
}
$sdkVersions = @(& $DotnetPath --list-sdks)
if ($sdkVersions.Count -eq 0) { throw 'Building the C# desktop requires .NET SDK 8 or later.' }
$destinationPath = [IO.Path]::GetFullPath($Destination)
if ($destinationPath -like '*\AppData\Local\Programs\CodexQuotaMonitor\app*') { throw 'Build to a source or staging directory, never to deployment output.' }
$project = Join-Path $repoRoot 'desktop\CodexQuotaMonitor.Desktop\CodexQuotaMonitor.Desktop.csproj'
$arguments = @('publish', $project, '-c', 'Release', '-r', 'win-x64', '--nologo', '-o', $destinationPath, '--self-contained', (-not $FrameworkDependent).ToString().ToLowerInvariant(), '-p:PublishSingleFile=false')
& $DotnetPath @arguments
if ($LASTEXITCODE -ne 0) { throw 'The C# desktop publish failed.' }
$exe = Join-Path $destinationPath 'CodexQuotaMonitor.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'The desktop executable was not produced.' }
$sdkRoot = Split-Path -Parent ([IO.Path]::GetFullPath($DotnetPath))
foreach ($license in @('LICENSE.txt', 'ThirdPartyNotices.txt')) {
    $sourceLicense = Join-Path $sdkRoot $license
    if (Test-Path -LiteralPath $sourceLicense -PathType Leaf) { Copy-Item -LiteralPath $sourceLicense -Destination (Join-Path $destinationPath ('DOTNET-' + $license)) -Force }
}
[IO.File]::WriteAllText((Join-Path $destinationPath 'desktop-manifest.json'), ([ordered]@{
    SchemaVersion = 1
    Runtime = 'CSharpWpf'
    TargetFramework = 'net8.0-windows'
    SelfContained = -not [bool]$FrameworkDependent
    ExecutableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ DesktopRoot = $destinationPath; Executable = $exe; SelfContained = -not [bool]$FrameworkDependent }
