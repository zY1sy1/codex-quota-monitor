BeforeAll {
    $script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
    $script:HostPath = Join-Path $script:RepoRoot 'companion\Bin\relay-quota-host.exe'
    . (Join-Path $script:RepoRoot 'companion\Private\RelayScriptClient.ps1')
    . (Join-Path $script:RepoRoot 'companion\Private\RelayState.ps1')
    . (Join-Path $script:RepoRoot 'companion\Private\RelayCache.ps1')
    . (Join-Path $script:RepoRoot 'companion\Private\Settings.ps1')
    . (Join-Path $PSScriptRoot '..\Fixtures\FakeRelayApi.ps1')

    $script:Apis = [Collections.Generic.List[object]]::new()
    $script:Clients = [Collections.Generic.List[object]]::new()
    $script:FakeSecret = 'fixture-credential'

    function Get-Preset {
        param([Parameter(Mandatory)][string]$Id)
        $presetPath = Join-Path $script:RepoRoot 'companion\Presets\relay-usage.json'
        $document = Get-Content -LiteralPath $presetPath -Raw | ConvertFrom-Json
        return @($document.Presets | Where-Object Id -eq $Id)[0]
    }

    function New-EndToEndProvider {
        param(
            [Parameter(Mandatory)][string]$Id,
            [Parameter(Mandatory)][string]$BaseUrl,
            [string]$Path = '/user/balance',
            [string]$ProviderKind = 'Generic',
            [string]$Method = 'GET',
            [AllowNull()][object]$Query = $null,
            [AllowNull()][object]$Headers = $null,
            [AllowNull()][string]$Body = $null,
            [AllowNull()][string]$ExtractorScript = $null,
            [int]$TimeoutSeconds = 2
        )
        if ($null -eq $Query) { $Query = [ordered]@{} }
        if ($null -eq $Headers) { $Headers = [ordered]@{} }
        $preset = switch ($Id) {
            'wakaka' { Get-Preset -Id 'wakaka' }
            'general' { Get-Preset -Id 'general' }
            'new-api' { Get-Preset -Id 'new-api' }
            default { $null }
        }
        if ($null -ne $preset) {
            $ProviderKind = [string]$preset.ProviderKind
            $request = $preset.RequestDefinition
            $Method = [string]$request.Method
            $Path = [string]$request.Path
            $Query = $request.Query
            $Headers = $request.Headers
            $Body = $request.Body
            $ExtractorScript = [string]$preset.ExtractorScript
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$ExtractorScript)) {
            $ExtractorScript = @"
function(response){const data=response.data??response;return {isValid:response.success??true,invalidMessage:response.message??null,remaining:data.balance??data.quota,unit:data.currency??"USD",planName:data.planName??null};}
"@
        }
        [pscustomobject][ordered]@{
            Id = $Id
            Name = $Id
            Enabled = $true
            ProviderKind = $ProviderKind
            BaseUrl = $BaseUrl
            RequestDefinition = if ($ProviderKind -eq 'Generic') {
                [pscustomobject][ordered]@{
                    Method = $Method; Path = $Path; Query = [pscustomobject]$Query
                    Headers = [pscustomobject]$Headers; Body = $Body
                }
            } else { $null }
            ExtractorScript = $ExtractorScript
            TimeoutSeconds = $TimeoutSeconds
            IntervalMinutes = 10
            TrustedDestination = $BaseUrl
        }
    }

    function Invoke-EndToEndQuery {
        param(
            [Parameter(Mandatory)][object]$Api,
            [Parameter(Mandatory)][object]$Provider,
            [switch]$UseCredential,
            [AllowNull()][hashtable]$Secrets
        )
        $client = Start-RelayScriptClient -ExecutablePath $script:HostPath -ArgumentList @()
        $script:Clients.Add($client)
        $secrets = if ($null -ne $Secrets) {
            $Secrets
        }
        elseif ($UseCredential) {
            @{ ApiKey = $script:FakeSecret; AccessToken = ''; UserId = '' }
        }
        else {
            @{}
        }
        return Invoke-RelayScriptQuery -Client $client -Provider $Provider -Secrets $secrets
    }

    function Get-RelayStateFromSuccess {
        param([Parameter(Mandatory)][string]$ProviderId, [Parameter(Mandatory)][object]$Response)
        $state = New-RelayProviderState -ProviderId $ProviderId -Enabled $true
        return Complete-RelayProviderSuccess -State $state -Results $Response.Results -Now ([DateTimeOffset]::UtcNow)
    }
}

Describe 'relay end-to-end fake API' {
    AfterEach {
        foreach ($client in @($script:Clients)) {
            Stop-RelayScriptClient -Client $client -TimeoutMilliseconds 500
        }
        $script:Clients.Clear()
        foreach ($api in @($script:Apis)) {
            Stop-FakeRelayApi -Api $api
        }
        $script:Apis.Clear()
    }

    It 'queries Wakaka, General, New API, and rate-limit loopback endpoints' {
        $api = Start-FakeRelayApi -Scenario 'Happy'
        $script:Apis.Add($api)
        $providers = @(
            New-EndToEndProvider -Id 'wakaka' -BaseUrl $api.BaseUrl
            New-EndToEndProvider -Id 'general' -BaseUrl $api.BaseUrl
            New-EndToEndProvider -Id 'new-api' -BaseUrl $api.BaseUrl
            New-EndToEndProvider -Id 'rate-limit' -BaseUrl $api.BaseUrl -Path '/rate-limit'
        )

        $results = foreach ($provider in $providers) {
            Invoke-EndToEndQuery -Api $api -Provider $provider -UseCredential
        }

        @($results | Where-Object Ok -ne $true).Count | Should -Be 0 `
            -Because (($results | ConvertTo-Json -Depth 8 -Compress))
        @($results[0].Results).Count | Should -Be 2
        $results[1].Results[0].Remaining | Should -Be 42
        $results[2].Results[0].Remaining | Should -Be 7
        $results[3].Results[0].Remaining | Should -Be 3
        $results.Meta.DestinationHost | Should -Not -Match 'credential'
        $api.Stats.TotalRequests | Should -Be 4
    }

    It 'queries a Generic GET provider on an arbitrary loopback path' {
        $api = Start-FakeRelayApi -Scenario 'Happy'
        $script:Apis.Add($api)
        $provider = New-EndToEndProvider -Id 'generic-get' -BaseUrl $api.BaseUrl -Path '/generic/get' `
            -Headers @{ 'X-Api-Key' = '{{apiKey}}' } `
            -ExtractorScript 'function(response){return {isValid:true,remaining:response.balance,unit:"USD"};}'

        $result = Invoke-EndToEndQuery -Api $api -Provider $provider -Secrets @{ ApiKey = 'get-secret'; AccessToken = ''; UserId = '' }

        $result.Ok | Should -BeTrue
        $result.Results[0].Remaining | Should -Be 42
        $api.LastRequest.Path | Should -BeExactly '/generic/get'
        $api.LastRequest.Method | Should -BeExactly 'GET'
        $api.LastRequest.HasApiKey | Should -BeTrue
    }

    It 'queries a Generic POST provider with body and header authentication' {
        $api = Start-FakeRelayApi -Scenario 'Happy'
        $script:Apis.Add($api)
        $provider = New-EndToEndProvider -Id 'generic-post' -BaseUrl $api.BaseUrl -Method 'POST' -Path '/generic/post' `
            -Headers @{ 'X-Api-Key' = '{{apiKey}}' } -Body '{"user":"{{userId}}"}' `
            -ExtractorScript 'function(response){return {isValid:true,remaining:response.balance,planName:response.planName};}'

        $result = Invoke-EndToEndQuery -Api $api -Provider $provider -Secrets @{
            ApiKey = 'post-secret'; AccessToken = ''; UserId = 'user-7'
        }

        $result.Ok | Should -BeTrue
        $result.Results[0].PlanName | Should -BeExactly 'Generic POST'
        $api.LastRequest.Method | Should -BeExactly 'POST'
        $api.LastRequest.Path | Should -BeExactly '/generic/post'
        $api.LastRequest.HasApiKey | Should -BeTrue
        $api.LastRequest.BodyHasUserId | Should -BeTrue
        ($api.LastRequest | ConvertTo-Json -Depth 8 -Compress) | Should -Not -Match 'post-secret|user-7'
    }

    It 'preserves an explicit zero through the real sidecar' {
        $api = Start-FakeRelayApi -Scenario 'Zero'
        $script:Apis.Add($api)
        $provider = New-EndToEndProvider -Id 'zero' -BaseUrl $api.BaseUrl -Path '/v1/usage'

        $result = Invoke-EndToEndQuery -Api $api -Provider $provider

        $result.Ok | Should -BeTrue
        $result.Results[0].Remaining | Should -Be 0
        $state = Get-RelayStateFromSuccess -ProviderId 'zero' -Response $result
        $state.Results[0].Remaining | Should -Be 0
    }

    It 'maps HTTP 429 and Retry-After without exposing response data' {
        $api = Start-FakeRelayApi -Scenario 'RateLimited'
        $script:Apis.Add($api)
        $provider = New-EndToEndProvider -Id 'rate-limit' -BaseUrl $api.BaseUrl -Path '/rate-limit'

        $result = Invoke-EndToEndQuery -Api $api -Provider $provider

        $result.Ok | Should -BeFalse
        $result.Error.Category | Should -BeExactly 'HttpStatus'
        $result.Error.HttpStatus | Should -Be 429
        $result.Error.RetryAfterSeconds | Should -Be 4
        ($result | ConvertTo-Json -Depth 8 -Compress) | Should -Not -Match 'credential|response|header'
    }

    It 'maps invalid JSON and a slow route to sanitized categories' {
        $invalidApi = Start-FakeRelayApi -Scenario 'InvalidJson'
        $script:Apis.Add($invalidApi)
        $invalidProvider = New-EndToEndProvider -Id 'invalid-json' -BaseUrl $invalidApi.BaseUrl -Path '/invalid-json'
        $invalid = Invoke-EndToEndQuery -Api $invalidApi -Provider $invalidProvider

        $slowApi = Start-FakeRelayApi -Scenario 'Slow'
        $script:Apis.Add($slowApi)
        $slowProvider = New-EndToEndProvider -Id 'slow' -BaseUrl $slowApi.BaseUrl -Path '/slow' -TimeoutSeconds 2
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $slow = Invoke-EndToEndQuery -Api $slowApi -Provider $slowProvider
        $watch.Stop()

        $invalid.Ok | Should -BeFalse
        $invalid.Error.Category | Should -BeExactly 'InvalidJson'
        $slow.Ok | Should -BeFalse
        $slow.Error.Category | Should -BeExactly 'Timeout'
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 6
    }

    It 'keeps a last-good cache stale after the loopback API becomes unavailable' {
        $api = Start-FakeRelayApi -Scenario 'Happy'
        $script:Apis.Add($api)
        $provider = New-EndToEndProvider -Id 'cached' -BaseUrl $api.BaseUrl -Path '/user/balance'
        $live = Invoke-EndToEndQuery -Api $api -Provider $provider
        $live.Ok | Should -BeTrue
        $state = Get-RelayStateFromSuccess -ProviderId 'cached' -Response $live
        $cachePath = Join-Path $TestDrive 'relay-cache.json'
        Write-RelayCache -Path $cachePath -Cache ([pscustomobject][ordered]@{
                SchemaVersion = 1
                Providers = @([pscustomobject][ordered]@{
                        ProviderId = 'cached'
                        UpdatedAt = $state.LastSuccessAt.ToUniversalTime().ToString('o')
                        Results = $state.Results
                    })
            })

        Stop-FakeRelayApi -Api $api
        $script:Apis.Remove($api)
        $failed = Invoke-EndToEndQuery -Api $api -Provider $provider
        $stale = Complete-RelayProviderFailure -State $state -Category 'Connectivity' -Now ([DateTimeOffset]::UtcNow)
        $roundTrip = Read-RelayCache -Path $cachePath

        $failed.Ok | Should -BeFalse
        $stale.Status | Should -BeExactly 'Stale'
        $stale.Results[0].Remaining | Should -Be 42
        $roundTrip.Providers[0].Results[0].Remaining | Should -Be 42
    }

    It 'keeps official quota live when relay auth fails and exits both children cleanly' {
        $api = Start-FakeRelayApi -Scenario 'Auth'
        $script:Apis.Add($api)
        $module = Import-Module (Join-Path $script:RepoRoot 'companion\CodexQuotaMonitor.psd1') -Force -PassThru
        $clients = [Collections.Generic.List[object]]::new()
        $clientIds = [Collections.Generic.List[int]]::new()
        $hostPath = $script:HostPath
        $startRelayScriptClient = ${function:Start-RelayScriptClient}
        $provider = New-EndToEndProvider -Id 'auth' -BaseUrl $api.BaseUrl -Path '/auth'
        $provider | Add-Member -MemberType NoteProperty -Name Secrets -Value ([pscustomobject]@{
                ApiKey = 'stored'; AccessToken = ''; UserId = ''
            })
        $providerDocument = [pscustomobject]@{ SchemaVersion = 2; Providers = @($provider) }
        $overrides = [ordered]@{
            ReadRelayProviders = { param($Path) $providerDocument }.GetNewClosure()
            ReadRelayCache = { param($Path) [pscustomobject]@{ SchemaVersion = 1; Providers = @() } }.GetNewClosure()
            UnprotectRelaySecret = { param($CipherText) '' }.GetNewClosure()
            StartRelayClient = {
                param($ExecutablePath, $ArgumentList, $WorkingDirectory)
                $client = & $startRelayScriptClient -ExecutablePath $hostPath -ArgumentList @()
                $clients.Add($client)
                $clientIds.Add([int]$client.Process.Id)
                return $client
            }.GetNewClosure()
        }
        try {
            $result = & $module {
                param($Arguments)
                Invoke-CodexQuotaMonitorRuntime @Arguments
            } @{
                Headless = $true
                AppServerExecutable = (Get-Process -Id $PID).Path
                AppServerArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $script:RepoRoot 'tests\Fixtures\FakeAppServer.ps1'), '-Scenario', 'Happy')
                LocalAppData = (Join-Path $TestDrive 'runtime')
                Startup = (Join-Path $TestDrive 'startup')
                InstancePrefix = 'Local\RelayE2E.' + [guid]::NewGuid().ToString('N')
                RunForSeconds = 3
                TickMilliseconds = 50
                PassThru = $true
                FunctionOverrides = $overrides
            }
        }
        finally {
            Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
        }

        $result.Status | Should -BeExactly 'Live'
        @($result.QuotaWindows).Count | Should -Be 2
        $result.RelayStates[0].Status | Should -BeExactly 'AuthRequired' `
            -Because (($result | ConvertTo-Json -Depth 10 -Compress))
        @($clients | Where-Object { $_.Disposed }).Count | Should -Be 1
        @($clients | Where-Object Disposed).Count | Should -Be 1
        @($clientIds | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) }).Count |
            Should -Be 0
    }

    It 'never exceeds two in-flight fake API requests' {
        $api = Start-FakeRelayApi -Scenario 'Slow' -DelayMilliseconds 500
        $script:Apis.Add($api)
        $provider = New-EndToEndProvider -Id 'slow-concurrency' -BaseUrl $api.BaseUrl -Path '/slow' -TimeoutSeconds 5
        $client = Start-RelayScriptClient -ExecutablePath $script:HostPath -ArgumentList @()
        $script:Clients.Add($client)

        foreach ($index in 1..4) {
            $result = Invoke-RelayScriptQuery -Client $client -Provider $provider -Secrets @{}
            $result.Ok | Should -BeTrue
        }
        $api.Stats.MaxConcurrent | Should -BeLessOrEqual 2
    }
}
