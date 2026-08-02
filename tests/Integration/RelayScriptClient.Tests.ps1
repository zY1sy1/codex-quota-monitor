BeforeAll {
    $clientScript = "$PSScriptRoot\..\..\companion\Private\RelayScriptClient.ps1"
    if (Test-Path -LiteralPath $clientScript -PathType Leaf) {
        . $clientScript
    }
    $script:PwshPath = (Get-Process -Id $PID).Path
    $script:FakeHost = "$PSScriptRoot\..\Fixtures\FakeRelayQuotaHost.ps1"
    $script:Clients = [Collections.Generic.List[object]]::new()

    function New-TestRelayProvider {
        param(
            [string]$Script = 'echo-success',
            [int]$TimeoutSeconds = 2
        )
        [pscustomobject][ordered]@{
            Id = 'fixture-provider'
            Name = 'Fixture'
            Enabled = $true
            BaseUrl = 'https://fixture.invalid'
            TemplateType = 'General'
            Script = $Script
            TimeoutSeconds = $TimeoutSeconds
            IntervalMinutes = 10
            TrustedDestination = $null
        }
    }

    function Start-TestRelayClient {
        param(
            [string[]]$ExtraArguments = @(),
            [int]$StderrRecordLimit = 8
        )
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:FakeHost) + $ExtraArguments
        $client = Start-RelayScriptClient -ExecutablePath $script:PwshPath -ArgumentList $arguments -StderrRecordLimit $StderrRecordLimit
        $script:Clients.Add($client)
        return $client
    }
}

Describe 'relay script host JSONL client' {
    AfterEach {
        foreach ($client in @($script:Clients)) {
            Stop-RelayScriptClient -Client $client -TimeoutMilliseconds 300
        }
        $script:Clients.Clear()
    }

    It 'starts once with redirected UTF-8 streams and no secret arguments or environment values' {
        $secret = 'SECRET_SENTINEL_81273'
        $client = Start-TestRelayClient

        $result = Invoke-RelayScriptQuery -Client $client -Provider (New-TestRelayProvider) -Secrets @{
            ApiKey = $secret
            AccessToken = ''
            UserId = ''
        }

        $result.Ok | Should -BeTrue
        $client.Process.StartInfo.UseShellExecute | Should -BeFalse
        $client.Process.StartInfo.RedirectStandardInput | Should -BeTrue
        $client.Process.StartInfo.RedirectStandardOutput | Should -BeTrue
        $client.Process.StartInfo.RedirectStandardError | Should -BeTrue
        $client.Process.StartInfo.StandardInputEncoding.WebName | Should -BeExactly 'utf-8'
        $client.Process.StartInfo.StandardOutputEncoding.WebName | Should -BeExactly 'utf-8'
        $client.Process.StartInfo.StandardErrorEncoding.WebName | Should -BeExactly 'utf-8'
        (@($client.Process.StartInfo.ArgumentList) -join "`n") | Should -Not -Match $secret
        (@($client.Process.StartInfo.Environment.Values) -join "`n") | Should -Not -Match $secret
    }

    It 'correlates two commands by distinct generated IDs on one long-lived process' {
        $client = Start-TestRelayClient
        $processId = $client.Process.Id

        $first = Invoke-RelayScriptQuery -Client $client -Provider (New-TestRelayProvider) -Secrets @{}
        $second = Invoke-RelayScriptQuery -Client $client -Provider (New-TestRelayProvider) -Secrets @{}

        $first.Id | Should -Not -BeNullOrEmpty
        $second.Id | Should -Not -BeNullOrEmpty
        $second.Id | Should -Not -BeExactly $first.Id
        $first.Results[0].Remaining | Should -Be 7
        $second.Results[0].PlanName | Should -BeExactly 'Fixture'
        $client.Process.Id | Should -Be $processId
    }

    It 'returns only the normalized response allowlist' {
        $client = Start-TestRelayClient

        $result = Invoke-RelayScriptQuery -Client $client -Provider (New-TestRelayProvider) -Secrets @{}

        ($result.PSObject.Properties.Name -join ',') | Should -BeExactly 'Id,Ok,Results,Meta'
        ($result.Results[0].PSObject.Properties.Name -join ',') |
            Should -BeExactly 'IsValid,InvalidMessage,Remaining,Unit,PlanName,Total,Used,Extra'
        ($result.Meta.PSObject.Properties.Name -join ',') |
            Should -BeExactly 'HttpStatus,DestinationHost,DurationMs'
    }

    It 'preserves a sanitized sidecar failure without adding raw fields' {
        $client = Start-TestRelayClient

        $result = Invoke-RelayScriptQuery -Client $client -Provider (New-TestRelayProvider -Script 'sanitized-failure') -Secrets @{}

        $result.Ok | Should -BeFalse
        ($result.PSObject.Properties.Name -join ',') | Should -BeExactly 'Id,Ok,Error'
        ($result.Error.PSObject.Properties.Name -join ',') |
            Should -BeExactly 'Category,Message,HttpStatus,RetryAfterSeconds,DestinationHost,DestinationFingerprint'
        $result.Error.Category | Should -BeExactly 'HttpStatus'
        $result.Error.HttpStatus | Should -Be 401
    }

    It 'caps stderr records without exposing incoming secrets' {
        $secret = 'SECRET_STDERR_91734'
        $client = Start-TestRelayClient -StderrRecordLimit 3

        $result = Invoke-RelayScriptQuery -Client $client -Provider (New-TestRelayProvider -Script 'stderr-burst') -Secrets @{ ApiKey = $secret }

        $result.Ok | Should -BeTrue
        @($client.Stderr).Count | Should -Be 3
        (@($client.Stderr) -join "`n") | Should -Not -Match $secret
    }

    It 'returns a sanitized lifecycle failure when stdout is malformed' {
        $client = Start-TestRelayClient

        $result = Invoke-RelayScriptQuery -Client $client -Provider (New-TestRelayProvider -Script 'malformed-output') -Secrets @{}

        $result.Ok | Should -BeFalse
        $result.Error.Category | Should -BeExactly 'SidecarLifecycle'
        $result.Error.Message | Should -BeExactly 'Relay script host returned an invalid response.'
    }

    It 'returns a sanitized lifecycle failure after process exit' {
        $client = Start-TestRelayClient

        $result = Invoke-RelayScriptQuery -Client $client -Provider (New-TestRelayProvider -Script 'exit-17') -Secrets @{}

        $result.Ok | Should -BeFalse
        $result.Error.Category | Should -BeExactly 'SidecarLifecycle'
        $result.Error.Message | Should -BeExactly 'Relay script host exited unexpectedly.'
        ($result | ConvertTo-Json -Depth 8 -Compress) | Should -Not -Match '17|exit code|stack|exception'
    }

    It 'times out at provider timeout plus two seconds and stops the blocked client' {
        $client = Start-TestRelayClient
        $watch = [Diagnostics.Stopwatch]::StartNew()

        $result = Invoke-RelayScriptQuery -Client $client -Provider (New-TestRelayProvider -Script 'delayed-success' -TimeoutSeconds 2) -Secrets @{}
        $watch.Stop()

        $result.Ok | Should -BeFalse
        $result.Error.Category | Should -BeExactly 'Timeout'
        $watch.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 3.5
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 5.5
        $client.Disposed | Should -BeTrue
    }

    It 'stops a stubborn child within one bounded deadline and is idempotent' {
        $client = Start-TestRelayClient -ExtraArguments @('-Stubborn')
        $watch = [Diagnostics.Stopwatch]::StartNew()

        Stop-RelayScriptClient -Client $client -TimeoutMilliseconds 300
        Stop-RelayScriptClient -Client $client -TimeoutMilliseconds 300
        $watch.Stop()

        $watch.Elapsed.TotalSeconds | Should -BeLessThan 1.2
        $client.Disposed | Should -BeTrue
    }
}
