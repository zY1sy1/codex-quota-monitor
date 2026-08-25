#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProgramRoot,
    [Parameter(Mandatory)][string]$LocalAppData,
    [Parameter(Mandatory)][string]$Startup,
    [switch]$PreserveData
)

$ErrorActionPreference = 'Stop'
$module = $null
try {
    $programRootPath = [IO.Path]::GetFullPath($ProgramRoot)
    $manifestPath = Join-Path $programRootPath 'app\CodexQuotaMonitor.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw [IO.InvalidDataException]::new('The installed application is incomplete.')
    }

    $module = Import-Module -Name $manifestPath -Force -PassThru
    $result = Uninstall-CodexQuotaMonitor `
        -ProgramRoot $programRootPath `
        -LocalAppData $LocalAppData `
        -Startup $Startup `
        -InstancePrefix 'Local\CodexQuotaMonitor' `
        -PreserveData:$PreserveData `
        -PreserveProgramFiles

    $result |
        Select-Object Operation, Changed, Installed, Running, StartupEnabled,
            PreservedData, PreservedProgramFiles, Root, DataPath, LogDirectory, ShortcutPath |
        ConvertTo-Json -Compress
}
catch {
    [Console]::Error.WriteLine('Codex Quota Monitor uninstall preparation failed.')
    exit 1
}
finally {
    if ($null -ne $module) {
        Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
    }
}
