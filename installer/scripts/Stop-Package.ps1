#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProgramRoot,
    [Parameter(Mandatory)][string]$LocalAppData,
    [Parameter(Mandatory)][string]$Startup,
    [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$module = $null
try {
    $programRootPath = [IO.Path]::GetFullPath($ProgramRoot)
    $packagedManifest = Join-Path $programRootPath 'app\CodexQuotaMonitor.psd1'
    $legacyManifest = Join-Path $LocalAppData 'CodexQuotaMonitor\app\CodexQuotaMonitor.psd1'
    $manifestPath = $null
    $installedProgramRoot = $null

    if (Test-Path -LiteralPath $packagedManifest -PathType Leaf) {
        $manifestPath = $packagedManifest
        $installedProgramRoot = $programRootPath
    }
    elseif (Test-Path -LiteralPath $legacyManifest -PathType Leaf) {
        $manifestPath = $legacyManifest
    }

    if ($null -eq $manifestPath) {
        [pscustomobject][ordered]@{
            Operation = 'Stop'
            Changed = $false
            Installed = $false
            Running = $false
            SignalSent = $false
            Status = 'NotInstalled'
            LastErrorCategory = $null
        } | ConvertTo-Json -Compress
        exit 0
    }

    $module = Import-Module -Name $manifestPath -Force -PassThru
    $arguments = @{
        LocalAppData = $LocalAppData
        Startup = $Startup
        InstancePrefix = 'Local\CodexQuotaMonitor'
        TimeoutSeconds = $TimeoutSeconds
        Wait = $true
    }
    if ($null -ne $installedProgramRoot) {
        $arguments.ProgramRoot = $installedProgramRoot
    }
    $result = Stop-CodexQuotaMonitor @arguments

    $result |
        Select-Object Operation, Changed, Installed, Running, SignalSent, Status,
            LastErrorCategory, ProgramRoot, AppPath |
        ConvertTo-Json -Compress
}
catch {
    [Console]::Error.WriteLine('Codex Quota Monitor shutdown failed.')
    exit 1
}
finally {
    if ($null -ne $module) {
        Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
    }
}
