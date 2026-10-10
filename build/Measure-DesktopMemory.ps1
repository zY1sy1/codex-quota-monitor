#requires -Version 7.4
[CmdletBinding()]
param([ValidateRange(15, 120)][int]$Seconds = 30)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([IO.Path]::GetFullPath((& git -C $repoRoot rev-parse --show-toplevel).Trim()) -ne $repoRoot) { throw 'The canonical Git repository could not be verified.' }
$fixture = Join-Path $repoRoot 'desktop\CodexQuotaMonitor.Tests\bin\Release\net8.0-windows\CodexQuotaMonitor.Tests.exe'
$desktop = Join-Path $repoRoot 'desktop\CodexQuotaMonitor.Desktop\bin\Release\net8.0-windows\win-x64\CodexQuotaMonitor.exe'
if (-not (Test-Path -LiteralPath $fixture) -or -not (Test-Path -LiteralPath $desktop)) { throw 'Run build\Test-Desktop.ps1 first.' }
$resultRoot = Join-Path $repoRoot ('outputs\desktop\memory\' + [guid]::NewGuid().ToString('N'))
$nativeRoot = Join-Path $resultRoot 'native'
$legacyParent = Join-Path $resultRoot 'legacy'
$legacyRoot = Join-Path $legacyParent 'CodexQuotaMonitor'
$null = New-Item -ItemType Directory -Path $resultRoot, $nativeRoot, $legacyParent -Force
$prefix = 'Local\CodexQuotaMonitor.Memory.' + [guid]::NewGuid().ToString('N')
$legacyPwsh = Join-Path $env:LOCALAPPDATA 'Programs\CodexQuotaMonitor\runtime\pwsh\pwsh.exe'
if (-not (Test-Path -LiteralPath $legacyPwsh)) { $legacyPwsh = (Get-Process -Id $PID).Path }
function Start-MemoryProcess([string]$Executable, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    return [Diagnostics.Process]::Start($info)
}
$native = $null; $legacy = $null
try {
    $native = Start-MemoryProcess $desktop @('--data-root', $nativeRoot, '--instance-prefix', ($prefix + '.Native'), '--run-for-seconds', ([string]($Seconds + 30)), '--codex', $fixture, '--codex-argument', '--fixture-rpc')
    $legacy = Start-MemoryProcess $legacyPwsh @('-NoLogo', '-NoProfile', '-NonInteractive', '-Sta', '-WindowStyle', 'Hidden', '-File', (Join-Path $repoRoot 'companion\Start-CodexQuotaMonitor.ps1'), '-Legacy', '-LocalAppData', $legacyParent, '-InstancePrefix', ($prefix + '.Legacy'), '-RunForSeconds', ([string]($Seconds + 30)), '-AppServerExecutable', $fixture, '-AppServerArguments', '--fixture-rpc')
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.Elapsed.TotalSeconds -lt $Seconds) {
        if ($native.HasExited -or $legacy.HasExited) { throw 'A benchmark process exited unexpectedly.' }
        Start-Sleep -Milliseconds 500
    }
    $data = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter ("IDProcess = {0} OR IDProcess = {1}" -f $native.Id, $legacy.Id) | ForEach-Object {
        [ordered]@{ Runtime = if ($_.IDProcess -eq $native.Id) { 'CSharpWpf' } else { 'PowerShellWpf' }; ProcessId = $_.IDProcess;
            PrivateWorkingSetMB = [math]::Round($_.WorkingSetPrivate / 1MB, 1); WorkingSetMB = [math]::Round($_.WorkingSet / 1MB, 1); PrivateCommittedMB = [math]::Round($_.PrivateBytes / 1MB, 1) }
    })
    $nativeHealth = Get-Content -LiteralPath (Join-Path $nativeRoot 'data\health.json') -Raw | ConvertFrom-Json
    $legacyHealth = Get-Content -LiteralPath (Join-Path $legacyRoot 'data\health.json') -Raw | ConvertFrom-Json
    if ($nativeHealth.Status -ne 'Live' -or $legacyHealth.Status -ne 'Live' -or $nativeHealth.QuotaWindowCount -ne $legacyHealth.QuotaWindowCount -or $nativeHealth.RenderedOfficialQuotaCount -ne 2) { throw 'The benchmark did not reach equivalent live quota data and rendered cards.' }
    $report = [ordered]@{ Scenario = 'Full window, dark theme, same two official quota windows, no relay providers'; WarmupSeconds = $Seconds; CapturedAt = [DateTimeOffset]::UtcNow.ToString('o'); MainProcesses = $data }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $resultRoot 'memory.json') -Encoding utf8
    $report | ConvertTo-Json -Depth 6
    Write-Output (Join-Path $resultRoot 'memory.json')
}
finally {
    foreach ($name in @(($prefix + '.Native'), ($prefix + '.Legacy'))) {
        try { $signal = [Threading.EventWaitHandle]::OpenExisting($name + '.Exit'); $signal.Set() | Out-Null; $signal.Dispose() } catch [Threading.WaitHandleCannotBeOpenedException] { }
    }
    foreach ($process in @($native, $legacy)) {
        if ($null -ne $process) { if (-not $process.HasExited -and -not $process.WaitForExit(5000)) { $process.Kill($true) }; $process.Dispose() }
    }
}
