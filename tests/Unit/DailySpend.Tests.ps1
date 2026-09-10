BeforeAll {
    $setup = @(
        'ObjectAccess.ps1',
        'RelayPresentation.ps1',
        'Settings.ps1',
        'DailySpend.ps1'
    ) | ForEach-Object { Join-Path $PSScriptRoot '..\..\companion\Private\' $_ }
    foreach ($path in $setup) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            . $path
        }
    }

    function New-TestSpendState {
        param(
            [string]$ProviderId,
            [string]$Status = 'Live',
            [AllowNull()][object]$Remaining = 100.0,
            [AllowNull()][string]$Unit = 'USD',
            [bool]$IsValid = $true,
            [AllowNull()][object]$Total = $null
        )
        $result = [pscustomobject][ordered]@{
            IsValid = $IsValid
            InvalidMessage = $null
            Remaining = $Remaining
            Unit = $Unit
            PlanName = $null
            Total = $Total
            Used = $null
            Extra = $null
        }
        [pscustomobject][ordered]@{
            ProviderId = $ProviderId
            Status = $Status
            Results = [object[]]@($result)
        }
    }
}

Describe 'daily spend store' {
    It 'round-trips a canonical document through read and write' {
        $directory = Join-Path $TestDrive 'store'
        $path = Join-Path $directory 'daily-spend.json'
        $doc = ConvertTo-CanonicalDailySpendDocument ([ordered]@{
            SchemaVersion = 1
            Date = '2026-09-08'
            Providers = [ordered]@{ 'wakaka' = 113.08; 'sub2' = 514.05 }
        })
        $doc | Should -Not -BeNullOrEmpty
        Write-DailySpendStore -Path $path -Document $doc

        $loaded = Read-DailySpendStore -Path $path
        $loaded.SchemaVersion | Should -Be 1
        $loaded.Date | Should -BeExactly '2026-09-08'
        $loaded.Providers['wakaka'] | Should -Be 113.08
        $loaded.Providers['sub2'] | Should -Be 514.05
    }

    It 'recovers an empty document from a corrupt file' {
        $directory = Join-Path $TestDrive 'corrupt'
        $path = Join-Path $directory 'daily-spend.json'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [IO.File]::WriteAllText($path, '{not valid json')
        $loaded = Read-DailySpendStore -Path $path
        $loaded.SchemaVersion | Should -Be 1
        @($loaded.Providers.Keys).Count | Should -Be 0
    }

    It 'rejects a malformed document schema' {
        ConvertTo-CanonicalDailySpendDocument ([ordered]@{
            SchemaVersion = 9
            Date = ''
            Providers = [ordered]@{}
        }) | Should -BeNullOrEmpty
        ConvertTo-CanonicalDailySpendDocument ([ordered]@{
            SchemaVersion = 1
            Date = '09/08/2026'
            Providers = [ordered]@{}
        }) | Should -BeNullOrEmpty
        ConvertTo-CanonicalDailySpendDocument ([ordered]@{
            SchemaVersion = 1
            Date = ''
            Providers = [ordered]@{ 'wakaka' = -1 }
        }) | Should -BeNullOrEmpty
    }
}

Describe 'resolve daily spend rows' {
    BeforeEach {
        $script:Now = [DateTimeOffset]::Now
        $states = [ordered]@{}
        $states['wakaka'] = New-TestSpendState -ProviderId 'wakaka' -Remaining 113.08
        $states['sub2'] = New-TestSpendState -ProviderId 'sub2' -Remaining 514.05
        $script:States = $states
    }

    It 'establishes a peak on first sight and shows zero burn' {
        $result = Resolve-RelayDailySpendRows -States $script:States `
            -Document (New-EmptyDailySpendDocument) -Now $script:Now -ShowEnabled $true
        @($result.Rows).Count | Should -Be 1
        $result.Rows[0].ValueText | Should -BeExactly '$0.00 USD'
        $result.Changed | Should -BeTrue
        $result.Store.Providers['wakaka'] | Should -Be 113.08
        $result.Store.Providers['sub2'] | Should -Be 514.05
    }

    It 'accumulates the day burn across providers' {
        $first = Resolve-RelayDailySpendRows -States $script:States `
            -Document (New-EmptyDailySpendDocument) -Now $script:Now -ShowEnabled $true
        $script:States['wakaka'].Results[0].Remaining = 103.08
        $script:States['sub2'].Results[0].Remaining = 500.0
        $second = Resolve-RelayDailySpendRows -States $script:States `
            -Document $first.Store -Now $script:Now -ShowEnabled $true
        $second.Rows[0].ValueText | Should -BeExactly '$24.05 USD'
        $second.Changed | Should -BeFalse
    }

    It 'resets a provider to zero when its balance tops up above the peak' {
        $first = Resolve-RelayDailySpendRows -States $script:States `
            -Document (New-EmptyDailySpendDocument) -Now $script:Now -ShowEnabled $true
        $script:States['wakaka'].Results[0].Remaining = 103.08
        $second = Resolve-RelayDailySpendRows -States $script:States `
            -Document $first.Store -Now $script:Now -ShowEnabled $true
        $second.Rows[0].ValueText | Should -BeExactly '$10.00 USD'
        # wakaka tops up above its peak -> its own burn resets, sub2 untouched
        $script:States['wakaka'].Results[0].Remaining = 130.0
        $third = Resolve-RelayDailySpendRows -States $script:States `
            -Document $second.Store -Now $script:Now -ShowEnabled $true
        $third.Rows[0].ValueText | Should -BeExactly '$0.00 USD'
    }

    It 'clears the store when the local date rolls over' {
        $first = Resolve-RelayDailySpendRows -States $script:States `
            -Document (New-EmptyDailySpendDocument) -Now $script:Now -ShowEnabled $true
        $first.Store.Date | Should -Not -BeNullOrEmpty
        $tomorrow = $script:Now.AddDays(1)
        $second = Resolve-RelayDailySpendRows -States $script:States `
            -Document $first.Store -Now $tomorrow -ShowEnabled $true
        $second.Changed | Should -BeTrue
        $second.Rows[0].ValueText | Should -BeExactly '$0.00 USD'
        $second.Store.Date | Should -Be (
            $tomorrow.ToLocalTime().ToString('yyyy-MM-dd')
        )
    }

    It 'ignores non-live and non-USD providers' {
        $states = [ordered]@{}
        $states['dead'] = New-TestSpendState -ProviderId 'dead' -Status 'Stale' -Remaining 50.0
        $states['pct'] = New-TestSpendState -ProviderId 'pct' -Status 'Live' -Remaining 80.0 -Unit '%'
        $states['usd'] = New-TestSpendState -ProviderId 'usd' -Status 'Live' -Remaining 90.0
        $result = Resolve-RelayDailySpendRows -States $states `
            -Document (New-EmptyDailySpendDocument) -Now $script:Now -ShowEnabled $true
        @($result.Rows).Count | Should -Be 1
        $result.Rows[0].ValueText | Should -BeExactly '$0.00 USD'
        @($result.Store.Providers.Keys) | Should -Be @('usd')
    }

    It 'ignores a capped USD plan counter that would falsely count a reset' {
        $states = [ordered]@{}
        $states['capped'] = New-TestSpendState -ProviderId 'capped' -Status 'Live' `
            -Remaining 42.0 -Total 100.0
        $states['wallet'] = New-TestSpendState -ProviderId 'wallet' -Status 'Live' `
            -Remaining 90.0
        $result = Resolve-RelayDailySpendRows -States $states `
            -Document (New-EmptyDailySpendDocument) -Now $script:Now -ShowEnabled $true
        @($result.Rows).Count | Should -Be 1
        $result.Rows[0].ValueText | Should -BeExactly '$0.00 USD'
        @($result.Store.Providers.Keys) | Should -Be @('wallet')
    }

    It 'returns no row when the display is disabled' {
        $result = Resolve-RelayDailySpendRows -States $script:States `
            -Document (New-EmptyDailySpendDocument) -Now $script:Now -ShowEnabled $false
        @($result.Rows).Count | Should -Be 0
        $result.Changed | Should -BeFalse
    }

    It 'returns no row when no provider reports a usable USD balance' {
        $states = [ordered]@{}
        $states['pct'] = New-TestSpendState -ProviderId 'pct' -Status 'Live' -Remaining 80.0 -Unit '%'
        $states['invalid'] = New-TestSpendState -ProviderId 'invalid' -Status 'Live' -Remaining 40.0 -IsValid $false
        $result = Resolve-RelayDailySpendRows -States $states `
            -Document (New-EmptyDailySpendDocument) -Now $script:Now -ShowEnabled $true
        @($result.Rows).Count | Should -Be 0
    }
}
