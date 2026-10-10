#requires -Version 7.4
[CmdletBinding()]
param(
    [switch]$Demo,
    [ValidateSet('Full', 'CompactBar', 'Orb')][string]$Mode = 'Full',
    [ValidateSet('Light', 'Dark')][string]$Theme = 'Dark',
    [string]$DataRoot = (Join-Path $PSScriptRoot '..\outputs\desktop\preview-state')
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([IO.Path]::GetFullPath((& git -C $repoRoot rev-parse --show-toplevel).Trim()) -ne $repoRoot) { throw 'The canonical repository could not be verified.' }
$exe = Join-Path $repoRoot 'companion\Desktop\CodexQuotaMonitor.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { & (Join-Path $repoRoot 'build\Build-Desktop.ps1') }
$start = [Diagnostics.ProcessStartInfo]::new($exe)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
foreach ($argument in @('--data-root', [IO.Path]::GetFullPath($DataRoot), '--instance-prefix', 'Local\CodexQuotaMonitor.CSharp.Preview', '--mode', $Mode, '--theme', $Theme)) { $start.ArgumentList.Add($argument) }
if ($Demo) { $start.ArgumentList.Add('--demo') }
[Diagnostics.Process]::Start($start) | Select-Object Id, ProcessName
