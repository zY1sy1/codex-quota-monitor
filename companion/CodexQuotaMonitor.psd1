@{
    RootModule = 'CodexQuotaMonitor.psm1'
    ModuleVersion = '1.1.0'
    GUID = '7e095aae-f952-43b8-8d93-e38b6f9703b5'
    Author = 'Local developer'
    CompanyName = 'Local developer'
    Copyright = '(c) Local developer. All rights reserved.'
    Description = 'Windows companion for displaying official Codex ChatGPT quota windows.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Install-CodexQuotaMonitor'
        'Repair-CodexQuotaMonitor'
        'Uninstall-CodexQuotaMonitor'
        'Start-CodexQuotaMonitor'
        'Stop-CodexQuotaMonitor'
        'Get-CodexQuotaMonitorStatus'
        'Test-CodexQuotaMonitorHealth'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Codex', 'Quota', 'Windows', 'Tray')
            ProjectUri = 'https://chatgpt.com/codex/settings/usage'
        }
    }
}
