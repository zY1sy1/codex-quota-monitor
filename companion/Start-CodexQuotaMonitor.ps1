#requires -Version 7.4

[CmdletBinding()]
param(
    [switch] $Headless,

    [string] $AppServerExecutable,

    [string[]] $AppServerArguments,

    [string] $LocalAppData,

    [string] $Startup,

    [string] $ProgramRoot,

    [string] $InstancePrefix = 'Local\CodexQuotaMonitor',

    [ValidateRange(0, [int]::MaxValue)]
    [int] $RunForSeconds = 0,

    [ValidateRange(25, 1000)]
    [int] $TickMilliseconds = 100,

    [ValidateRange(1, 300)]
    [int] $RequestTimeoutSeconds = 10,

    [switch] $PassThru
)

$manifestPath = Join-Path $PSScriptRoot 'CodexQuotaMonitor.psd1'
$module = Import-Module -Name $manifestPath -Force -PassThru

try {
    $runtimeArguments = @{}
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        $runtimeArguments[$entry.Key] = $entry.Value
    }

    & $module {
        param([hashtable] $Arguments)

        Invoke-CodexQuotaMonitorRuntime @Arguments
    } $runtimeArguments
}
finally {
    Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
}
