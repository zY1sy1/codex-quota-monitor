BeforeAll {
    $settingsScript = "$PSScriptRoot\..\..\companion\Private\Settings.ps1"
    $cacheScript = "$PSScriptRoot\..\..\companion\Private\RelayCache.ps1"
    . $settingsScript
    if (Test-Path -LiteralPath $cacheScript -PathType Leaf) {
        . $cacheScript
    }

    function New-TestRelayCacheResult {
        param(
            [AllowNull()][object]$Remaining = [double]18.42,
            [AllowNull()][string]$Extra = $null
        )
        [ordered]@{
            IsValid = $true
            InvalidMessage = $null
            Remaining = $Remaining
            Unit = 'USD'
            PlanName = $null
            Total = $null
            Used = $null
            Extra = $Extra
        }
    }

    function New-TestRelayCache {
        param(
            [object[]]$Results = [object[]]@(New-TestRelayCacheResult)
        )
        [ordered]@{
            SchemaVersion = 1
            Providers = [object[]]@(
                [ordered]@{
                    ProviderId = 'wkk'
                    UpdatedAt = '2026-08-01T08:00:00.0000000+00:00'
                    Results = $Results
                }
            )
        }
    }
}

Describe 'relay last-good cache persistence' {
    It 'round-trips only normalized last-good fields and preserves explicit zero' {
        $path = Join-Path $TestDrive 'round-trip\relay-cache.json'
        $cache = New-TestRelayCache -Results @(
            New-TestRelayCacheResult -Remaining ([double]0)
        )

        Write-RelayCache -Path $path -Cache $cache

        $json = [IO.File]::ReadAllText($path)
        $json | Should -Not -Match 'script|header|response|token|secret'
        $loaded = Read-RelayCache -Path $path
        $loaded.Providers[0].Results[0].Remaining | Should -Be 0
        $loaded.Providers[0].Results[0].Remaining | Should -BeOfType ([double])
        ($loaded.Providers[0].Results[0].Keys -join ',') |
            Should -BeExactly 'IsValid,InvalidMessage,Remaining,Unit,PlanName,Total,Used,Extra'
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -File -Filter '*.tmp').Count |
            Should -Be 0
    }

    It 'normalizes update timestamps to invariant UTC ISO-8601' {
        $cache = New-TestRelayCache
        $cache.Providers[0]['UpdatedAt'] = '2026-08-01T16:00:00+08:00'

        $canonical = ConvertTo-CanonicalRelayCache -Cache $cache

        $canonical.Providers[0].UpdatedAt |
            Should -BeExactly '2026-08-01T08:00:00.0000000+00:00'
    }

    It 'accepts parsed date objects and normalizes them to UTC' {
        $dateTimeCache = New-TestRelayCache
        $dateTimeCache.Providers[0]['UpdatedAt'] = [DateTime]'2026-08-01T08:00:00Z'
        $offsetCache = New-TestRelayCache
        $offsetCache.Providers[0]['UpdatedAt'] = [DateTimeOffset]'2026-08-01T16:00:00+08:00'

        $dateTimeCanonical = ConvertTo-CanonicalRelayCache -Cache $dateTimeCache
        $offsetCanonical = ConvertTo-CanonicalRelayCache -Cache $offsetCache

        $dateTimeCanonical.Providers[0].UpdatedAt |
            Should -BeExactly '2026-08-01T08:00:00.0000000+00:00'
        $offsetCanonical.Providers[0].UpdatedAt |
            Should -BeExactly '2026-08-01T08:00:00.0000000+00:00'
    }

    It 'returns a fresh empty cache when the file is absent' {
        $path = Join-Path $TestDrive 'missing\relay-cache.json'
        $first = Read-RelayCache -Path $path
        $first.Providers += (New-TestRelayCache).Providers
        $second = Read-RelayCache -Path $path

        @($second.Providers).Count | Should -Be 0
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'quarantines unknown fields, invalid dates, invalid numbers, and oversized strings' -ForEach @(
        @{ Name = 'unknown'; Mutate = { param($cache) $cache.Providers[0].Results[0]['RawResponse'] = '{}' } }
        @{ Name = 'date'; Mutate = { param($cache) $cache.Providers[0]['UpdatedAt'] = 'not-a-date' } }
        @{ Name = 'culture-date'; Mutate = { param($cache) $cache.Providers[0]['UpdatedAt'] = '08/01/2026 08:00:00' } }
        @{ Name = 'date-only'; Mutate = { param($cache) $cache.Providers[0]['UpdatedAt'] = '2026-08-01' } }
        @{ Name = 'space-date'; Mutate = { param($cache) $cache.Providers[0]['UpdatedAt'] = '2026-08-01 08:00:00Z' } }
        @{
            Name = 'padded-date'
            Mutate = {
                param($cache)
                $timestamp = '2026-08-01T08:00:00Z'
                $cache.Providers[0]['UpdatedAt'] = $timestamp + (' ' * (4097 - $timestamp.Length))
            }
        }
        @{ Name = 'number'; Mutate = { param($cache) $cache.Providers[0].Results[0]['Remaining'] = '18.42' } }
        @{ Name = 'string'; Mutate = { param($cache) $cache.Providers[0].Results[0]['Extra'] = 'x' * 4097 } }
    ) {
        $path = Join-Path $TestDrive "$Name\relay-cache.json"
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        $cache = New-TestRelayCache
        & $Mutate $cache
        $evidence = $cache | ConvertTo-Json -Depth 8 -Compress
        [IO.File]::WriteAllText($path, $evidence, [Text.UTF8Encoding]::new($false))

        $loaded = Read-RelayCache -Path $path -Now ([DateTimeOffset]'2026-08-02T02:03:04.005Z')

        @($loaded.Providers).Count | Should -Be 0
        Test-Path -LiteralPath $path | Should -BeFalse
        [IO.File]::ReadAllText("$path.corrupt-20260802T020304005Z") |
            Should -BeExactly $evidence
    }

    It 'quarantines malformed JSON and returns an empty cache' {
        $path = Join-Path $TestDrive 'malformed-json\relay-cache.json'
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        $evidence = '{ definitely-not-json'
        [IO.File]::WriteAllText($path, $evidence, [Text.UTF8Encoding]::new($false))

        $loaded = Read-RelayCache -Path $path -Now ([DateTimeOffset]'2026-08-02T02:03:04.005Z')

        @($loaded.Providers).Count | Should -Be 0
        Test-Path -LiteralPath $path | Should -BeFalse
        [IO.File]::ReadAllText("$path.corrupt-20260802T020304005Z") |
            Should -BeExactly $evidence
    }

    It 'rejects provider and result collections beyond the fixed caps' {
        $tooManyProviders = [ordered]@{
            SchemaVersion = 1
            Providers = [object[]]@(foreach ($index in 0..100) {
                [ordered]@{
                    ProviderId = "provider-$index"
                    UpdatedAt = '2026-08-01T08:00:00Z'
                    Results = [object[]]@(New-TestRelayCacheResult)
                }
            })
        }
        $tooManyResults = New-TestRelayCache -Results ([object[]]@(
            foreach ($index in 0..32) { New-TestRelayCacheResult -Remaining ([double]$index) }
        ))

        ConvertTo-CanonicalRelayCache -Cache $tooManyProviders | Should -BeNullOrEmpty
        ConvertTo-CanonicalRelayCache -Cache $tooManyResults | Should -BeNullOrEmpty
    }

    It 'accepts provider, result, and string collections exactly at their caps' {
        $results = [object[]]@(
            foreach ($index in 0..31) {
                New-TestRelayCacheResult -Remaining ([double]$index) -Extra ('x' * 4096)
            }
        )
        $cache = [ordered]@{
            SchemaVersion = 1
            Providers = [object[]]@(
                foreach ($index in 0..99) {
                    [ordered]@{
                        ProviderId = "provider-$index"
                        UpdatedAt = '2026-08-01T16:00:00+08:00'
                        Results = $results
                    }
                }
            )
        }

        $canonical = ConvertTo-CanonicalRelayCache -Cache $cache

        @($canonical.Providers).Count | Should -Be 100
        @($canonical.Providers[0].Results).Count | Should -Be 32
        $canonical.Providers[0].Results[0].Extra.Length | Should -Be 4096
    }

    It 'rejects an invalid caller cache with a constant message and no file' {
        $path = Join-Path $TestDrive 'invalid-write\relay-cache.json'
        $cache = New-TestRelayCache
        $cache.Providers[0].Results[0]['Authorization'] = 'secret-sentinel'

        { Write-RelayCache -Path $path -Cache $cache } |
            Should -Throw -ExpectedMessage 'Relay cache does not match the supported schema.'
        Test-Path -LiteralPath $path | Should -BeFalse
    }
}
