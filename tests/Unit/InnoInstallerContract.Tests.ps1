BeforeAll {
    $script:IssPath = Join-Path $PSScriptRoot '..\..\installer\CodexQuotaMonitor.iss'
}

Describe 'Inno Setup installer contract' {
    It 'defines a stable current-user x64 product and bundled payload' {
        Test-Path -LiteralPath $IssPath -PathType Leaf | Should -BeTrue
        $source = Get-Content -LiteralPath $IssPath -Raw

        $source | Should -Match 'AppId=\{\{7B0B5FCB-62F5-4D3C-AF28-0EE1CA930D47\}'
        $source | Should -Match 'DefaultDirName=\{localappdata\}\\Programs\\CodexQuotaMonitor'
        $source | Should -Match 'PrivilegesRequired=lowest'
        $source | Should -Match 'PrivilegesRequiredOverridesAllowed=\s*(?:\r?\n)'
        $source | Should -Not -Match 'PrivilegesRequiredOverridesAllowed=.*(?:commandline|dialog)'
        $source | Should -Match 'ArchitecturesAllowed=x64compatible'
        $source | Should -Match 'MinVersion=10\.0\.190[0-9]{2}'
        $source | Should -Match 'VersionInfoProductVersion=\{#NumericVersion\}'
        $source | Should -Match 'runtime\\pwsh\\pwsh\.exe'
        $source | Should -Match 'payload\\\*'
    }

    It 'stops old packages, validates post-install, and prepares uninstall' {
        $source = Get-Content -LiteralPath $IssPath -Raw

        $source | Should -Match 'PrepareToInstall'
        $source | Should -Match 'Stop-Package\.ps1'
        $source | Should -Match "ExtractTemporaryFile\('Stop-Package\.ps1'\)"
        $source | Should -Match 'Install-Package\.ps1'
        $source | Should -Match 'Prepare-Uninstall\.ps1'
        $source | Should -Match 'CurStepChanged'
        $source | Should -Match 'CurUninstallStepChanged'
        $source | Should -Match 'MsgBox'
        $source | Should -Match 'WizardIsTaskSelected'
        $source | Should -Not -Match '(?<!Wizard)IsTaskSelected'
        $source | Should -Match '\{sys\}\\wscript\.exe'
        $source | Should -Match 'desktopicon'
        $source | Should -Match '\[UninstallDelete\]'
        $source | Should -Match 'Type:\s*filesandordirs;\s*Name:\s*"\{app\}\\app"'
    }

    It 'does not launch the runtime as a child of Setup' {
        $source = Get-Content -LiteralPath $IssPath -Raw

        $source | Should -Match 'Install-Package\.ps1'
        $source | Should -Match '-SkipStart'
        $source | Should -Match 'ShellExec\(\s*''open'''
        $source | Should -Match '\{sys\}\\explorer\.exe'
        $source | Should -Match 'launchafterinstall'
    }
}
