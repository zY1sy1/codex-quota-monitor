#requires -Version 7.4
[CmdletBinding()]
param([string]$DotnetPath)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([IO.Path]::GetFullPath((& git -C $repoRoot rev-parse --show-toplevel).Trim()) -ne $repoRoot) { throw 'The canonical Git repository could not be verified.' }
if ([string]::IsNullOrWhiteSpace($DotnetPath)) { $localSdk = Join-Path $repoRoot '.tools\dotnet\dotnet.exe'; $DotnetPath = if (Test-Path -LiteralPath $localSdk) { $localSdk } else { (Get-Command dotnet -ErrorAction Stop).Source } }
$project = Join-Path $repoRoot 'desktop\CodexQuotaMonitor.Tests\CodexQuotaMonitor.Tests.csproj'
& $DotnetPath run --project $project -c Release -- $repoRoot
if ($LASTEXITCODE -ne 0) { throw 'Desktop behavioral tests failed.' }
