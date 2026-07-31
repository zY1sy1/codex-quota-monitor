#requires -Version 7.4
[CmdletBinding()]
param(
    [switch]$PreserveData
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\companion\CodexQuotaMonitor.psd1') -Force
Uninstall-CodexQuotaMonitor -PreserveData:$PreserveData
