BeforeAll {
    $stateScript = "$PSScriptRoot\..\..\companion\Private\RelayState.ps1"
    if (Test-Path -LiteralPath $stateScript -PathType Leaf) {
        . $stateScript
    }

    function New-TestUsageResult {
        param(
            [bool]$IsValid = $true,
            [AllowNull()][object]$Remaining = [double]18.42,
            [AllowNull()][string]$InvalidMessage = $null,
            [string]$PlanName = 'Wallet'
        )
        [pscustomobject][ordered]@{
            IsValid = $IsValid
            InvalidMessage = $InvalidMessage
            Remaining = $Remaining
            Unit = 'USD'
            PlanName = $PlanName
            Total = $null
            Used = $null
            Extra = $null
        }
    }
}

Describe 'relay provider state transitions' {
    It 'creates the exact Starting shape without cached data' {
        $state = New-RelayProviderState -ProviderId 'wkk' -Enabled $true

        ($state.PSObject.Properties.Name -join ',') |
            Should -BeExactly 'ProviderId,Status,Results,LastSuccessAt,LastAttemptAt,LastErrorCategory,NextDueAt,ConsecutiveFailures,RetryAfterSeconds,InFlight'
        $state.ProviderId | Should -BeExactly 'wkk'
        $state.Status | Should -BeExactly 'Starting'
        @($state.Results).Count | Should -Be 0
        $state.NextDueAt | Should -Be ([DateTimeOffset]::MinValue)
        $state.ConsecutiveFailures | Should -Be 0
        $state.InFlight | Should -BeFalse
    }

    It 'starts from stale cache and preserves explicit zero through a network failure' {
        $cachedAt = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $now = [DateTimeOffset]'2026-08-01T08:05:00Z'
        $later = $now.AddMinutes(1)
        $cached = [object[]]@(New-TestUsageResult -Remaining ([double]0))

        $state = New-RelayProviderState -ProviderId 'wkk' -Enabled $true -CachedResults $cached -CachedAt $cachedAt
        $state.Status | Should -BeExactly 'Stale'
        $state = Complete-RelayProviderSuccess -State $state -Results $cached -Now $now
        $state.Status | Should -BeExactly 'Live'
        $state.Results[0].Remaining | Should -Be 0
        $state = Complete-RelayProviderFailure -State $state -Category 'Network' -Now $later

        $state.Status | Should -BeExactly 'Stale'
        $state.Results[0].Remaining | Should -Be 0
        $state.LastSuccessAt | Should -Be $now
        $state.LastAttemptAt | Should -Be $later
        $state.ConsecutiveFailures | Should -Be 1
    }

    It 'uses Unavailable without synthesizing zero when no last-good data exists' {
        $state = New-RelayProviderState -ProviderId 'empty' -Enabled $true

        $failed = Complete-RelayProviderFailure -State $state -Category 'Timeout' -Now ([DateTimeOffset]'2026-08-01T09:00:00Z')

        $failed.Status | Should -BeExactly 'Unavailable'
        @($failed.Results).Count | Should -Be 0
        $failed.LastSuccessAt | Should -BeNullOrEmpty
    }

    It 'preserves last-good data for authentication and script failures' -ForEach @(
        @{ Category = 'Authentication'; Expected = 'AuthRequired' }
        @{ Category = 'ScriptSyntax'; Expected = 'InvalidScript' }
        @{ Category = 'DestinationTrustRequired'; Expected = 'InvalidScript' }
    ) {
        $cached = [object[]]@(New-TestUsageResult -Remaining ([double]7))
        $cachedAt = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $state = New-RelayProviderState -ProviderId 'wkk' -Enabled $true -CachedResults $cached -CachedAt $cachedAt

        $failed = Complete-RelayProviderFailure -State $state -Category $Category -Now $cachedAt.AddMinutes(1)

        $failed.Status | Should -BeExactly $Expected
        $failed.Results[0].Remaining | Should -Be 7
        $failed.LastSuccessAt | Should -Be $cachedAt
    }

    It 'maps an all-invalid successful extractor result to AuthRequired without replacing last-good data' {
        $cached = [object[]]@(New-TestUsageResult -Remaining ([double]9))
        $cachedAt = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $state = New-RelayProviderState -ProviderId 'wkk' -Enabled $true -CachedResults $cached -CachedAt $cachedAt
        $invalid = [object[]]@(
            New-TestUsageResult -IsValid $false -Remaining $null -InvalidMessage 'account invalid'
        )

        $next = Complete-RelayProviderSuccess -State $state -Results $invalid -Now $cachedAt.AddMinutes(2)

        $next.Status | Should -BeExactly 'AuthRequired'
        $next.Results[0].Remaining | Should -Be 9
        $next.LastSuccessAt | Should -Be $cachedAt
    }

    It 'keeps mixed valid and invalid rows in a Live result' {
        $state = New-RelayProviderState -ProviderId 'mixed' -Enabled $true
        $results = [object[]]@(
            New-TestUsageResult -IsValid $true -Remaining ([double]5) -PlanName 'Live'
            New-TestUsageResult -IsValid $false -Remaining $null -InvalidMessage 'expired' -PlanName 'Expired'
        )
        $now = [DateTimeOffset]'2026-08-01T10:00:00+08:00'

        $next = Complete-RelayProviderSuccess -State $state -Results $results -Now $now

        $next.Status | Should -BeExactly 'Live'
        @($next.Results).Count | Should -Be 2
        $next.Results[0].IsValid | Should -BeTrue
        $next.Results[1].IsValid | Should -BeFalse
        $next.LastSuccessAt.Offset | Should -Be ([TimeSpan]::Zero)
    }

    It 'disables and re-enables without discarding last-good data' {
        $cached = [object[]]@(New-TestUsageResult -Remaining ([double]11))
        $state = New-RelayProviderState -ProviderId 'wkk' -Enabled $true -CachedResults $cached -CachedAt ([DateTimeOffset]'2026-08-01T08:00:00Z')

        $disabled = Set-RelayProviderEnabled -State $state -Enabled $false
        $enabled = Set-RelayProviderEnabled -State $disabled -Enabled $true

        $disabled.Status | Should -BeExactly 'Disabled'
        $disabled.InFlight | Should -BeFalse
        $enabled.Status | Should -BeExactly 'Stale'
        $enabled.Results[0].Remaining | Should -Be 11
    }

    It 'keeps Disabled state when an in-flight success arrives after disable' {
        $cachedAt = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $attemptAt = $cachedAt.AddMinutes(1)
        $cached = [object[]]@(New-TestUsageResult -Remaining ([double]11))
        $state = New-RelayProviderState -ProviderId 'wkk' -Enabled $true -CachedResults $cached -CachedAt $cachedAt
        $attempt = Start-RelayProviderAttempt -State $state -Now $attemptAt
        $disabled = Set-RelayProviderEnabled -State $attempt -Enabled $false

        $completed = Complete-RelayProviderSuccess -State $disabled -Results @(
            New-TestUsageResult -Remaining ([double]99)
        ) -Now $attemptAt.AddMinutes(1)

        $completed.Status | Should -BeExactly 'Disabled'
        $completed.Results[0].Remaining | Should -Be 11
        $completed.LastSuccessAt | Should -Be $cachedAt
        $completed.LastAttemptAt | Should -Be $attemptAt
        $completed.InFlight | Should -BeFalse
    }

    It 'keeps Disabled state when an in-flight failure arrives after disable' {
        $cachedAt = [DateTimeOffset]'2026-08-01T08:00:00Z'
        $attemptAt = $cachedAt.AddMinutes(1)
        $cached = [object[]]@(New-TestUsageResult -Remaining ([double]11))
        $state = New-RelayProviderState -ProviderId 'wkk' -Enabled $true -CachedResults $cached -CachedAt $cachedAt
        $attempt = Start-RelayProviderAttempt -State $state -Now $attemptAt
        $disabled = Set-RelayProviderEnabled -State $attempt -Enabled $false

        $completed = Complete-RelayProviderFailure -State $disabled -Category 'Network' -Now $attemptAt.AddMinutes(1)

        $completed.Status | Should -BeExactly 'Disabled'
        $completed.Results[0].Remaining | Should -Be 11
        $completed.LastSuccessAt | Should -Be $cachedAt
        $completed.LastAttemptAt | Should -Be $attemptAt
        $completed.LastErrorCategory | Should -BeNullOrEmpty
        $completed.ConsecutiveFailures | Should -Be 0
        $completed.InFlight | Should -BeFalse
    }

    It 'keeps a disabled state disabled when an attempt is requested' {
        $state = New-RelayProviderState -ProviderId 'wkk' -Enabled $false

        $attempt = Start-RelayProviderAttempt -State $state -Now ([DateTimeOffset]'2026-08-01T08:00:00Z')

        $attempt.Status | Should -BeExactly 'Disabled'
        $attempt.LastAttemptAt | Should -BeNullOrEmpty
        $attempt.InFlight | Should -BeFalse
    }

    It 'marks attempts without mutating the input state' {
        $state = New-RelayProviderState -ProviderId 'wkk' -Enabled $true
        $before = $state | ConvertTo-Json -Depth 8 -Compress
        $now = [DateTimeOffset]'2026-08-01T08:00:00Z'

        $attempt = Start-RelayProviderAttempt -State $state -Now $now

        ($state | ConvertTo-Json -Depth 8 -Compress) | Should -BeExactly $before
        $state.InFlight | Should -BeFalse
        $attempt.InFlight | Should -BeTrue
        $attempt.LastAttemptAt | Should -Be $now
    }

    It 'does not mutate an input state during success or failure' {
        $state = New-RelayProviderState -ProviderId 'wkk' -Enabled $true -CachedResults @(
            New-TestUsageResult -Remaining ([double]3)
        ) -CachedAt ([DateTimeOffset]'2026-08-01T08:00:00Z')
        $before = $state | ConvertTo-Json -Depth 8 -Compress

        $null = Complete-RelayProviderSuccess -State $state -Results @(
            New-TestUsageResult -Remaining ([double]2)
        ) -Now ([DateTimeOffset]'2026-08-01T08:01:00Z')
        $null = Complete-RelayProviderFailure -State $state -Category 'Network' -Now ([DateTimeOffset]'2026-08-01T08:02:00Z')

        ($state | ConvertTo-Json -Depth 8 -Compress) | Should -BeExactly $before
    }

    It 'does not mutate an input state when changing enabled status' {
        $state = New-RelayProviderState -ProviderId 'wkk' -Enabled $true -CachedResults @(
            New-TestUsageResult -Remaining ([double]3)
        ) -CachedAt ([DateTimeOffset]'2026-08-01T08:00:00Z')
        $before = $state | ConvertTo-Json -Depth 8 -Compress

        $disabled = Set-RelayProviderEnabled -State $state -Enabled $false

        ($state | ConvertTo-Json -Depth 8 -Compress) | Should -BeExactly $before
        $state.Status | Should -BeExactly 'Stale'
        $disabled.Status | Should -BeExactly 'Disabled'
    }
}
