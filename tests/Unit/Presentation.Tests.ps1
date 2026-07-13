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

    It 'formats a sub-day countdown with total hours' {
        $resetsAt = $CountdownNow.ToUnixTimeSeconds() + (5 * 3600) + (2 * 60) + 3
        Format-ResetCountdown -ResetsAt $resetsAt -Now $CountdownNow | Should -Be '05:02:03'
    }

    It 'formats one day and multi-day countdowns with remaining clock time' {
        Format-ResetCountdown -ResetsAt ($CountdownNow.ToUnixTimeSeconds() + 86400) -Now $CountdownNow | Should -Be '1天 00:00:00'
        $resetsAt = $CountdownNow.ToUnixTimeSeconds() + (2 * 86400) + (3 * 3600) + (4 * 60) + 5
        Format-ResetCountdown -ResetsAt $resetsAt -Now $CountdownNow | Should -Be '2天 03:04:05'
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
}
