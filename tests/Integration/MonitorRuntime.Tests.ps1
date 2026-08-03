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

    It 'composes all display views and invokes the desktop initializer exactly once' {
        $localAppData = Join-Path $TestDrive 'Desktop Initializer'
        $startup = Join-Path $TestDrive 'Desktop Initializer Startup'
        New-Item -ItemType Directory -Path $startup -Force | Out-Null
        $instancePrefix = 'Local\CodexQuotaMonitor.DesktopInitializer.' + [guid]::NewGuid().ToString('N')
        $pwsh = (Get-Process -Id $PID).Path
        $calls = [Collections.Generic.List[string]]::new()
        $relayCacheWrites = [Collections.Generic.List[object]]::new()
        $existingRelayProvider = [pscustomobject][ordered]@{
            Id = '11111111-1111-1111-1111-111111111111'
            Name = 'Existing relay'
            Enabled = $false
            BaseUrl = 'https://relay.example'
            TemplateType = 'General'
            Script = 'fixture'
            TimeoutSeconds = 10
            IntervalMinutes = 15
            TrustedDestination = $null
            Secrets = [pscustomobject]@{ ApiKey = ''; AccessToken = ''; UserId = '' }
        }

        $windowView = [pscustomobject][ordered]@{
            Window = [pscustomobject]@{}
            SetFreshness = { param([bool]$IsLive, [string]$Text) }
            Dispose = { }
        }
        $compactBarView = [pscustomobject][ordered]@{ Window = [pscustomobject]@{}; Dispose = { } }
        $orbView = [pscustomobject][ordered]@{ Window = [pscustomobject]@{}; Dispose = { } }
        $trayView = [pscustomobject][ordered]@{
            SetSeverity = { param([string]$Severity) }
            SetTooltip = { param([string]$Tooltip) }
            Dispose = { }
        }
        $interaction = [pscustomobject][ordered]@{
            ShowAndActivate = { }
            Dispose = { }
        }
        $relayManagerView = [pscustomobject][ordered]@{
            Dispose = { $calls.Add('dispose-relay-manager-view') | Out-Null }
        }
        $relayManagerController = [pscustomobject][ordered]@{
            Show = { $calls.Add('show-relay-manager') | Out-Null }
            Dispose = { $calls.Add('dispose-relay-manager-controller') | Out-Null }
        }
        $displayController = [pscustomobject][ordered]@{
            State = [pscustomobject]@{ Visible = $true; Mode = 'Full'; Theme = 'Dark'; FullLayout = 'Overview'; Topmost = $true }
            SetSnapshot = { param($Rows) $calls.Add("snapshot:$(@($Rows).Count)") | Out-Null }
            Dispose = { $calls.Add('dispose-display') | Out-Null }
        }
        $overrides = [ordered]@{
            ReadRelayProviders = {
                param($Path)
                [pscustomobject]@{ SchemaVersion = 1; Providers = @($existingRelayProvider) }
            }.GetNewClosure()
            ReadRelayCache = {
                param($Path)
                [pscustomobject]@{
                    SchemaVersion = 1
                    Providers = @([pscustomobject]@{
                        ProviderId = $existingRelayProvider.Id
                        UpdatedAt = '2026-08-01T08:00:00.0000000+00:00'
                        Results = @([pscustomobject]@{
                            IsValid = $true; Remaining = 9; Unit = 'USD'; PlanName = 'Old'
                        })
                    })
                }
            }.GetNewClosure()
            WriteRelayCache = {
                param($Path, $Cache)
                $relayCacheWrites.Add($Cache) | Out-Null
            }.GetNewClosure()
            NewWindow = { Write-Output -NoEnumerate $windowView }.GetNewClosure()
            NewCompactBar = { Write-Output -NoEnumerate $compactBarView }.GetNewClosure()
            NewOrb = { Write-Output -NoEnumerate $orbView }.GetNewClosure()
            NewTray = { param([switch]$Visible) Write-Output -NoEnumerate $trayView }.GetNewClosure()
            NewRelayManager = {
                $calls.Add('new-relay-manager-view') | Out-Null
                Write-Output -NoEnumerate $relayManagerView
            }.GetNewClosure()
            NewRelayManagerController = {
                param(
                    $View, $Providers, $WriteProviders, $ProtectSecret, $UnprotectSecret,
                    $QueryProvider, $ApplyProviders, $RemoveProviderArtifacts, $ConfirmDelete
                )
                $View | Should -Be $relayManagerView
                & $ApplyProviders @($existingRelayProvider) @($existingRelayProvider.Id) @() $false
                $calls.Add('new-relay-manager-controller') | Out-Null
                Write-Output -NoEnumerate $relayManagerController
            }.GetNewClosure()
            NewDisplay = {
                param($Settings, $FullView, $CompactBarView, $OrbView, $SaveSettings, [switch]$DeferShow)
                $FullView | Should -Be $windowView
                $CompactBarView | Should -Be $compactBarView
                $OrbView | Should -Be $orbView
                $DeferShow | Should -BeTrue
                $calls.Add('new-display') | Out-Null
                Write-Output -NoEnumerate $displayController
            }.GetNewClosure()
            NewInteraction = {
                param(
                    $Settings,
                    $WindowView,
                    $DisplayController,
                    $TrayView,
                    $SaveSettings,
                    $ApplyStartupPreference,
                    $RequestRefresh,
                    $ExitEvent,
                    $OpenTarget,
                    $LogDirectory,
                    $OnManageRelays
                )
                $DisplayController | Should -Be $displayController
                $OnManageRelays | Should -BeOfType ([scriptblock])
                & $OnManageRelays
                Write-Output -NoEnumerate $interaction
            }.GetNewClosure()
            InitializeDesktop = {
                param(
                    $WindowView, $CompactBarView, $OrbView, $DisplayController,
                    $TrayView, $Settings, $GetWorkAreas, $SetPlacement
                )
                $DisplayController | Should -Be $displayController
                $calls.Add('initialize-desktop') | Out-Null
            }.GetNewClosure()
        }

        $module = Import-Module -Name $ManifestPath -Force -PassThru
        try {
            $arguments = @{
                AppServerExecutable = $pwsh
                AppServerArguments = @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $FakeServerPath,
                    '-Scenario', 'RuntimeHappy'
                )
                LocalAppData = $localAppData
                Startup = $startup
                InstancePrefix = $instancePrefix
                RunForSeconds = 1
                TickMilliseconds = 50
                PassThru = $true
                FunctionOverrides = $overrides
            }
            $result = & $module {
                param([hashtable]$RuntimeArguments)
                Invoke-CodexQuotaMonitorRuntime @RuntimeArguments
            } $arguments
        }
        finally {
            Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
        }

        @($calls | Where-Object { $_ -notlike 'snapshot:*' -and $_ -ne 'dispose-display' }) |
            Should -Be @(
                'new-relay-manager-view', 'new-relay-manager-controller',
                'new-display', 'show-relay-manager', 'initialize-desktop',
                'dispose-relay-manager-controller'
            )
        @($calls | Where-Object { $_ -like 'snapshot:*' }).Count | Should -BeGreaterThan 0
        @($calls | Where-Object { $_ -eq 'dispose-display' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -eq 'dispose-relay-manager-view' }).Count | Should -Be 0
        $relayCacheWrites.Count | Should -Be 1
        @($relayCacheWrites[0].Providers).Count | Should -Be 0
        $result.Status | Should -BeExactly 'Live'
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
            'LastErrorCategory', 'LastErrorMessage', 'ProcessId', 'UpdatedAt',
            'RelayProviderCount', 'RelayLiveCount', 'RelayStaleCount', 'RelayInvalidCount',
            'RelayHostState', 'DisplayMode', 'Theme'
        )
        $health.SchemaVersion | Should -Be 2
        $health.Status | Should -BeExactly 'Live'
        $health.PlanType | Should -BeExactly 'plus'
        $health.QuotaWindowCount | Should -Be 2
        [datetimeoffset]$health.LastSuccessAt | Should -BeGreaterThan ([datetimeoffset]'2020-01-01')
        $health.LastErrorCategory | Should -BeNullOrEmpty
        $health.LastErrorMessage | Should -BeNullOrEmpty
        $health.ProcessId | Should -Be $PID
        [datetimeoffset]$health.UpdatedAt | Should -BeGreaterThan ([datetimeoffset]'2020-01-01')
        $health.RelayProviderCount | Should -Be 0
        $health.RelayLiveCount | Should -Be 0
        $health.RelayStaleCount | Should -Be 0
        $health.RelayInvalidCount | Should -Be 0
        $health.RelayHostState | Should -BeExactly 'Disabled'
        $health.DisplayMode | Should -BeExactly 'Full'
        $health.Theme | Should -BeExactly 'Dark'

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
