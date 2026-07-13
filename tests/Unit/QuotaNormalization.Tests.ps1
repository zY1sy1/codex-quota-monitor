BeforeAll {
    . "$PSScriptRoot\..\..\companion\Private\ObjectAccess.ps1"
    . "$PSScriptRoot\..\..\companion\Private\QuotaNormalization.ps1"
}

Describe 'Get-ObjectField' {
    It 'returns null for a null input or a missing field' {
        Get-ObjectField -InputObject $null -Name 'anything' | Should -BeNullOrEmpty
        Get-ObjectField -InputObject ([pscustomobject]@{ Present = 1 }) -Name 'missing' | Should -BeNullOrEmpty
    }

    It 'reads IDictionary and PSObject fields, including null values' {
        $dictionary = [ordered]@{ Present = 42; Empty = $null }
        $object = [pscustomobject]@{ Present = 'value'; Empty = $null }

        Get-ObjectField -InputObject $dictionary -Name 'Present' | Should -Be 42
        Get-ObjectField -InputObject $dictionary -Name 'Empty' | Should -BeNullOrEmpty
        Get-ObjectField -InputObject $object -Name 'Present' | Should -Be 'value'
        Get-ObjectField -InputObject $object -Name 'Empty' | Should -BeNullOrEmpty
    }

    It 'reads generic IDictionary implementations with explicit members' {
        $dictionary = [System.Collections.Generic.Dictionary[string, object]]::new()
        $dictionary.Add('Present', 84)
        $dictionary.Add('Empty', $null)

        Get-ObjectField -InputObject $dictionary -Name 'Present' | Should -Be 84
        Get-ObjectField -InputObject $dictionary -Name 'Empty' | Should -BeNullOrEmpty
        Get-ObjectField -InputObject $dictionary -Name 'Missing' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-QuotaWindow' {
    It 'normalizes a compatibility-only response' {
        $fixture = Get-Content "$PSScriptRoot\..\Fixtures\RateLimits\compatibility-one.json" -Raw | ConvertFrom-Json
        $rows = @(ConvertTo-QuotaWindow -RateLimitResult $fixture)

        $rows.Count | Should -Be 1
        $rows[0].Key | Should -Be 'codex|primary|300|1783933200'
        $rows[0].LimitId | Should -Be 'codex'
        $rows[0].UsedPercent | Should -Be 35.25
        $rows[0].RemainingPercent | Should -Be 64.8
    }

    It 'emits primary and secondary windows from a named bucket' {
        $fixture = Get-Content "$PSScriptRoot\..\Fixtures\RateLimits\primary-secondary.json" -Raw | ConvertFrom-Json
        $rows = @(ConvertTo-QuotaWindow -RateLimitResult $fixture)

        $rows.Count | Should -Be 2
        $rows.WindowKind | Should -Be @('primary', 'secondary')
        $rows.WindowDurationMins | Should -Be @(300, 10080)
    }

    It 'prefers multi-bucket data and deduplicates compatibility data' {
        $fixture = Get-Content "$PSScriptRoot\..\Fixtures\RateLimits\multi-bucket.json" -Raw | ConvertFrom-Json
        $fixture.rateLimits.primary.usedPercent = 88.8
        $rows = @(ConvertTo-QuotaWindow -RateLimitResult $fixture)

        $rows.Count | Should -Be 3
        @($rows.Key | Select-Object -Unique).Count | Should -Be 3
        ($rows | Where-Object Key -EQ 'codex|primary|300|1783933200').UsedPercent | Should -Be 12.3
    }

    It 'preserves unknown bucket ids and durations without inventing percentages' {
        $fixture = Get-Content "$PSScriptRoot\..\Fixtures\RateLimits\unknown-window.json" -Raw | ConvertFrom-Json
        $fixture.rateLimitsByLimitId.'future-agent-hourly'.primary.PSObject.Properties.Remove('usedPercent')
        $row = @(ConvertTo-QuotaWindow -RateLimitResult $fixture)[0]

        $row.LimitId | Should -Be 'future-agent-hourly'
        $row.WindowDurationMins | Should -Be 45
        ($null -eq $row.UsedPercent) | Should -BeTrue
        ($null -eq $row.RemainingPercent) | Should -BeTrue
        $row.RateLimitReached | Should -Be 'future_reason'
    }

    It 'uses the exact locked property order and scalar types' {
        $fixture = Get-Content "$PSScriptRoot\..\Fixtures\RateLimits\compatibility-one.json" -Raw | ConvertFrom-Json
        $row = @(ConvertTo-QuotaWindow -RateLimitResult $fixture)[0]

        ($row.PSObject.Properties.Name -join ',') | Should -Be 'Key,LimitId,LimitName,WindowKind,UsedPercent,RemainingPercent,WindowDurationMins,ResetsAt,RateLimitReached'
        $row.Key | Should -BeOfType ([string])
        $row.LimitId | Should -BeOfType ([string])
        $row.LimitName | Should -BeOfType ([string])
        $row.WindowKind | Should -BeOfType ([string])
        $row.UsedPercent | Should -BeOfType ([double])
        $row.RemainingPercent | Should -BeOfType ([double])
        $row.WindowDurationMins | Should -BeOfType ([int])
        $row.ResetsAt | Should -BeOfType ([long])
        $row.RateLimitReached | Should -BeOfType ([string])
    }

    It 'sorts by duration then limit id and removes duplicate keys deterministically' {
        $result = [pscustomobject]@{
            rateLimitsByLimitId = [ordered]@{
                zAlias = [ordered]@{
                    limitId = 'zeta'
                    limitName = 'Zeta'
                    primary = [ordered]@{ usedPercent = 20; windowDurationMins = 60; resetsAt = 200; rateLimitReachedType = 'none' }
                }
                alpha = [ordered]@{
                    limitId = 'alpha'
                    limitName = 'Alpha'
                    primary = [ordered]@{ usedPercent = 30; windowDurationMins = 60; resetsAt = 100; rateLimitReachedType = 'none' }
                }
                duplicateZeta = [ordered]@{
                    limitId = 'zeta'
                    limitName = 'Zeta'
                    primary = [ordered]@{ usedPercent = 20; windowDurationMins = 60; resetsAt = 200; rateLimitReachedType = 'none' }
                }
                short = [ordered]@{
                    limitId = 'short'
                    limitName = 'Short'
                    primary = [ordered]@{ usedPercent = 40; windowDurationMins = 30; resetsAt = 50; rateLimitReachedType = 'none' }
                }
            }
        }

        $rows = @(ConvertTo-QuotaWindow -RateLimitResult $result)

        $rows.Count | Should -Be 3
        $rows.LimitId | Should -Be @('short', 'alpha', 'zeta')
        @($rows.Key | Select-Object -Unique).Count | Should -Be 3
    }

    It 'normalizes invalid, coercive, and non-finite used percentages to null' -ForEach @(
        @{ Value = 'not-a-number' },
        @{ Value = [double]::NaN },
        @{ Value = [double]::PositiveInfinity },
        @{ Value = [double]::NegativeInfinity },
        @{ Value = $true },
        @{ Value = $false },
        @{ Value = [char]'7' },
        @{ Value = [DayOfWeek]::Monday }
    ) {
        $result = [pscustomobject]@{
            rateLimitsByLimitId = [ordered]@{
                sample = [ordered]@{
                    limitId = 'sample'
                    limitName = 'Sample'
                    primary = [ordered]@{
                        usedPercent = $Value
                        windowDurationMins = 60
                        resetsAt = 100
                        rateLimitReachedType = 'none'
                    }
                }
            }
        }

        $row = @(ConvertTo-QuotaWindow -RateLimitResult $result)[0]

        ($null -eq $row.UsedPercent) | Should -BeTrue
        ($null -eq $row.RemainingPercent) | Should -BeTrue
    }

    It 'falls back to typed zero for invalid or out-of-range integral fields' -ForEach @(
        @{ Duration = 'not-a-duration'; Resets = 1; ExpectedDuration = 0; ExpectedResets = 1 },
        @{ Duration = '2147483648'; Resets = 1; ExpectedDuration = 0; ExpectedResets = 1 },
        @{ Duration = 1; Resets = 'not-a-reset'; ExpectedDuration = 1; ExpectedResets = 0 },
        @{ Duration = 1; Resets = '9223372036854775808'; ExpectedDuration = 1; ExpectedResets = 0 }
    ) {
        $result = [pscustomobject]@{
            rateLimitsByLimitId = [ordered]@{
                sample = [ordered]@{
                    limitId = 'sample'
                    limitName = 'Sample'
                    primary = [ordered]@{
                        usedPercent = 20
                        windowDurationMins = $Duration
                        resetsAt = $Resets
                        rateLimitReachedType = 'none'
                    }
                }
            }
        }

        $row = @(ConvertTo-QuotaWindow -RateLimitResult $result)[0]

        $row.WindowDurationMins | Should -Be $ExpectedDuration
        $row.WindowDurationMins | Should -BeOfType ([int])
        $row.ResetsAt | Should -Be $ExpectedResets
        $row.ResetsAt | Should -BeOfType ([long])
    }

    It 'rejects fractional integral window values instead of rounding them' {
        $result = [pscustomobject]@{
            rateLimitsByLimitId = [ordered]@{
                sample = [ordered]@{
                    limitId = 'sample'
                    limitName = 'Sample'
                    primary = [ordered]@{
                        usedPercent = 20
                        windowDurationMins = 60.6
                        resetsAt = 123.4
                        rateLimitReachedType = 'none'
                    }
                }
            }
        }

        $row = @(ConvertTo-QuotaWindow -RateLimitResult $result)[0]

        $row.WindowDurationMins | Should -Be 0
        $row.WindowDurationMins | Should -BeOfType ([int])
        $row.ResetsAt | Should -Be 0
        $row.ResetsAt | Should -BeOfType ([long])
    }

    It 'rejects coercible nonnumeric integral window values' -ForEach @(
        @{ Duration = $true; Resets = $false },
        @{ Duration = [char]'7'; Resets = [char]'8' },
        @{ Duration = [DayOfWeek]::Monday; Resets = [DayOfWeek]::Tuesday }
    ) {
        $result = [pscustomobject]@{
            rateLimitsByLimitId = [ordered]@{
                sample = [ordered]@{
                    limitId = 'sample'
                    limitName = 'Sample'
                    primary = [ordered]@{
                        usedPercent = 20
                        windowDurationMins = $Duration
                        resetsAt = $Resets
                        rateLimitReachedType = 'none'
                    }
                }
            }
        }

        $row = @(ConvertTo-QuotaWindow -RateLimitResult $result)[0]

        $row.WindowDurationMins | Should -Be 0
        $row.ResetsAt | Should -Be 0
    }

    It 'rejects non-finite integral window values' -ForEach @(
        @{ Duration = [double]::NaN; Resets = [double]::NaN },
        @{ Duration = [double]::PositiveInfinity; Resets = [double]::NegativeInfinity }
    ) {
        $result = [pscustomobject]@{
            rateLimitsByLimitId = [ordered]@{
                sample = [ordered]@{
                    limitId = 'sample'
                    limitName = 'Sample'
                    primary = [ordered]@{
                        usedPercent = 20
                        windowDurationMins = $Duration
                        resetsAt = $Resets
                        rateLimitReachedType = 'none'
                    }
                }
            }
        }

        $row = @(ConvertTo-QuotaWindow -RateLimitResult $result)[0]

        $row.WindowDurationMins | Should -Be 0
        $row.ResetsAt | Should -Be 0
    }

    It 'accepts exact numeric primitives and invariant integral strings' -ForEach @(
        @{ Duration = [double]60.0; Resets = [double]123.0 },
        @{ Duration = '60'; Resets = '123' }
    ) {
        $result = [pscustomobject]@{
            rateLimitsByLimitId = [ordered]@{
                sample = [ordered]@{
                    limitId = 'sample'
                    limitName = 'Sample'
                    primary = [ordered]@{
                        usedPercent = 20
                        windowDurationMins = $Duration
                        resetsAt = $Resets
                        rateLimitReachedType = 'none'
                    }
                }
            }
        }

        $row = @(ConvertTo-QuotaWindow -RateLimitResult $result)[0]

        $row.WindowDurationMins | Should -Be 60
        $row.WindowDurationMins | Should -BeOfType ([int])
        $row.ResetsAt | Should -Be 123
        $row.ResetsAt | Should -BeOfType ([long])
    }

    It 'chooses the same canonical collision winner regardless of map order' {
        $lowerCandidate = [ordered]@{
            limitId = 'same'
            limitName = 'Same'
            primary = [ordered]@{ usedPercent = 20; windowDurationMins = 60; resetsAt = 200; rateLimitReachedType = 'Alpha' }
        }
        $higherCandidate = [ordered]@{
            limitId = 'same'
            limitName = 'Same'
            primary = [ordered]@{ usedPercent = 80; windowDurationMins = 60; resetsAt = 200; rateLimitReachedType = 'Zulu' }
        }
        $forward = [pscustomobject]@{
            rateLimitsByLimitId = [ordered]@{ first = $higherCandidate; second = $lowerCandidate }
        }
        $reverse = [pscustomobject]@{
            rateLimitsByLimitId = [ordered]@{ first = $lowerCandidate; second = $higherCandidate }
        }

        $forwardRow = @(ConvertTo-QuotaWindow -RateLimitResult $forward)[0]
        $reverseRow = @(ConvertTo-QuotaWindow -RateLimitResult $reverse)[0]

        $forwardRow.UsedPercent | Should -Be 20
        $forwardRow.RateLimitReached | Should -Be 'Alpha'
        ($forwardRow | ConvertTo-Json -Compress) | Should -Be ($reverseRow | ConvertTo-Json -Compress)
    }

    It 'prefers a complete duplicate over a sparse duplicate regardless of map order' {
        $sparseCandidate = [ordered]@{
            limitId = 'same'
            limitName = ''
            primary = [ordered]@{ usedPercent = $null; windowDurationMins = 60; resetsAt = 200; rateLimitReachedType = '' }
        }
        $completeCandidate = [ordered]@{
            limitId = 'same'
            limitName = 'Codex'
            primary = [ordered]@{ usedPercent = 80; windowDurationMins = 60; resetsAt = 200; rateLimitReachedType = 'none' }
        }
        $sparseFirst = [pscustomobject]@{
            rateLimitsByLimitId = [ordered]@{ first = $sparseCandidate; second = $completeCandidate }
        }
        $completeFirst = [pscustomobject]@{
            rateLimitsByLimitId = [ordered]@{ first = $completeCandidate; second = $sparseCandidate }
        }

        $sparseFirstRow = @(ConvertTo-QuotaWindow -RateLimitResult $sparseFirst)[0]
        $completeFirstRow = @(ConvertTo-QuotaWindow -RateLimitResult $completeFirst)[0]

        $sparseFirstRow.LimitName | Should -Be 'Codex'
        $sparseFirstRow.UsedPercent | Should -Be 80
        $sparseFirstRow.RateLimitReached | Should -Be 'none'
        ($sparseFirstRow | ConvertTo-Json -Compress) | Should -Be ($completeFirstRow | ConvertTo-Json -Compress)
    }

    It 'sorts LimitId with ordinal case-sensitive comparison after duration' {
        $result = [pscustomobject]@{
            rateLimitsByLimitId = [ordered]@{
                lower = [ordered]@{
                    limitId = 'codex'
                    limitName = 'Lower'
                    primary = [ordered]@{ usedPercent = 20; windowDurationMins = 60; resetsAt = 100; rateLimitReachedType = 'none' }
                }
                upper = [ordered]@{
                    limitId = 'Codex'
                    limitName = 'Upper'
                    primary = [ordered]@{ usedPercent = 20; windowDurationMins = 60; resetsAt = 100; rateLimitReachedType = 'none' }
                }
            }
        }

        $rows = @(ConvertTo-QuotaWindow -RateLimitResult $result)

        ($rows.LimitId -join '|') | Should -BeExactly 'Codex|codex'
    }
}

Describe 'Get-RemainingPercent' {
    It 'clamps remaining percent' -ForEach @(
        @{ Used = $null; Remaining = $null },
        @{ Used = -5; Remaining = 100 },
        @{ Used = 25.5; Remaining = 74.5 },
        @{ Used = 140; Remaining = 0 }
    ) {
        Get-RemainingPercent -UsedPercent $Used | Should -Be $Remaining
    }

    It 'returns null for invalid and non-finite input' -ForEach @(
        @{ Used = 'not-a-number' },
        @{ Used = [double]::NaN },
        @{ Used = [double]::PositiveInfinity },
        @{ Used = [double]::NegativeInfinity }
    ) {
        Get-RemainingPercent -UsedPercent $Used | Should -BeNullOrEmpty
    }
}
