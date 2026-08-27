BeforeAll {
    $script:CompanionRoot = Join-Path $PSScriptRoot '..\..\companion'
    $script:ManifestPath = Join-Path $script:CompanionRoot 'CodexQuotaMonitor.psd1'
    $script:FakeServerPath = Join-Path $PSScriptRoot '..\Fixtures\FakeAppServer.ps1'
    $script:PwshPath = (Get-Process -Id $PID).Path

    function New-TestRuntimeRelayProvider {
        param(
            [string]$Id,
            [int]$IntervalMinutes = 10,
            [bool]$Enabled = $true
        )
        [pscustomobject][ordered]@{
            Id = $Id
            Name = "Relay $Id"
            Enabled = $Enabled
            BaseUrl = 'https://fixture.invalid'
            ProviderKind = 'Generic'
            RequestDefinition = [pscustomobject][ordered]@{
                Method = 'GET'; Path = '/usage'; Query = [pscustomobject][ordered]@{}
                Headers = [pscustomobject][ordered]@{}; Body = $null
            }
            ExtractorScript = 'function(response){return {remaining:response.balance};}'
            TimeoutSeconds = 2
            IntervalMinutes = $IntervalMinutes
            TrustedDestination = 'https://fixture.invalid:443'
            Secrets = [pscustomobject]@{
                ApiKey = "encrypted-$Id"
                AccessToken = ''
                UserId = ''
            }
        }
    }

    function New-TestRuntimeRelayResult {
        param(
            [double]$Remaining,
            [AllowNull()][object]$Total = ([double]100),
            [string]$PlanName = 'Fixture'
        )
        [pscustomobject][ordered]@{
            IsValid = $true
            InvalidMessage = $null
            Remaining = $Remaining
            Unit = 'USD'
            PlanName = $PlanName
            Total = $Total
            Used = $null
            Extra = $null
        }
    }

    function New-TestRuntimeCache {
        param(
            [AllowNull()][string]$ProviderId = $null,
            [AllowNull()][object[]]$Results = $null
        )
        $providers = if ($null -eq $ProviderId) {
            @()
        }
        else {
            @([pscustomobject][ordered]@{
                ProviderId = $ProviderId
                UpdatedAt = '2026-08-01T08:00:00.0000000+00:00'
                Results = [object[]]$Results
            })
        }
        [pscustomobject][ordered]@{
            SchemaVersion = 2
            Providers = [object[]]$providers
        }
    }

    function Invoke-TestRelayRuntime {
        param(
            [object[]]$Providers,
            [object]$Cache,
            [hashtable]$Responses,
            [int]$RunForSeconds = 2,
            [switch]$FailRelayStart,
            [switch]$RequestManualRefresh,
            [AllowNull()][string]$FailUnprotectProvider = $null,
            [AllowNull()][string]$CrashRelayQueryProvider = $null,
            [switch]$ThrowRelayStop,
            [string]$AppServerScenario = 'RuntimeHappy'
        )
        $localAppData = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $startup = Join-Path $TestDrive ('Startup-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $startup -Force | Out-Null
        $instancePrefix = 'Local\CodexQuotaMonitor.RelayRuntime.' + [guid]::NewGuid().ToString('N')
        $cacheWrites = [Collections.Generic.List[object]]::new()
        $queryCalls = [Collections.Generic.List[string]]::new()
        $startCalls = [Collections.Generic.List[string]]::new()
        $officialRefreshCalls = [Collections.Generic.List[string]]::new()
        $lifecycleCalls = [Collections.Generic.List[string]]::new()
        $crashedQueryProviders = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        $providerDocument = [pscustomobject]@{
            SchemaVersion = 1
            Providers = [object[]]$Providers
        }
        $module = Import-Module -Name $script:ManifestPath -Force -PassThru
        $originalStopProcess = & $module { ${function:Stop-AppServerProcess} }
        $overrides = [ordered]@{
            ReadRelayProviders = { param($Path) $providerDocument }.GetNewClosure()
            ReadRelayCache = { param($Path) $Cache }.GetNewClosure()
            WriteRelayCache = {
                param($Path, $Cache)
                $cacheWrites.Add($Cache) | Out-Null
            }.GetNewClosure()
            UnprotectRelaySecret = {
                param($CipherText)
                if ([string]::IsNullOrEmpty($CipherText)) { return '' }
                if (-not [string]::IsNullOrEmpty($FailUnprotectProvider) -and
                    $CipherText -eq "encrypted-$FailUnprotectProvider") {
                    throw [Security.Cryptography.CryptographicException]::new('private DPAPI detail')
                }
                return 'RUNTIME_RELAY_SECRET_SENTINEL'
            }.GetNewClosure()
            StartRelayClient = {
                param($ExecutablePath, $ArgumentList, $WorkingDirectory)
                $startCalls.Add('start') | Out-Null
                if ($FailRelayStart) {
                    throw [InvalidOperationException]::new('private startup detail')
                }
                [pscustomobject]@{
                    Process = [pscustomobject]@{ HasExited = $false }
                    Disposed = $false
                }
            }.GetNewClosure()
            StopRelayClient = {
                param($Client, $TimeoutMilliseconds)
                $lifecycleCalls.Add('relay-stop') | Out-Null
                if ($null -ne $Client) { $Client.Disposed = $true }
                if ($ThrowRelayStop) {
                    throw [InvalidOperationException]::new('private relay stop detail')
                }
            }.GetNewClosure()
            QueryRelay = {
                param($Client, $Provider, $Secrets)
                $providerId = [string]$Provider.Id
                $queryCalls.Add($providerId) | Out-Null
                if ($providerId -eq $CrashRelayQueryProvider -and
                    $crashedQueryProviders.Add($providerId)) {
                    throw [IO.IOException]::new('private sidecar crash detail')
                }
                return $Responses[$providerId]
            }.GetNewClosure()
            StopProcess = {
                param($Transport, $TimeoutMilliseconds)
                $lifecycleCalls.Add('official-stop') | Out-Null
                & $originalStopProcess -Transport $Transport `
                    -TimeoutMilliseconds $TimeoutMilliseconds
            }.GetNewClosure()
        }
        if ($RequestManualRefresh) {
            $overrides['UpdateNotification'] = {
                param($State, $Method, $Now)
                $officialRefreshCalls.Add([string]$Method) | Out-Null
                return @()
            }.GetNewClosure()
        }
        try {
            $arguments = @{
                Headless = $true
                AppServerExecutable = $script:PwshPath
                AppServerArguments = @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:FakeServerPath,
                    '-Scenario', $AppServerScenario
                )
                LocalAppData = $localAppData
                Startup = $startup
                InstancePrefix = $instancePrefix
                RunForSeconds = $RunForSeconds
                TickMilliseconds = 50
                PassThru = $true
                FunctionOverrides = $overrides
                RequestRefreshWhenReady = [bool]$RequestManualRefresh
            }
            $result = & $module {
                param([hashtable]$RuntimeArguments)
                Invoke-CodexQuotaMonitorRuntime @RuntimeArguments
            } $arguments
        }
        finally {
            Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
        }
        [pscustomobject]@{
            Result = $result
            CacheWrites = @($cacheWrites)
            QueryCalls = @($queryCalls)
            StartCalls = @($startCalls)
            OfficialRefreshCalls = @($officialRefreshCalls)
            LifecycleCalls = @($lifecycleCalls)
            HealthPath = Join-Path $localAppData 'CodexQuotaMonitor\data\health.json'
        }
    }
}

Describe 'relay runtime composition' {
    It 'keeps official quota live when every relay query fails' {
        $providers = @(
            New-TestRuntimeRelayProvider 'one'
            New-TestRuntimeRelayProvider 'two'
        )
        $failure = [pscustomobject]@{
            Id = 'ignored'
            Ok = $false
            Error = [pscustomobject]@{
                Category = 'Connectivity'
                Message = 'Relay request failed.'
                HttpStatus = $null
                RetryAfterSeconds = $null
            }
        }

        $run = Invoke-TestRelayRuntime -Providers $providers -Cache (New-TestRuntimeCache) `
            -Responses @{ one = $failure; two = $failure }

        $run.Result.Status | Should -BeExactly 'Live'
        @($run.Result.QuotaWindows).Count | Should -Be 2
        @($run.Result.RelayStates | Where-Object Status -eq 'Unavailable').Count | Should -Be 2 `
            -Because "actual states: $(@($run.Result.RelayStates.Status) -join ', ')"
        @($run.CacheWrites).Count | Should -Be 0
        @($run.QueryCalls | Sort-Object) | Should -Be @('one', 'two')
    }

    It 'preserves precise relay failure categories instead of collapsing script failures' {
        $providers = @(
            New-TestRuntimeRelayProvider 'not-found'
            New-TestRuntimeRelayProvider 'rate-limit'
            New-TestRuntimeRelayProvider 'syntax'
            New-TestRuntimeRelayProvider 'extractor'
        )
        $responses = @{
            'not-found' = [pscustomobject]@{
                Ok = $false
                Error = [pscustomobject]@{
                    Category = 'HttpStatus'; Message = 'Relay returned an error.'
                    HttpStatus = 404; RetryAfterSeconds = $null
                }
            }
            'rate-limit' = [pscustomobject]@{
                Ok = $false
                Error = [pscustomobject]@{
                    Category = 'HttpStatus'; Message = 'Relay returned an error.'
                    HttpStatus = 429; RetryAfterSeconds = 60
                }
            }
            syntax = [pscustomobject]@{
                Ok = $false
                Error = [pscustomobject]@{
                    Category = 'ScriptSyntax'; Message = 'Relay script failed.'
                    HttpStatus = $null; RetryAfterSeconds = $null
                }
            }
            extractor = [pscustomobject]@{
                Ok = $false
                Error = [pscustomobject]@{
                    Category = 'ExtractorExecution'; Message = 'Relay script failed.'
                    HttpStatus = $null; RetryAfterSeconds = $null
                }
            }
        }

        $run = Invoke-TestRelayRuntime -Providers $providers -Cache (New-TestRuntimeCache) `
            -Responses $responses
        $states = @{}
        foreach ($state in @($run.Result.RelayStates)) { $states[$state.ProviderId] = $state }

        $states['not-found'].LastErrorCategory | Should -BeExactly 'EndpointNotFound'
        $states['rate-limit'].LastErrorCategory | Should -BeExactly 'RateLimit'
        $states.syntax.LastErrorCategory | Should -BeExactly 'ScriptSyntax'
        $states.extractor.LastErrorCategory | Should -BeExactly 'ExtractorExecution'
    }

    It 'keeps one relay stale while another is live and writes cache only for success' {
        $providers = @(
            New-TestRuntimeRelayProvider 'stale'
            New-TestRuntimeRelayProvider 'live'
        )
        $cachedResult = New-TestRuntimeRelayResult -Remaining 9 -PlanName 'Cached'
        $cache = New-TestRuntimeCache -ProviderId 'stale' -Results @($cachedResult)
        $networkFailure = [pscustomobject]@{
            Id = 'ignored'
            Ok = $false
            Error = [pscustomobject]@{
                Category = 'Connectivity'
                Message = 'Relay request failed.'
                HttpStatus = $null
                RetryAfterSeconds = $null
            }
        }
        $success = [pscustomobject]@{
            Id = 'ignored'
            Ok = $true
            Results = @((New-TestRuntimeRelayResult -Remaining 20 -PlanName 'Live'))
            Meta = [pscustomobject]@{ HttpStatus = 200; DestinationHost = 'fixture.invalid'; DurationMs = 1 }
        }

        $run = Invoke-TestRelayRuntime -Providers $providers -Cache $cache `
            -Responses @{ stale = $networkFailure; live = $success }
        $healthText = Get-Content -LiteralPath $run.HealthPath -Raw
        $health = $healthText | ConvertFrom-Json

        $run.Result.Status | Should -BeExactly 'Live'
        @($run.Result.RelayStates | Where-Object Status -eq 'Stale').Count | Should -Be 1
        @($run.Result.RelayStates | Where-Object Status -eq 'Live').Count | Should -Be 1
        @($run.CacheWrites).Count | Should -Be 1
        $health.SchemaVersion | Should -Be 2
        $health.RelayProviderCount | Should -Be 2
        $health.RelayLiveCount | Should -Be 1
        $health.RelayStaleCount | Should -Be 1
        $health.RelayInvalidCount | Should -Be 0
        $health.RelayHostState | Should -BeExactly 'Live'
        $health.DisplayMode | Should -BeExactly 'Full'
        $health.Theme | Should -BeExactly 'Dark'
        $healthText | Should -Not -Match 'token|authorization|cookie|secret|password|api.?key'
    }

    It 'marks only relay hosting unavailable after three startup failures' {
        $providers = @((New-TestRuntimeRelayProvider 'one'))

        $run = Invoke-TestRelayRuntime -Providers $providers -Cache (New-TestRuntimeCache) `
            -Responses @{} -FailRelayStart -RunForSeconds 3
        $health = Get-Content -LiteralPath $run.HealthPath -Raw | ConvertFrom-Json

        $run.Result.Status | Should -BeExactly 'Live'
        @($run.StartCalls).Count | Should -BeGreaterOrEqual 3
        $run.Result.RelayHostState | Should -BeExactly 'Unavailable'
        $health.RelayHostState | Should -BeExactly 'Unavailable'
        @($run.Result.RelayStates.Status) | Should -Be @('Starting')
    }

    It 'preserves cached provider state metadata across three relay host startup failures' {
        $provider = New-TestRuntimeRelayProvider 'cached'
        $cachedResult = New-TestRuntimeRelayResult -Remaining 9 -PlanName 'Cached'
        $cache = New-TestRuntimeCache -ProviderId 'cached' -Results @($cachedResult)

        $run = Invoke-TestRelayRuntime -Providers @($provider) -Cache $cache `
            -Responses @{} -FailRelayStart -RunForSeconds 3
        $state = @($run.Result.RelayStates)[0]

        $run.Result.RelayHostState | Should -BeExactly 'Unavailable'
        $state.Status | Should -BeExactly 'Stale'
        $state.Results[0].Remaining | Should -Be 9
        $state.LastErrorCategory | Should -BeNullOrEmpty
        $state.ConsecutiveFailures | Should -Be 0
        $state.LastAttemptAt | Should -BeNullOrEmpty
    }

    It 'manual refresh requests official quota and every enabled interval-zero relay beyond one scheduler batch' {
        $providers = @(
            New-TestRuntimeRelayProvider 'one' -IntervalMinutes 0
            New-TestRuntimeRelayProvider 'two' -IntervalMinutes 0
            New-TestRuntimeRelayProvider 'three' -IntervalMinutes 0
            New-TestRuntimeRelayProvider 'four' -IntervalMinutes 0
            New-TestRuntimeRelayProvider 'five' -IntervalMinutes 0
        )
        $success = [pscustomobject]@{
            Id = 'ignored'
            Ok = $true
            Results = @((New-TestRuntimeRelayResult -Remaining 50))
            Meta = [pscustomobject]@{ HttpStatus = 200; DestinationHost = 'fixture.invalid'; DurationMs = 1 }
        }

        $run = Invoke-TestRelayRuntime -Providers $providers -Cache (New-TestRuntimeCache) `
            -Responses @{
                one = $success; two = $success; three = $success; four = $success; five = $success
            } -RequestManualRefresh

        @($run.QueryCalls | Sort-Object) | Should -Be @('five', 'four', 'one', 'three', 'two')
        @($run.OfficialRefreshCalls | Where-Object { $_ -eq 'account/rateLimits/updated' }).Count |
            Should -BeGreaterOrEqual 1
    }

    It 'releases every unexecuted scheduler action after the first query crashes and later runs them' {
        $providers = @(
            New-TestRuntimeRelayProvider 'crash'
            New-TestRuntimeRelayProvider 'second'
            New-TestRuntimeRelayProvider 'third'
        )
        $success = [pscustomobject]@{
            Id = 'ignored'
            Ok = $true
            Results = @((New-TestRuntimeRelayResult -Remaining 50))
            Meta = [pscustomobject]@{ HttpStatus = 200; DestinationHost = 'fixture.invalid'; DurationMs = 1 }
        }

        $run = Invoke-TestRelayRuntime -Providers $providers -Cache (New-TestRuntimeCache) `
            -Responses @{ crash = $success; second = $success; third = $success } `
            -CrashRelayQueryProvider 'crash' -RunForSeconds 3

        @($run.QueryCalls | Sort-Object) | Should -Be @('crash', 'second', 'third')
        @($run.Result.RelayStates | Where-Object Status -eq 'Live').Count | Should -Be 2
        @($run.StartCalls).Count | Should -BeGreaterOrEqual 2
    }

    It 'does not cache an all-invalid result and pauses that provider after one attempt' {
        $provider = New-TestRuntimeRelayProvider 'invalid'
        $invalidResult = New-TestRuntimeRelayResult -Remaining 0
        $invalidResult.IsValid = $false
        $invalidResult.InvalidMessage = 'account invalid'
        $invalidResult.Remaining = $null
        $response = [pscustomobject]@{
            Id = 'ignored'
            Ok = $true
            Results = @($invalidResult)
            Meta = [pscustomobject]@{ HttpStatus = 200; DestinationHost = 'fixture.invalid'; DurationMs = 1 }
        }

        $run = Invoke-TestRelayRuntime -Providers @($provider) -Cache (New-TestRuntimeCache) `
            -Responses @{ invalid = $response }

        @($run.QueryCalls) | Should -Be @('invalid')
        @($run.CacheWrites).Count | Should -Be 0
        @($run.Result.RelayStates.Status) | Should -Be @('AuthRequired')
    }

    It 'does not start the relay sidecar when no provider is enabled' {
        $provider = New-TestRuntimeRelayProvider 'disabled' -Enabled $false

        $run = Invoke-TestRelayRuntime -Providers @($provider) -Cache (New-TestRuntimeCache) `
            -Responses @{}

        @($run.StartCalls).Count | Should -Be 0
        @($run.QueryCalls).Count | Should -Be 0
        $run.Result.RelayHostState | Should -BeExactly 'Disabled'
        @($run.Result.RelayStates.Status) | Should -Be @('Disabled')
    }

    It 'does not stop the official App Server when a relay query crashes' {
        $provider = New-TestRuntimeRelayProvider 'crash' -IntervalMinutes 0
        $success = [pscustomobject]@{
            Id = 'ignored'
            Ok = $true
            Results = @((New-TestRuntimeRelayResult -Remaining 50))
            Meta = [pscustomobject]@{ HttpStatus = 200; DestinationHost = 'fixture.invalid'; DurationMs = 1 }
        }

        $run = Invoke-TestRelayRuntime -Providers @($provider) -Cache (New-TestRuntimeCache) `
            -Responses @{ crash = $success } -CrashRelayQueryProvider 'crash' `
            -RequestManualRefresh -RunForSeconds 2

        $run.Result.Status | Should -BeExactly 'Live'
        @($run.LifecycleCalls | Where-Object { $_ -eq 'official-stop' }).Count | Should -Be 1
        $run.LifecycleCalls[-1] | Should -BeExactly 'official-stop'
    }

    It 'continues official cleanup when stopping the relay client throws' {
        $provider = New-TestRuntimeRelayProvider 'live'
        $success = [pscustomobject]@{
            Id = 'ignored'
            Ok = $true
            Results = @((New-TestRuntimeRelayResult -Remaining 50))
            Meta = [pscustomobject]@{ HttpStatus = 200; DestinationHost = 'fixture.invalid'; DurationMs = 1 }
        }

        $run = Invoke-TestRelayRuntime -Providers @($provider) -Cache (New-TestRuntimeCache) `
            -Responses @{ live = $success } -ThrowRelayStop

        @($run.LifecycleCalls | Where-Object { $_ -eq 'relay-stop' }).Count | Should -Be 1
        @($run.LifecycleCalls | Where-Object { $_ -eq 'official-stop' }).Count | Should -Be 1
        $run.LifecycleCalls | Should -Be @('relay-stop', 'official-stop')
    }

    It 'isolates an unreadable credential to one provider without restarting the relay host' {
        $providers = @(
            New-TestRuntimeRelayProvider 'broken'
            New-TestRuntimeRelayProvider 'live'
        )
        $success = [pscustomobject]@{
            Id = 'ignored'
            Ok = $true
            Results = @((New-TestRuntimeRelayResult -Remaining 50))
            Meta = [pscustomobject]@{ HttpStatus = 200; DestinationHost = 'fixture.invalid'; DurationMs = 1 }
        }

        $run = Invoke-TestRelayRuntime -Providers $providers -Cache (New-TestRuntimeCache) `
            -Responses @{ live = $success } -FailUnprotectProvider 'broken'

        @($run.Result.RelayStates | Where-Object Status -eq 'AuthRequired').Count | Should -Be 1
        @($run.Result.RelayStates | Where-Object Status -eq 'Live').Count | Should -Be 1
        @($run.QueryCalls) | Should -Be @('live')
        @($run.StartCalls).Count | Should -Be 1
        $run.Result.RelayHostState | Should -BeExactly 'Live'
    }

    It 'keeps relay data live while the official App Server reconnects' {
        $provider = New-TestRuntimeRelayProvider 'live'
        $success = [pscustomobject]@{
            Id = 'ignored'
            Ok = $true
            Results = @((New-TestRuntimeRelayResult -Remaining 60))
            Meta = [pscustomobject]@{ HttpStatus = 200; DestinationHost = 'fixture.invalid'; DurationMs = 1 }
        }

        $run = Invoke-TestRelayRuntime -Providers @($provider) -Cache (New-TestRuntimeCache) `
            -Responses @{ live = $success } -AppServerScenario 'RuntimeInitializeError'

        $run.Result.Status | Should -BeExactly 'Reconnecting'
        @($run.Result.RelayStates | Where-Object Status -eq 'Live').Count | Should -Be 1
        $run.Result.RelayHostState | Should -BeExactly 'Live'
        @($run.StartCalls).Count | Should -Be 1
    }
}
