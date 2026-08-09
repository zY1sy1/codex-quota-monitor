BeforeAll {
    . "$PSScriptRoot\..\..\companion\Private\ObjectAccess.ps1"
    . "$PSScriptRoot\..\..\companion\Private\Presentation.ps1"
}

Describe 'Get-QuotaLabel' {
    It 'uses the five-hour label for durations from 270 through 330 minutes' {
        Get-QuotaLabel -WindowDurationMins 270 -LimitName 'Ignored' | Should -Be '5 小时额度'
        Get-QuotaLabel -WindowDurationMins 330 -LimitName 'Ignored' | Should -Be '5 小时额度'
    }

    It 'uses the weekly label for durations from 9000 through 11000 minutes' {
        Get-QuotaLabel -WindowDurationMins 9000 -LimitName 'Ignored' | Should -Be '周额度'
        Get-QuotaLabel -WindowDurationMins 11000 -LimitName 'Ignored' | Should -Be '周额度'
    }

    It 'uses the official nonblank name for other durations' {
        Get-QuotaLabel -WindowDurationMins 60 -LimitName 'Code review' | Should -Be 'Code review'
    }

    It 'falls back to an explicit other-duration label' {
        Get-QuotaLabel -WindowDurationMins 45 -LimitName '   ' | Should -Be '其他额度 · 45 分钟'
    }
}

Describe 'Format-ResetCountdown' {
    BeforeAll {
        $script:CountdownNow = [DateTimeOffset]'2026-07-13T00:00:00Z'
    }

    It 'shows refreshing for expired and exactly-current reset times' {
        Format-ResetCountdown -ResetsAt ($CountdownNow.ToUnixTimeSeconds() - 1) -Now $CountdownNow | Should -Be '正在刷新'
        Format-ResetCountdown -ResetsAt $CountdownNow.ToUnixTimeSeconds() -Now $CountdownNow | Should -Be '正在刷新'
    }

    It 'keeps a positive fractional second in the active countdown' {
        $resetsAt = $CountdownNow.ToUnixTimeSeconds() + 1
        $now = [DateTimeOffset]::FromUnixTimeSeconds($resetsAt).AddMilliseconds(-500)

        Format-ResetCountdown -ResetsAt $resetsAt -Now $now | Should -Be '00:00:00'
    }

    It 'formats a sub-day countdown with total hours' {
        $resetsAt = $CountdownNow.ToUnixTimeSeconds() + (5 * 3600) + (2 * 60) + 3
        Format-ResetCountdown -ResetsAt $resetsAt -Now $CountdownNow | Should -Be '05:02:03'
    }

    It 'formats one day and multi-day countdowns with remaining clock time' {
        Format-ResetCountdown -ResetsAt ($CountdownNow.ToUnixTimeSeconds() + 86400) -Now $CountdownNow | Should -Be '1天 00:00:00'
        $resetsAt = $CountdownNow.ToUnixTimeSeconds() + (2 * 86400) + (3 * 3600) + (4 * 60) + 5
        Format-ResetCountdown -ResetsAt $resetsAt -Now $CountdownNow | Should -Be '2天 03:04:05'
    }

    It 'returns an unknown label for an out-of-range Unix timestamp' {
        Format-ResetCountdown -ResetsAt ([long]::MaxValue) -Now $CountdownNow | Should -Be '重置时间未知'
    }
}

Describe 'Get-QuotaSeverity' {
    It 'returns gray while offline regardless of the remaining quota' {
        Get-QuotaSeverity -MinimumRemaining 99 -Offline $true | Should -Be 'Gray'
    }

    It 'applies the red, yellow, and green boundaries' -ForEach @(
        @{ Remaining = 14.9; Expected = 'Red' },
        @{ Remaining = 15; Expected = 'Yellow' },
        @{ Remaining = 40; Expected = 'Yellow' },
        @{ Remaining = 40.1; Expected = 'Green' }
    ) {
        Get-QuotaSeverity -MinimumRemaining $Remaining -Offline $false | Should -Be $Expected
    }

    It 'returns gray for missing, invalid, and non-finite remaining quota' -ForEach @(
        @{ Remaining = $null },
        @{ Remaining = 'not-a-number' },
        @{ Remaining = [double]::NaN },
        @{ Remaining = [double]::PositiveInfinity },
        @{ Remaining = [double]::NegativeInfinity }
    ) {
        Get-QuotaSeverity -MinimumRemaining $Remaining -Offline $false | Should -Be 'Gray'
    }
}

Describe 'Get-TrayTooltip' {
    It 'uses compact known labels, official labels, and rounded remaining percentages' {
        $windows = @(
            [pscustomobject]@{ WindowDurationMins = 300; LimitName = 'Codex'; RemainingPercent = 74.6 }
            [pscustomobject]@{ WindowDurationMins = 10080; LimitName = 'Codex'; RemainingPercent = 40.4 }
            [pscustomobject]@{ WindowDurationMins = 60; LimitName = 'Review'; RemainingPercent = 12.2 }
        )

        Get-TrayTooltip -QuotaWindows $windows | Should -Be '5h 75% | 周 40% | Review 12%'
    }

    It 'marks a missing remaining percentage instead of fabricating 100 percent' {
        $windows = @(
            [pscustomobject]@{ WindowDurationMins = 45; LimitName = ''; RemainingPercent = $null }
        )

        $tooltip = Get-TrayTooltip -QuotaWindows $windows

        $tooltip | Should -Be '其他额度 · 45 分钟 --%'
        $tooltip | Should -Not -Match '100%'
    }

    It 'hard-limits the Windows tray tooltip to 63 characters' {
        $windows = @(
            [pscustomobject]@{
                WindowDurationMins = 60
                LimitName = ('Very long official quota name ' * 4).Trim()
                RemainingPercent = 55
            }
        )

        $tooltip = Get-TrayTooltip -QuotaWindows $windows

        $tooltip.Length | Should -Be 63
        $tooltip.StartsWith('Very long official quota name') | Should -BeTrue
    }

    It 'shows an unknown percentage for invalid and non-finite values' -ForEach @(
        @{ Remaining = 'not-a-number' },
        @{ Remaining = [double]::NaN },
        @{ Remaining = [double]::PositiveInfinity },
        @{ Remaining = [double]::NegativeInfinity }
    ) {
        $windows = @(
            [pscustomobject]@{ WindowDurationMins = 60; LimitName = 'Review'; RemainingPercent = $Remaining }
        )

        Get-TrayTooltip -QuotaWindows $windows | Should -Be 'Review --%'
    }

    It 'does not split an emoji surrogate pair at the tooltip boundary' {
        $emoji = [char]::ConvertFromUtf32(0x1F600)
        $windows = @(
            [pscustomobject]@{
                WindowDurationMins = 60
                LimitName = ('x' * 62) + $emoji
                RemainingPercent = 55
            }
        )

        $tooltip = Get-TrayTooltip -QuotaWindows $windows

        $tooltip.Length | Should -BeLessOrEqual 63
        $tooltip | Should -Be ('x' * 62)
        [char]::IsHighSurrogate($tooltip[$tooltip.Length - 1]) | Should -BeFalse
    }

    It 'does not split a combining text element at the tooltip boundary' {
        $windows = @(
            [pscustomobject]@{
                WindowDurationMins = 60
                LimitName = ('x' * 62) + "e$([char]0x0301)"
                RemainingPercent = 55
            }
        )

        Get-TrayTooltip -QuotaWindows $windows | Should -Be ('x' * 62)
    }
}

Describe 'ConvertTo-QuotaPresentationRow' {
    BeforeAll {
        $script:PresentationNow = [DateTimeOffset]'2026-07-13T00:00:00Z'
        $script:PresentationReset = $PresentationNow.AddHours(5).ToUnixTimeSeconds()
    }

    It 'builds the exact display boundary for fractional remaining quota' {
        $source = [pscustomobject][ordered]@{
            Key = 'codex|primary|300|reset'
            LimitId = 'codex'
            LimitName = 'Ignored'
            WindowKind = 'primary'
            UsedPercent = 25.5
            RemainingPercent = 74.5
            WindowDurationMins = 300
            ResetsAt = $PresentationReset
            RateLimitReached = ''
        }

        $row = @(ConvertTo-QuotaPresentationRow -QuotaWindows @($source) -Now $PresentationNow)[0]

        @($row.PSObject.Properties.Name) | Should -Be @(
            'Key', 'Label', 'RemainingText', 'ProgressValue', 'CountdownText', 'ResetTimeText'
        )
        $row.Key | Should -BeExactly $source.Key
        $row.Label | Should -BeExactly '5 小时额度'
        $row.RemainingText | Should -BeExactly '74.5%'
        $row.ProgressValue | Should -BeOfType ([double])
        $row.ProgressValue | Should -Be 74.5
        $row.CountdownText | Should -BeExactly '05:00:00'
        $expectedLocal = [DateTimeOffset]::FromUnixTimeSeconds($PresentationReset).ToLocalTime().ToString(
            "'重置时间：'yyyy-MM-dd HH:mm",
            [Globalization.CultureInfo]::InvariantCulture
        )
        $row.ResetTimeText | Should -BeExactly $expectedLocal
    }

    It 'does not fabricate progress for missing, invalid, non-finite, or out-of-range remaining quota' -ForEach @(
        @{ Remaining = $null },
        @{ Remaining = 'not-a-number' },
        @{ Remaining = [double]::NaN },
        @{ Remaining = [double]::PositiveInfinity },
        @{ Remaining = -0.1 },
        @{ Remaining = 100.1 }
    ) {
        $source = [pscustomobject]@{
            Key = 'review|primary|60|reset'
            LimitName = 'Review'
            RemainingPercent = $Remaining
            WindowDurationMins = 60
            ResetsAt = $PresentationReset
        }

        $row = @(ConvertTo-QuotaPresentationRow -QuotaWindows @($source) -Now $PresentationNow)[0]

        $row.ProgressValue | Should -BeNullOrEmpty
        $row.RemainingText | Should -BeExactly '--%'
    }

    It 'marks invalid Unix reset timestamps unknown without throwing' -ForEach @(
        @{ Reset = 'not-a-timestamp' },
        @{ Reset = [double]::NaN },
        @{ Reset = [long]::MaxValue },
        @{ Reset = 0 },
        @{ Reset = $null }
    ) {
        $source = [pscustomobject]@{
            Key = 'review|primary|60|bad'
            LimitName = 'Review'
            RemainingPercent = 50
            WindowDurationMins = 60
            ResetsAt = $Reset
        }

        $row = @(ConvertTo-QuotaPresentationRow -QuotaWindows @($source) -Now $PresentationNow)[0]

        $row.CountdownText | Should -BeExactly '重置时间未知'
        $row.ResetTimeText | Should -BeExactly '重置时间未知'
    }

    It 'does not mutate source records' {
        $source = [pscustomobject][ordered]@{
            Key = 'codex|secondary|10080|reset'
            LimitName = 'Codex'
            RemainingPercent = 80
            WindowDurationMins = 10080
            ResetsAt = $PresentationReset
        }
        $before = $source | ConvertTo-Json -Compress

        $null = @(ConvertTo-QuotaPresentationRow -QuotaWindows @($source) -Now $PresentationNow)

        ($source | ConvertTo-Json -Compress) | Should -BeExactly $before
    }

    It 'returns an empty collection for no quota windows' {
        @(ConvertTo-QuotaPresentationRow -QuotaWindows @() -Now $PresentationNow).Count | Should -Be 0
    }
}

Describe 'ConvertTo-OfficialMonitorPresentationRow' {
    It 'adapts the legacy official display shape without changing its producer' {
        $legacy = [pscustomobject][ordered]@{
            Key = 'official:five-hour'
            Label = '5 小时额度'
            RemainingText = '74.5%'
            ProgressValue = [double]74.5
            CountdownText = '05:00:00'
            ResetTimeText = '重置时间：2026-08-01 13:00'
        }

        $row = ConvertTo-OfficialMonitorPresentationRow -Row $legacy

        $row.SourceKind | Should -BeExactly 'Official'
        $row.SourceId | Should -BeExactly 'codex'
        $row.ValueText | Should -BeExactly '74.5%'
        $row.Countdown | Should -BeExactly '05:00:00'
        $row.ResetTime | Should -BeExactly '重置时间：2026-08-01 13:00'
    }
}
