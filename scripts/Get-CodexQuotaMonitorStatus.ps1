#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\companion\CodexQuotaMonitor.psd1') -Force
Get-CodexQuotaMonitorStatus
