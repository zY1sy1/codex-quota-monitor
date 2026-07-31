BeforeAll {
    $script:CompanionRoot = Join-Path $PSScriptRoot '..\..\companion'
    $script:ManifestPath = Join-Path $script:CompanionRoot 'CodexQuotaMonitor.psd1'
    $script:RuntimePath = Join-Path $script:CompanionRoot 'Start-CodexQuotaMonitor.ps1'
    $script:FakeServerPath = Join-Path $PSScriptRoot '..\Fixtures\FakeAppServer.ps1'
}

Describe 'Codex quota monitor production composition' {
    It 'declares the fixed module identity and only the seven management exports' {
        Test-Path -LiteralPath $ManifestPath -PathType Leaf | Should -BeTrue
        $manifest = Import-PowerShellDataFile -Path $ManifestPath

        $manifest.RootModule | Should -BeExactly 'CodexQuotaMonitor.psm1'
        $manifest.ModuleVersion | Should -BeExactly '0.1.0'
        $manifest.PowerShellVersion | Should -BeExactly '7.4'
        [guid]$manifest.GUID | Should -Not -Be ([guid]::Empty)
        @($manifest.FunctionsToExport) | Should -Be @(
            'Install-CodexQuotaMonitor'
            'Repair-CodexQuotaMonitor'
            'Uninstall-CodexQuotaMonitor'
            'Start-CodexQuotaMonitor'
            'Stop-CodexQuotaMonitor'
            'Get-CodexQuotaMonitorStatus'
            'Test-CodexQuotaMonitorHealth'
        )
    }

    It 'runs headless through the full fake App Server handshake and writes only sanitized health' {
        Test-Path -LiteralPath $RuntimePath -PathType Leaf | Should -BeTrue
        $localAppData = Join-Path $TestDrive 'Local App Data 测试'
        $startup = Join-Path $TestDrive 'Startup'
        New-Item -ItemType Directory -Path $startup -Force | Out-Null
        $instancePrefix = 'Local\CodexQuotaMonitor.RuntimeTest.' + [guid]::NewGuid().ToString('N')
        $pwsh = (Get-Process -Id $PID).Path
        $serverArguments = @(
            '-NoLogo'
            '-NoProfile'
            '-NonInteractive'
            '-File'
            $FakeServerPath
            '-Scenario'
            'RuntimeHappy'
        )

        $result = & $RuntimePath `
            -Headless `
            -AppServerExecutable $pwsh `
            -AppServerArguments $serverArguments `
            -LocalAppData $localAppData `
            -Startup $startup `
            -InstancePrefix $instancePrefix `
            -RunForSeconds 3 `
            -PassThru

        $healthPath = Join-Path $localAppData 'CodexQuotaMonitor\data\health.json'
        Test-Path -LiteralPath $healthPath -PathType Leaf | Should -BeTrue
        $healthText = Get-Content -LiteralPath $healthPath -Raw
        $health = $healthText | ConvertFrom-Json

        @($health.PSObject.Properties.Name) | Should -Be @(
            'SchemaVersion', 'Status', 'PlanType', 'QuotaWindowCount', 'LastSuccessAt',
            'LastErrorCategory', 'LastErrorMessage', 'ProcessId', 'UpdatedAt'
        )
        $health.SchemaVersion | Should -Be 1
        $health.Status | Should -BeExactly 'Live'
        $health.PlanType | Should -BeExactly 'plus'
        $health.QuotaWindowCount | Should -Be 2
        [datetimeoffset]$health.LastSuccessAt | Should -BeGreaterThan ([datetimeoffset]'2020-01-01')
        $health.LastErrorCategory | Should -BeNullOrEmpty
        $health.LastErrorMessage | Should -BeNullOrEmpty
        $health.ProcessId | Should -Be $PID
        [datetimeoffset]$health.UpdatedAt | Should -BeGreaterThan ([datetimeoffset]'2020-01-01')

        $result.Status | Should -BeExactly 'Live'
        $result.PlanType | Should -BeExactly 'plus'
        @($result.QuotaWindows).Count | Should -Be 2

        $allPersistedText = @(
            Get-ChildItem -LiteralPath (Join-Path $localAppData 'CodexQuotaMonitor') -Recurse -File |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
        ) -join "`n"
        $allPersistedText | Should -Not -Match 'FAKE_RUNTIME_SECRET'
        $allPersistedText | Should -Not -Match 'usedPercent|rateLimitsByLimitId|authorization'
        Get-ChildItem -LiteralPath (Split-Path $healthPath -Parent) -Filter '*.tmp' | Should -BeNullOrEmpty
    }

    It 'clears the last displayed quota after the account changes away from ChatGPT' {
        $localAppData = Join-Path $TestDrive 'Auth Change'
        $startup = Join-Path $TestDrive 'Auth Change Startup'
        New-Item -ItemType Directory -Path $startup -Force | Out-Null
        $instancePrefix = 'Local\CodexQuotaMonitor.AuthChange.' + [guid]::NewGuid().ToString('N')
        $pwsh = (Get-Process -Id $PID).Path

        $result = & $RuntimePath `
            -Headless `
            -AppServerExecutable $pwsh `
            -AppServerArguments @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $FakeServerPath,
                '-Scenario', 'RuntimeAuthChange'
            ) `
            -LocalAppData $localAppData `
            -Startup $startup `
            -InstancePrefix $instancePrefix `
            -RunForSeconds 2 `
            -PassThru

        $health = Get-Content -LiteralPath (
            Join-Path $localAppData 'CodexQuotaMonitor\data\health.json'
        ) -Raw | ConvertFrom-Json
        $health.Status | Should -BeExactly 'AuthRequired'
        $health.PlanType | Should -BeNullOrEmpty
        $health.QuotaWindowCount | Should -Be 0
        $result.Status | Should -BeExactly 'AuthRequired'
        $result.PlanType | Should -BeNullOrEmpty
        @($result.QuotaWindows).Count | Should -Be 0
    }

    It 'refreshes immediately again when the same bucket enters a later reset cycle' {
        $localAppData = Join-Path $TestDrive 'Reset Cycles'
        $startup = Join-Path $TestDrive 'Reset Cycles Startup'
        New-Item -ItemType Directory -Path $startup -Force | Out-Null
        $instancePrefix = 'Local\CodexQuotaMonitor.ResetCycles.' + [guid]::NewGuid().ToString('N')
        $pwsh = (Get-Process -Id $PID).Path

        $result = & $RuntimePath `
            -Headless `
            -AppServerExecutable $pwsh `
            -AppServerArguments @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $FakeServerPath,
                '-Scenario', 'RuntimeResetCycles'
            ) `
            -LocalAppData $localAppData `
            -Startup $startup `
            -InstancePrefix $instancePrefix `
            -RunForSeconds 3 `
            -PassThru

        $fiveHour = @($result.QuotaWindows | Where-Object WindowDurationMins -eq 300)
        $fiveHour.Count | Should -Be 1
        $fiveHour[0].RemainingPercent | Should -Be 70
        $fiveHour[0].ResetsAt | Should -Be 1893456000
    }

    It 'moves a request-level initialization error into the reconnect schedule' {
        $localAppData = Join-Path $TestDrive 'Initialize Error'
        $startup = Join-Path $TestDrive 'Initialize Error Startup'
        New-Item -ItemType Directory -Path $startup -Force | Out-Null
        $instancePrefix = 'Local\CodexQuotaMonitor.InitializeError.' + [guid]::NewGuid().ToString('N')
        $pwsh = (Get-Process -Id $PID).Path

        $result = & $RuntimePath `
            -Headless `
            -AppServerExecutable $pwsh `
            -AppServerArguments @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $FakeServerPath,
                '-Scenario', 'RuntimeInitializeError'
            ) `
            -LocalAppData $localAppData `
            -Startup $startup `
            -InstancePrefix $instancePrefix `
            -RunForSeconds 1 `
            -PassThru

        $health = Get-Content -LiteralPath (
            Join-Path $localAppData 'CodexQuotaMonitor\data\health.json'
        ) -Raw | ConvertFrom-Json
        $health.Status | Should -BeExactly 'Reconnecting'
        $health.LastErrorCategory | Should -BeExactly 'RequestFailed'
        $result.Status | Should -BeExactly 'Reconnecting'
    }
}
