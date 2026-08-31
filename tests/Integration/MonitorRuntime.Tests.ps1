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
        $manifest.ModuleVersion | Should -BeExactly '1.1.0'
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
        $refreshCallbacks = [Collections.Generic.List[object]]::new()
        $relayCacheWrites = [Collections.Generic.List[object]]::new()
        $schedulerCreations = [Collections.Generic.List[object]]::new()
        $settingsSnapshots = [Collections.Generic.List[string]]::new()
        $ccSwitchDiscoveries = [Collections.Generic.List[object]]::new()
        $relayImportLinkReads = [Collections.Generic.List[string]]::new()
        $relayImportTransactions = [Collections.Generic.List[object]]::new()
        $existingRelayProvider = [pscustomobject][ordered]@{
            Id = '11111111-1111-1111-1111-111111111111'
            Name = 'Existing relay'
            Enabled = $false
            BaseUrl = 'https://relay.example'
            ProviderKind = 'Generic'
            RequestDefinition = [pscustomobject][ordered]@{
                Method = 'GET'; Path = '/usage'; Query = [pscustomobject][ordered]@{}
                Headers = [pscustomobject][ordered]@{}; Body = $null
            }
            ExtractorScript = 'function(response){return {remaining:response.balance};}'
            TimeoutSeconds = 10
            IntervalMinutes = 15
            TrustedDestination = 'https://relay.example:443'
            Secrets = [pscustomobject]@{ ApiKey = ''; AccessToken = ''; UserId = '' }
        }
        $settingsPath = Join-Path $localAppData 'CodexQuotaMonitor\data\settings.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
        $settingsJson = '{"SchemaVersion":3,"Appearance":{"Theme":"Dark","DisplayMode":"Full","FullLayout":"Overview","RememberLastMode":true},"Window":{"Full":{"Left":null,"Top":null,"Width":420,"Height":560,"Topmost":true,"Visible":true},"CompactBar":{"Left":null,"Top":null},"Orb":{"Left":null,"Top":null}},"Compact":{"FocusMetric":"Auto"},"Relay":{"AutoQueryIntervalMinutes":7},"Startup":true}'
        [IO.File]::WriteAllText($settingsPath, $settingsJson, [Text.UTF8Encoding]::new($false))

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
            ToggleTopmost = { }
            SetDisplayMode = { param($Mode) }
            SetTheme = { param($Theme) }
            SetFullLayout = { param($Layout) }
            ToggleStartup = { }
            Refresh = { }
            ManageRelays = { }
            Dispose = { }
        }
        $settingsView = [pscustomobject][ordered]@{
            Dispose = { $calls.Add('dispose-settings-view') | Out-Null }
        }
        $settingsController = [pscustomobject][ordered]@{
            Show = { $calls.Add('show-settings') | Out-Null }
            Dispose = { $calls.Add('dispose-settings-controller') | Out-Null }
        }
        $relayManagerView = [pscustomobject][ordered]@{
            Dispose = { $calls.Add('dispose-relay-manager-view') | Out-Null }
        }
        $relayManagerController = [pscustomobject][ordered]@{
            Show = { $calls.Add('show-relay-manager') | Out-Null }
            Dispose = { $calls.Add('dispose-relay-manager-controller') | Out-Null }
        }
        $ccSwitchImportView = [pscustomobject][ordered]@{
            Dispose = { $calls.Add('dispose-cc-switch-import-view') | Out-Null }
        }
        $ccSwitchImportController = [pscustomobject][ordered]@{
            Show = {
                param($Providers)
                $calls.Add('show-cc-switch-import') | Out-Null
                return $null
            }
            Dispose = { $calls.Add('dispose-cc-switch-import-controller') | Out-Null }
        }
        $displayController = [pscustomobject][ordered]@{
            State = [pscustomobject]@{ Visible = $true; Mode = 'Full'; Theme = 'Dark'; FullLayout = 'Overview'; Topmost = $true }
            SetSnapshot = { param($Rows) $calls.Add("snapshot:$(@($Rows).Count)") | Out-Null }
            Dispose = { $calls.Add('dispose-display') | Out-Null }
        }
        $overrides = [ordered]@{
            ReadRelayProviders = {
                param($Path)
                [pscustomobject]@{ SchemaVersion = 2; Providers = @($existingRelayProvider) }
            }.GetNewClosure()
            DiscoverCcSwitch = {
                param($ExecutablePath, $DatabasePath)
                $ccSwitchDiscoveries.Add([pscustomobject][ordered]@{
                    ExecutablePath = $ExecutablePath
                    DatabasePath = $DatabasePath
                    ParameterNames = [string[]]@($PSBoundParameters.Keys)
                }) | Out-Null
                [pscustomobject]@{ Ok = $true; Providers = @(); Error = $null }
            }.GetNewClosure()
            ReadRelayImportLinks = {
                param($Path)
                $relayImportLinkReads.Add([string]$Path) | Out-Null
                [pscustomobject]@{ SchemaVersion = 1; Links = @() }
            }.GetNewClosure()
            WriteRelayImportTransaction = {
                param($ProviderPath, $LinkPath, $ProviderDocument, $Mutation)
                $relayImportTransactions.Add([pscustomobject][ordered]@{
                    ProviderPath = $ProviderPath
                    LinkPath = $LinkPath
                    ProviderDocument = $ProviderDocument
                    Mutation = $Mutation
                }) | Out-Null
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
            NewWindow = {
                param([AllowNull()][scriptblock]$OnRefreshRequested)
                $refreshCallbacks.Add($OnRefreshRequested) | Out-Null
                Write-Output -NoEnumerate $windowView
            }.GetNewClosure()
            NewCompactBar = { Write-Output -NoEnumerate $compactBarView }.GetNewClosure()
            NewOrb = { Write-Output -NoEnumerate $orbView }.GetNewClosure()
            NewTray = { param([switch]$Visible) Write-Output -NoEnumerate $trayView }.GetNewClosure()
            NewRelayManager = {
                $calls.Add('new-relay-manager-view') | Out-Null
                Write-Output -NoEnumerate $relayManagerView
            }.GetNewClosure()
            NewCcSwitchImportView = {
                $calls.Add('new-cc-switch-import-view') | Out-Null
                Write-Output -NoEnumerate $ccSwitchImportView
            }.GetNewClosure()
            NewCcSwitchImportController = {
                param($View, $Discover, $ReadLinks, $ConvertCandidate)
                $View | Should -Be $ccSwitchImportView
                $ConvertCandidate | Should -BeOfType ([scriptblock])
                $null = & $Discover
                $null = & $ReadLinks
                $calls.Add('new-cc-switch-import-controller') | Out-Null
                Write-Output -NoEnumerate $ccSwitchImportController
            }.GetNewClosure()
            NewRelayManagerController = {
                param(
                    $View, $Providers, $WriteRelayState, $ImportProvider, $ProtectSecret, $UnprotectSecret,
                    $QueryProvider, $ApplyProviders, $RemoveProviderArtifacts, $ConfirmDelete
                )
                $View | Should -Be $relayManagerView
                & $WriteRelayState ([pscustomobject]@{ SchemaVersion = 2; Providers = @() }) ([pscustomobject]@{
                    Kind = 'None'; Link = $null; ProviderId = $null
                })
                $null = & $ImportProvider @()
                & $ApplyProviders @($existingRelayProvider) @($existingRelayProvider.Id) @() $false
                $calls.Add('new-relay-manager-controller') | Out-Null
                Write-Output -NoEnumerate $relayManagerController
            }.GetNewClosure()
            NewDisplay = {
                param(
                    $Settings, $FullView, $CompactBarView, $OrbView, $SaveSettings,
                    [AllowNull()][scriptblock]$OnRefreshRequested, [switch]$DeferShow
                )
                $FullView | Should -Be $windowView
                $CompactBarView | Should -Be $compactBarView
                $OrbView | Should -Be $orbView
                $refreshCallbacks.Add($OnRefreshRequested) | Out-Null
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
                    $OnManageRelays,
                    $OnOpenSettings
                )
                $refreshCallbacks.Add($RequestRefresh) | Out-Null
                $DisplayController | Should -Be $displayController
                $OnManageRelays | Should -BeOfType ([scriptblock])
                $OnOpenSettings | Should -BeOfType ([scriptblock])
                & $OnManageRelays
                Write-Output -NoEnumerate $interaction
            }.GetNewClosure()
            NewSettingsView = {
                $calls.Add('new-settings-view') | Out-Null
                Write-Output -NoEnumerate $settingsView
            }.GetNewClosure()
            NewSettingsController = {
                param(
                    $View, $GetSnapshot, $SetDisplayMode, $SetTheme, $SetFullLayout,
                    $ToggleTopmost, $ToggleStartup, $RequestRefresh, $ManageRelays
                )
                $View | Should -Be $settingsView
                $GetSnapshot | Should -BeOfType ([scriptblock])
                $SetDisplayMode | Should -BeOfType ([scriptblock])
                $SetTheme | Should -BeOfType ([scriptblock])
                $SetFullLayout | Should -BeOfType ([scriptblock])
                $ToggleTopmost | Should -BeOfType ([scriptblock])
                $ToggleStartup | Should -BeOfType ([scriptblock])
                $RequestRefresh | Should -BeOfType ([scriptblock])
                $ManageRelays | Should -BeOfType ([scriptblock])
                $settingsSnapshots.Add(
                    ((& $GetSnapshot).PSObject.Properties.Name -join ',')
                ) | Out-Null
                $calls.Add('new-settings-controller') | Out-Null
                Write-Output -NoEnumerate $settingsController
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
        $originalNewRelayScheduler = & $module { ${function:New-RelaySchedulerState} }
        $overrides['NewRelayScheduler'] = {
            param($Providers, $Now, $MaximumConcurrency)
            $scheduler = & $originalNewRelayScheduler -Providers $Providers -Now $Now `
                -MaximumConcurrency $MaximumConcurrency
            $schedulerCreations.Add([pscustomobject][ordered]@{
                EntryIntervals = [int[]]@($scheduler.Providers.IntervalMinutes)
            }) | Out-Null
            Write-Output -NoEnumerate $scheduler
        }.GetNewClosure()
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
                RunForSeconds = 2
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
                'new-relay-manager-view', 'new-cc-switch-import-view',
                'new-cc-switch-import-controller', 'show-cc-switch-import',
                'new-relay-manager-controller', 'new-display', 'show-relay-manager',
                'new-settings-view', 'new-settings-controller',
                'initialize-desktop', 'dispose-settings-controller',
                'dispose-relay-manager-controller',
                'dispose-cc-switch-import-controller', 'dispose-cc-switch-import-view'
            )
        @($calls | Where-Object { $_ -like 'snapshot:*' }).Count | Should -BeGreaterThan 0
        @($calls | Where-Object { $_ -eq 'dispose-display' }).Count | Should -Be 1
        $refreshCallbacks.Count | Should -Be 3
        $refreshCallbacks[0] | Should -BeOfType ([scriptblock])
        [object]::ReferenceEquals($refreshCallbacks[0], $refreshCallbacks[1]) | Should -BeTrue
        [object]::ReferenceEquals($refreshCallbacks[1], $refreshCallbacks[2]) | Should -BeTrue
        @($calls | Where-Object { $_ -eq 'dispose-relay-manager-view' }).Count | Should -Be 0
        $ccSwitchDiscoveries.Count | Should -Be 1
        $ccSwitchDiscoveries[0].ExecutablePath | Should -BeExactly (
            [IO.Path]::Combine($localAppData, 'CodexQuotaMonitor', 'app', 'Bin', 'relay-quota-host.exe')
        )
        $ccSwitchDiscoveries[0].DatabasePath | Should -BeExactly (
            [IO.Path]::GetFullPath([IO.Path]::Combine($env:USERPROFILE, '.cc-switch', 'cc-switch.db'))
        )
        @($ccSwitchDiscoveries[0].ParameterNames) | Should -Be @('ExecutablePath', 'DatabasePath')
        @($relayImportLinkReads) | Should -Be @(
            [IO.Path]::Combine($localAppData, 'CodexQuotaMonitor', 'data', 'relay-import-links.json')
        )
        $relayImportTransactions.Count | Should -Be 1
        $relayImportTransactions[0].ProviderPath | Should -BeExactly (
            [IO.Path]::Combine($localAppData, 'CodexQuotaMonitor', 'data', 'relay-providers.json')
        )
        $relayImportTransactions[0].LinkPath | Should -BeExactly (
            [IO.Path]::Combine($localAppData, 'CodexQuotaMonitor', 'data', 'relay-import-links.json')
        )
        $relayCacheWrites.Count | Should -Be 1
        @($relayCacheWrites[0].Providers).Count | Should -Be 0
        @($settingsSnapshots) | Should -Be @('Mode,Theme,FullLayout,Topmost,Startup')
        @($schedulerCreations).Count | Should -BeGreaterOrEqual 2
        foreach ($creation in $schedulerCreations) {
            @($creation.EntryIntervals) | Should -Be @(15)
        }
        (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).Relay.AutoQueryIntervalMinutes |
            Should -Be 7
        $result.Status | Should -BeExactly 'Live'
        $dispatcher = [Windows.Threading.Dispatcher]::CurrentDispatcher
        $dispatcher.HasShutdownStarted | Should -BeFalse
        $dispatcher.HasShutdownFinished | Should -BeFalse
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
