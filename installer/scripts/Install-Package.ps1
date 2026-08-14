#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProgramRoot,
    [Parameter(Mandatory)][string]$LocalAppData,
    [Parameter(Mandatory)][string]$Startup,
    [Parameter(Mandatory)][string]$PwshPath,
    [switch]$SkipStart
)

$ErrorActionPreference = 'Stop'
$module = $null
try {
    $programRootPath = [IO.Path]::GetFullPath($ProgramRoot)
    $payloadPath = Join-Path $programRootPath 'payload'
    $manifestPath = Join-Path $payloadPath 'CodexQuotaMonitor.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw [IO.InvalidDataException]::new('The installer payload is incomplete.')
    }

    $module = Import-Module -Name $manifestPath -Force -PassThru
    $result = Install-CodexQuotaMonitor `
        -SourcePath $payloadPath `
        -ProgramRoot $programRootPath `
        -LocalAppData $LocalAppData `
        -Startup $Startup `
        -PwshPath $PwshPath `
        -InstancePrefix 'Local\CodexQuotaMonitor' `
        -SkipStart:$SkipStart

    $result |
        Select-Object Operation, Changed, Installed, Running, StartupEnabled, Status,
            LastErrorCategory, ProgramRoot, AppPath, SettingsPath, HealthPath, LogDirectory |
        ConvertTo-Json -Compress
}
catch {
    [Console]::Error.WriteLine('Codex Quota Monitor package installation failed.')
    exit 1
}
finally {
    if ($null -ne $module) {
        Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
    }
}
