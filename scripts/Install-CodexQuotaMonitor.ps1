#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '..\build\Build-Desktop.ps1') | Out-Null
Import-Module (Join-Path $PSScriptRoot '..\companion\CodexQuotaMonitor.psd1') -Force
Install-CodexQuotaMonitor
