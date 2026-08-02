BeforeAll {
    $schedulerScript = "$PSScriptRoot\..\..\companion\Private\RelayScheduler.ps1"
    if (Test-Path -LiteralPath $schedulerScript -PathType Leaf) {
        . $schedulerScript
    }

    function New-TestRelaySchedulerProvider {
        param(
            [string]$Id,
            [bool]$Enabled = $true,
            [int]$IntervalMinutes = 10
        )
        [pscustomobject][ordered]@{
            Id = $Id
            Enabled = $Enabled
            IntervalMinutes = $IntervalMinutes
        }
    }
}

Describe 'relay provider scheduler' {
    It 'starts at most two due providers and deduplicates manual refresh' {
        $now = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $providers = @(
            New-TestRelaySchedulerProvider 'one'
            New-TestRelaySchedulerProvider 'two'
            New-TestRelaySchedulerProvider 'three'
        )
        $scheduler = New-RelaySchedulerState -Providers $providers -Now $now -MaximumConcurrency 2

        $first = Get-RelaySchedulerActions -State $scheduler -Now $now -ManualRefresh
        $second = Get-RelaySchedulerActions -State $first.State -Now $now -ManualRefresh

        @($first.Actions | Where-Object Kind -eq 'StartQuery').Count | Should -Be 2
        @($first.Actions | Select-Object -ExpandProperty ProviderId) | Should -Be @('one', 'two')
        @($second.Actions | Where-Object Kind -eq 'StartQuery').Count | Should -Be 0
        @($first.State.Providers | Where-Object InFlight).Count | Should -Be 2
    }

    It 'does not schedule disabled or interval-zero providers automatically' {
        $now = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $scheduler = New-RelaySchedulerState -Providers @(
            New-TestRelaySchedulerProvider 'disabled' -Enabled $false
            New-TestRelaySchedulerProvider 'manual-only' -IntervalMinutes 0
            New-TestRelaySchedulerProvider 'due'
        ) -Now $now

        $automatic = Get-RelaySchedulerActions -State $scheduler -Now $now
        $manual = Get-RelaySchedulerActions -State $automatic.State -Now $now -ManualRefresh

        @($automatic.Actions | Select-Object -ExpandProperty ProviderId) | Should -Be @('due')
        @($manual.Actions | Select-Object -ExpandProperty ProviderId) | Should -Be @('manual-only')
    }

    It 'schedules the next success at the configured provider interval' {
        $now = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $scheduler = New-RelaySchedulerState -Providers @(
            New-TestRelaySchedulerProvider 'wkk' -IntervalMinutes 17
        ) -Now $now
        $started = Get-RelaySchedulerActions -State $scheduler -Now $now

        $completed = Complete-RelaySchedulerAction -State $started.State -ProviderId 'wkk' `
            -Outcome Success -Now $now.AddSeconds(5)

        $entry = @($completed.Providers | Where-Object ProviderId -eq 'wkk')[0]
        $entry.InFlight | Should -BeFalse
        $entry.ConsecutiveFailures | Should -Be 0
        $entry.NextDueAt | Should -Be $now.AddSeconds(5).AddMinutes(17)
        @((Get-RelaySchedulerActions -State $completed -Now $entry.NextDueAt.AddTicks(-1)).Actions).Count |
            Should -Be 0
        @((Get-RelaySchedulerActions -State $completed -Now $entry.NextDueAt).Actions).Count |
            Should -Be 1
    }

    It 'uses the exact bounded network backoff sequence' {
        $now = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $scheduler = New-RelaySchedulerState -Providers @(
            New-TestRelaySchedulerProvider 'wkk'
        ) -Now $now
        $expectedMinutes = @(1, 2, 5, 10, 30, 60, 60)

        foreach ($expected in $expectedMinutes) {
            $started = Get-RelaySchedulerActions -State $scheduler -Now $now -ManualRefresh
            $scheduler = Complete-RelaySchedulerAction -State $started.State -ProviderId 'wkk' `
                -Outcome Failure -Category 'Connectivity' -Now $now
            $entry = @($scheduler.Providers)[0]
            ($entry.NextDueAt - $now).TotalMinutes | Should -Be $expected
            $now = $now.AddMinutes(70)
        }
    }

    It 'respects a valid Retry-After for HTTP 429 and caps it at one hour' -ForEach @(
        @{ RetryAfter = 17; ExpectedSeconds = 17 }
        @{ RetryAfter = 7200; ExpectedSeconds = 3600 }
    ) {
        $now = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $scheduler = New-RelaySchedulerState -Providers @(
            New-TestRelaySchedulerProvider 'wkk'
        ) -Now $now
        $started = Get-RelaySchedulerActions -State $scheduler -Now $now

        $completed = Complete-RelaySchedulerAction -State $started.State -ProviderId 'wkk' `
            -Outcome Failure -Category 'HttpStatus' -HttpStatus 429 `
            -RetryAfterSeconds $RetryAfter -Now $now

        (@($completed.Providers)[0].NextDueAt - $now).TotalSeconds | Should -Be $ExpectedSeconds
    }

    It 'rejects non-integer Retry-After values and uses normal backoff' -ForEach @(
        @{ RetryAfter = '17' }
        @{ RetryAfter = [double]1.5 }
        @{ RetryAfter = 0 }
        @{ RetryAfter = -1 }
    ) {
        $now = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $scheduler = New-RelaySchedulerState -Providers @(
            New-TestRelaySchedulerProvider 'wkk'
        ) -Now $now
        $started = Get-RelaySchedulerActions -State $scheduler -Now $now

        $completed = Complete-RelaySchedulerAction -State $started.State -ProviderId 'wkk' `
            -Outcome Failure -Category 'HttpStatus' -HttpStatus 429 `
            -RetryAfterSeconds $RetryAfter -Now $now

        (@($completed.Providers)[0].NextDueAt - $now).TotalMinutes | Should -Be 1
    }

    It 'pauses authentication failures but permits an explicit manual retry' {
        $now = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $scheduler = New-RelaySchedulerState -Providers @(
            New-TestRelaySchedulerProvider 'wkk'
        ) -Now $now
        $started = Get-RelaySchedulerActions -State $scheduler -Now $now
        $paused = Complete-RelaySchedulerAction -State $started.State -ProviderId 'wkk' `
            -Outcome Failure -Category 'HttpStatus' -HttpStatus 401 -Now $now

        @((Get-RelaySchedulerActions -State $paused -Now $now.AddDays(1)).Actions).Count |
            Should -Be 0
        $manual = Get-RelaySchedulerActions -State $paused -Now $now.AddDays(1) -ManualRefresh
        @($manual.Actions).Count | Should -Be 1
        @($manual.State.Providers)[0].PauseReason | Should -BeNullOrEmpty
    }

    It 'pauses script failures until manual refresh' {
        $now = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $scheduler = New-RelaySchedulerState -Providers @(
            New-TestRelaySchedulerProvider 'wkk'
        ) -Now $now
        $started = Get-RelaySchedulerActions -State $scheduler -Now $now
        $paused = Complete-RelaySchedulerAction -State $started.State -ProviderId 'wkk' `
            -Outcome Failure -Category 'ExtractorExecution' -Now $now

        @((Get-RelaySchedulerActions -State $paused -Now $now.AddDays(1)).Actions).Count |
            Should -Be 0
        @((Get-RelaySchedulerActions -State $paused -Now $now.AddDays(1) -ManualRefresh).Actions).Count |
            Should -Be 1
    }

    It 'never schedules a destination that still requires trust' {
        $now = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $scheduler = New-RelaySchedulerState -Providers @(
            New-TestRelaySchedulerProvider 'custom'
        ) -Now $now
        $started = Get-RelaySchedulerActions -State $scheduler -Now $now
        $paused = Complete-RelaySchedulerAction -State $started.State -ProviderId 'custom' `
            -Outcome Failure -Category 'DestinationTrustRequired' -Now $now

        @((Get-RelaySchedulerActions -State $paused -Now $now.AddDays(1)).Actions).Count |
            Should -Be 0
        @((Get-RelaySchedulerActions -State $paused -Now $now.AddDays(1) -ManualRefresh).Actions).Count |
            Should -Be 0
    }

    It 'keeps one provider failure local to that provider' {
        $now = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $scheduler = New-RelaySchedulerState -Providers @(
            New-TestRelaySchedulerProvider 'one'
            New-TestRelaySchedulerProvider 'two'
            New-TestRelaySchedulerProvider 'three'
        ) -Now $now -MaximumConcurrency 2
        $started = Get-RelaySchedulerActions -State $scheduler -Now $now

        $failed = Complete-RelaySchedulerAction -State $started.State -ProviderId 'one' `
            -Outcome Failure -Category 'Tls' -Now $now
        $next = Get-RelaySchedulerActions -State $failed -Now $now

        @($next.Actions | Select-Object -ExpandProperty ProviderId) | Should -Be @('three')
        @($next.State.Providers | Where-Object ProviderId -eq 'two')[0].InFlight | Should -BeTrue
    }

    It 'maps stable host errors into scheduler policies' -ForEach @(
        @{ Category = 'HttpStatus'; HttpStatus = 403; Expected = 'Authentication' }
        @{ Category = 'HttpStatus'; HttpStatus = 429; Expected = 'RateLimit' }
        @{ Category = 'HttpStatus'; HttpStatus = 503; Expected = 'Retry' }
        @{ Category = 'Dns'; HttpStatus = $null; Expected = 'Retry' }
        @{ Category = 'Timeout'; HttpStatus = $null; Expected = 'Retry' }
        @{ Category = 'SidecarLifecycle'; HttpStatus = $null; Expected = 'Retry' }
        @{ Category = 'ScriptSyntax'; HttpStatus = $null; Expected = 'InvalidScript' }
        @{ Category = 'RequestValidation'; HttpStatus = $null; Expected = 'InvalidScript' }
        @{ Category = 'ResultValidation'; HttpStatus = $null; Expected = 'InvalidScript' }
        @{ Category = 'DestinationTrustRequired'; HttpStatus = $null; Expected = 'TrustRequired' }
    ) {
        Get-RelaySchedulerFailurePolicy -Category $Category -HttpStatus $HttpStatus |
            Should -BeExactly $Expected
    }

    It 'does not mutate scheduler input state during actions or completion' {
        $now = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $scheduler = New-RelaySchedulerState -Providers @(
            New-TestRelaySchedulerProvider 'wkk'
        ) -Now $now
        $before = $scheduler | ConvertTo-Json -Depth 8 -Compress

        $started = Get-RelaySchedulerActions -State $scheduler -Now $now
        $null = Complete-RelaySchedulerAction -State $started.State -ProviderId 'wkk' `
            -Outcome Failure -Category 'Tls' -Now $now

        ($scheduler | ConvertTo-Json -Depth 8 -Compress) | Should -BeExactly $before
    }
}
