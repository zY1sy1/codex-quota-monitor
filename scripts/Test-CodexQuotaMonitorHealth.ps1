#requires -Version 7.4
[CmdletBinding()]
param(
    [switch]$Live
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\companion\CodexQuotaMonitor.psd1') -Force
Test-CodexQuotaMonitorHealth -Live:$Live
