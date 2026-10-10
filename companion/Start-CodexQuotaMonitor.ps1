#requires -Version 7.4

[CmdletBinding()]
param(
    [switch] $Headless,

    [switch] $Legacy,

    [string] $AppServerExecutable,

    [string[]] $AppServerArguments,

    [string] $LocalAppData,

    [string] $Startup,

    [string] $ProgramRoot,

    [string] $InstancePrefix = 'Local\CodexQuotaMonitor',

    [ValidateRange(0, [int]::MaxValue)]
    [int] $RunForSeconds = 0,

    [ValidateRange(25, 1000)]
    [int] $TickMilliseconds = 250,

    [ValidateRange(1, 300)]
    [int] $RequestTimeoutSeconds = 10,

    [switch] $PassThru
)

if ([string]::IsNullOrWhiteSpace($env:windir) -and
    -not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
    $env:windir = $env:SystemRoot
}

if ([string]::IsNullOrWhiteSpace($ProgramRoot)) {
    $candidateProgramRoot = Split-Path -Parent $PSScriptRoot
    if (Test-Path -LiteralPath (Join-Path $candidateProgramRoot 'installer-manifest.json') -PathType Leaf) {
        $ProgramRoot = $candidateProgramRoot
    }
}

$manifestPath = Join-Path $PSScriptRoot 'CodexQuotaMonitor.psd1'
$desktopExecutable = Join-Path $PSScriptRoot 'Desktop\CodexQuotaMonitor.exe'
if (-not $Legacy -and -not $Headless -and -not $PassThru -and
    (Test-Path -LiteralPath $desktopExecutable -PathType Leaf)) {
    $nativeLocalAppData = if ([string]::IsNullOrWhiteSpace($LocalAppData)) { [Environment]::GetFolderPath('LocalApplicationData') } else { $LocalAppData }
    $nativeStartInfo = [Diagnostics.ProcessStartInfo]::new($desktopExecutable)
    $nativeStartInfo.UseShellExecute = $false
    $nativeStartInfo.CreateNoWindow = $true
    $nativeStartInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    foreach ($argument in @('--data-root', (Join-Path $nativeLocalAppData 'CodexQuotaMonitor'), '--instance-prefix', $InstancePrefix)) {
        $nativeStartInfo.ArgumentList.Add($argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($AppServerExecutable)) {
        $nativeStartInfo.ArgumentList.Add('--codex')
        $nativeStartInfo.ArgumentList.Add($AppServerExecutable)
    }
    foreach ($argument in $AppServerArguments) { $nativeStartInfo.ArgumentList.Add('--codex-argument'); $nativeStartInfo.ArgumentList.Add($argument) }
    if ($RunForSeconds -gt 0) { $nativeStartInfo.ArgumentList.Add('--run-for-seconds'); $nativeStartInfo.ArgumentList.Add([string]$RunForSeconds) }
    $nativeProcess = [Diagnostics.Process]::Start($nativeStartInfo)
    try { if ($RunForSeconds -gt 0) { $nativeProcess.WaitForExit(); if ($nativeProcess.ExitCode -ne 0) { throw 'The C# desktop runtime failed.' } } }
    finally { $nativeProcess.Dispose() }
    return
}
$module = Import-Module -Name $manifestPath -Force -PassThru

try {
    $runtimeArguments = @{}
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Key -eq 'Legacy') { continue }
        $runtimeArguments[$entry.Key] = $entry.Value
    }
    if (-not [string]::IsNullOrWhiteSpace($ProgramRoot)) {
        $runtimeArguments['ProgramRoot'] = $ProgramRoot
    }

    & $module {
        param([hashtable] $Arguments)

        Invoke-CodexQuotaMonitorRuntime @Arguments
    } $runtimeArguments
}
finally {
    Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
}
