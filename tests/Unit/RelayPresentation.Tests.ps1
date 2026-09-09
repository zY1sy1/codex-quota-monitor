BeforeAll {
    . "$PSScriptRoot\..\..\companion\Private\ObjectAccess.ps1"
    . "$PSScriptRoot\..\..\companion\Private\Presentation.ps1"
    $relayPresentationScript = "$PSScriptRoot\..\..\companion\Private\RelayPresentation.ps1"
    if (Test-Path -LiteralPath $relayPresentationScript -PathType Leaf) {
        . $relayPresentationScript
    }

    function New-TestRelayPresentationResult {
        param(
            [bool]$IsValid = $true,
            [AllowNull()][object]$Remaining = [double]18.42,
            [AllowNull()][string]$Unit = 'USD',
            [AllowNull()][string]$PlanName = $null,
            [AllowNull()][object]$Total = $null,
            [AllowNull()][object]$Used = $null,
            [AllowNull()][string]$Extra = $null,
            [AllowNull()][string]$InvalidMessage = $null
        )
        [pscustomobject][ordered]@{
            IsValid = $IsValid
            InvalidMessage = $InvalidMessage
            Remaining = $Remaining
            Unit = $Unit
            PlanName = $PlanName
            Total = $Total
            Used = $Used
            Extra = $Extra
        }
    }

    function New-TestRelayPresentationState {
        param(
            [string]$Status = 'Live',
            [object[]]$Results = @((New-TestRelayPresentationResult)),
            [AllowNull()][object]$LastSuccessAt = ([DateTimeOffset]'2026-08-01T08:00:00Z'),
            [AllowNull()][string]$LastErrorCategory = $null
        )
        [pscustomobject]@{
            ProviderId = 'wkk'
            Status = $Status
            Results = $Results
            LastSuccessAt = $LastSuccessAt
            LastErrorCategory = $LastErrorCategory
        }
    }

    function New-TestSharedRow {
        param(
            [string]$Key,
            [string]$SourceKind,
            [AllowNull()][object]$ProgressValue,
            [string]$ValueText,
            [string]$State = 'Live',
            [bool]$IsStale = $false,
            [string]$Label = 'Quota'
        )
        [pscustomobject][ordered]@{
            Key = $Key
            SourceKind = $SourceKind
            SourceId = if ($SourceKind -eq 'Official') { 'codex' } else { 'wkk' }
            SourceLabel = if ($SourceKind -eq 'Official') { 'Codex 官方' } else { 'Wakaka' }
            GroupLabel = if ($SourceKind -eq 'Official') { 'Codex 官方额度' } else { '中转站额度' }
            Label = $Label
            ValueText = $ValueText
            SecondaryText = ''
            ProgressValue = $ProgressValue
            Countdown = ''
            ResetTime = ''
            IsStale = $IsStale
            UpdatedAt = [DateTimeOffset]'2026-08-01T08:00:00Z'
            State = $State
        }
    }
}

Describe 'relay presentation rows' {
    It 'creates the exact shared row shape and formats a USD plan' {
        $provider = [pscustomobject]@{ Id = 'wkk'; Name = 'Wakaka' }
        $state = New-TestRelayPresentationState -Results @(
            New-TestRelayPresentationResult -PlanName 'Wallet'
        )

        $row = @(ConvertTo-RelayPresentationRow -Provider $provider -State $state)[0]

        ($row.PSObject.Properties.Name -join ',') | Should -BeExactly `
            'Key,SourceKind,SourceId,SourceLabel,GroupLabel,Label,ValueText,SecondaryText,ProgressValue,Countdown,ResetTime,IsStale,UpdatedAt,State'
        $row.Key | Should -BeExactly 'relay:wkk:0'
        $row.SourceKind | Should -BeExactly 'Relay'
        $row.SourceId | Should -BeExactly 'wkk'
        $row.SourceLabel | Should -BeExactly 'Wakaka'
        $row.GroupLabel | Should -BeExactly '中转站额度'
        $row.Label | Should -BeExactly 'Wallet'
        $row.ValueText | Should -BeExactly '$18.42 USD'
        $row.ProgressValue | Should -BeNullOrEmpty
        $row.State | Should -BeExactly 'Live'
    }

    It 'formats currency with two decimals and keeps non-currency units compact' -ForEach @(
        @{ Remaining = [double]50; Unit = 'CNY'; Expected = '¥50.00 CNY' }
        @{ Remaining = [double]120; Unit = 'requests'; Expected = '120 requests' }
        @{ Remaining = [double]0; Unit = 'USD'; Expected = '$0.00 USD' }
    ) {
        $provider = [pscustomobject]@{ Id = 'p'; Name = 'Provider' }
        $state = New-TestRelayPresentationState -Results @(
            New-TestRelayPresentationResult -Remaining $Remaining -Unit $Unit
        )

        $row = @(ConvertTo-RelayPresentationRow -Provider $provider -State $state)[0]

        $row.ValueText | Should -BeExactly $Expected
    }

    It 'rounds currency for display while preserving the source value' {
        $provider = [pscustomobject]@{ Id = 'p'; Name = 'Provider' }
        $result = New-TestRelayPresentationResult -Remaining ([double]18.426) -Unit 'USD'
        $state = New-TestRelayPresentationState -Results @($result)

        $row = @(ConvertTo-RelayPresentationRow -Provider $provider -State $state)[0]

        $row.ValueText | Should -BeExactly '$18.43 USD'
        $result.Remaining | Should -Be 18.426
    }

    It 'derives percentage from remaining over total and clamps only the progress display' {
        $provider = [pscustomobject]@{ Id = 'p'; Name = 'Provider' }
        $state = New-TestRelayPresentationState -Results @(
            New-TestRelayPresentationResult -Remaining ([double]150) -Total ([double]100) -Unit 'USD'
        )

        $row = @(ConvertTo-RelayPresentationRow -Provider $provider -State $state)[0]

        $row.ValueText | Should -BeExactly '$150.00 / $100.00 USD'
        $row.ProgressValue | Should -Be 100
    }

    It 'derives remaining percentage from used over total while retaining used values' {
        $provider = [pscustomobject]@{ Id = 'p'; Name = 'Provider' }
        $state = New-TestRelayPresentationState -Results @(
            New-TestRelayPresentationResult -Remaining $null -Used ([double]30) `
                -Total ([double]100) -Unit 'requests'
        )

        $row = @(ConvertTo-RelayPresentationRow -Provider $provider -State $state)[0]

        $row.ValueText | Should -BeExactly '30 / 100 requests used'
        $row.ProgressValue | Should -Be 70
    }

    It 'marks last-good values stale with the UTC success timestamp and bounded extra text' {
        $provider = [pscustomobject]@{ Id = 'p'; Name = 'Provider' }
        $updatedAt = [DateTimeOffset]'2026-08-01T16:00:00+08:00'
        $state = New-TestRelayPresentationState -Status 'Stale' -LastSuccessAt $updatedAt -Results @(
            New-TestRelayPresentationResult -Extra ('x' * 400)
        )

        $row = @(ConvertTo-RelayPresentationRow -Provider $provider -State $state)[0]

        $row.IsStale | Should -BeTrue
        $row.UpdatedAt | Should -Be ([DateTimeOffset]'2026-08-01T08:00:00Z')
        $row.SecondaryText.Length | Should -Be 256
    }

    It 'creates a status row when an invalid provider has no result data' {
        $provider = [pscustomobject]@{ Id = 'bad'; Name = 'Broken relay' }
        $state = New-TestRelayPresentationState -Status 'InvalidScript' -Results @() -LastSuccessAt $null

        $row = @(ConvertTo-RelayPresentationRow -Provider $provider -State $state)[0]

        $row.Key | Should -BeExactly 'relay:bad:status'
        $row.Label | Should -BeExactly 'Broken relay'
        $row.ValueText | Should -BeExactly '--'
        $row.State | Should -BeExactly 'InvalidScript'
        $row.IsStale | Should -BeFalse
    }

    It 'shows the precise sanitized failure reason' -ForEach @(
        @{ Category='EndpointNotFound'; Expected='余额接口不存在' }
        @{ Category='InvalidJson'; Expected='返回内容不是 JSON' }
        @{ Category='ExtractorExecution'; Expected='返回内容无法解析' }
        @{ Category='ResultValidation'; Expected='余额字段不符合要求' }
        @{ Category='RateLimit'; Expected='查询频率受限' }
        @{ Category='DestinationTrustRequired'; Expected='需要确认目标地址' }
        @{ Category='Authentication'; Expected='需要重新验证凭据' }
        @{ Category='ScriptSyntax'; Expected='查询脚本语法无效' }
        @{ Category='RequestValidation'; Expected='查询请求配置无效' }
    ) {
        $provider = [pscustomobject]@{ Id='relay'; Name='Relay' }
        $state = New-TestRelayPresentationState -Status 'Unavailable' -Results @() `
            -LastSuccessAt $null -LastErrorCategory $Category

        $row = @(ConvertTo-RelayPresentationRow -Provider $provider -State $state)[0]

        $row.SecondaryText | Should -BeExactly $Expected
    }

    It 'shows the precise failure reason while keeping last-good rows stale' {
        $provider = [pscustomobject]@{ Id='relay'; Name='Relay' }
        $state = New-TestRelayPresentationState -Status 'InvalidScript' `
            -LastErrorCategory 'ExtractorExecution'

        $row = @(ConvertTo-RelayPresentationRow -Provider $provider -State $state)[0]

        $row.IsStale | Should -BeTrue
        $row.SecondaryText | Should -BeExactly '返回内容无法解析'
    }

    It 'does not present or rank a mixed invalid result even when it carries a number' {
        $provider = [pscustomobject]@{ Id = 'mixed'; Name = 'Mixed relay' }
        $state = New-TestRelayPresentationState -Results @(
            New-TestRelayPresentationResult -IsValid $true -Remaining ([double]80) `
                -Total ([double]100) -PlanName 'Valid'
            New-TestRelayPresentationResult -IsValid $false -Remaining ([double]1) `
                -Total ([double]100) -PlanName 'Invalid' -InvalidMessage 'account invalid'
        )

        $rows = @(ConvertTo-RelayPresentationRow -Provider $provider -State $state)

        $rows[1].ValueText | Should -BeExactly '--'
        $rows[1].ProgressValue | Should -BeNullOrEmpty
        $rows[1].SecondaryText | Should -BeExactly 'account invalid'
        (Get-CompactFocusRow -Rows $rows -PinnedKey $null).Key | Should -BeExactly $rows[0].Key
    }
}

Describe 'mixed source presentation selection' {
    It 'adapts official rows and preserves deterministic source and input order' {
        $official = [pscustomobject][ordered]@{
            Key = 'official:weekly'
            Label = '周额度'
            RemainingText = '80%'
            ProgressValue = [double]80
            CountdownText = '01:00:00'
            ResetTimeText = '重置时间：2026-08-02 08:00'
        }
        $relayTwo = New-TestSharedRow -Key 'relay:two:0' -SourceKind Relay `
            -ProgressValue ([double]30) -ValueText '30%' -Label 'Two'
        $relayOne = New-TestSharedRow -Key 'relay:one:0' -SourceKind Relay `
            -ProgressValue ([double]20) -ValueText '20%' -Label 'One'

        $rows = Merge-MonitorPresentationRows -OfficialRows @($official) -RelayRows @($relayTwo, $relayOne)

        @($rows | Select-Object -ExpandProperty Key) | Should -Be @(
            'official:weekly', 'relay:two:0', 'relay:one:0'
        )
        ($rows[0].PSObject.Properties.Name -join ',') | Should -BeExactly `
            'Key,SourceKind,SourceId,SourceLabel,GroupLabel,Label,ValueText,SecondaryText,ProgressValue,Countdown,ResetTime,IsStale,UpdatedAt,State,InUse'
        $rows[0].SourceKind | Should -BeExactly 'Official'
        $rows[0].SourceLabel | Should -BeExactly 'Codex 官方'
        $rows[0].InUse | Should -BeFalse
    }

    It 'marks only the relay row that matches the current CC Switch provider' {
        $official = [pscustomobject][ordered]@{
            Key = 'official:5h'
            Label = '5h'
            RemainingText = '47%'
            ProgressValue = [double]47
            CountdownText = '01:00:00'
            ResetTimeText = '重置时间：2026-09-09 18:05'
        }
        $relay = New-TestSharedRow -Key 'relay:wkk:0' -SourceKind Relay `
            -ProgressValue ([double]42) -ValueText '$42 USD' -Label 'Wallet'
        $current = [pscustomobject][ordered]@{
            AppType = 'codex'
            ProviderId = 'cs-wkk'
            Name = 'Wakaka'
        }

        $rows = Merge-MonitorPresentationRows -OfficialRows @($official) -RelayRows @($relay) `
            -CurrentProviders @($current)

        ($rows | Where-Object { $_.SourceKind -eq 'Relay' }).InUse | Should -BeTrue
        ($rows | Where-Object { $_.SourceKind -eq 'Official' }).InUse | Should -BeFalse
    }

    It 'marks the five-hour official row when the CC Switch provider is default' {
        $official5h = [pscustomobject][ordered]@{
            Key = 'codex|primary|300|1788963920'
            Label = '5 小时额度'
            RemainingText = '47%'
            ProgressValue = [double]47
            CountdownText = '01:00:00'
            ResetTimeText = '重置时间：2026-09-09 18:05'
        }
        $officialWeek = [pscustomobject][ordered]@{
            Key = 'codex|secondary|10080|1789467695'
            Label = '周额度'
            RemainingText = '87%'
            ProgressValue = [double]87
            CountdownText = '02:00:00'
            ResetTimeText = '重置时间：2026-09-16 09:01'
        }
        $relay = New-TestSharedRow -Key 'relay:wkk:0' -SourceKind Relay `
            -ProgressValue ([double]42) -ValueText '$42 USD' -Label 'Wallet'
        $current = [pscustomobject][ordered]@{
            AppType = 'codex'
            ProviderId = 'default'
            Name = 'default'
        }

        $rows = Merge-MonitorPresentationRows -OfficialRows @($official5h, $officialWeek) `
            -RelayRows @($relay) -CurrentProviders @($current)

        ($rows | Where-Object { $_.SourceKind -eq 'Official' -and $_.Label -eq '5 小时额度' }).InUse | Should -BeTrue
        ($rows | Where-Object { $_.SourceKind -eq 'Official' -and $_.Label -eq '周额度' }).InUse | Should -BeFalse
    }

    It 'leaves rows unmarked when the current provider is an unmonitored relay' {
        $official = [pscustomobject][ordered]@{
            Key = 'official:5h'
            Label = '5h'
            RemainingText = '47%'
            ProgressValue = [double]47
            CountdownText = '01:00:00'
            ResetTimeText = '重置时间：2026-09-09 18:05'
        }
        $relay = New-TestSharedRow -Key 'relay:wkk:0' -SourceKind Relay `
            -ProgressValue ([double]42) -ValueText '$42 USD' -Label 'Wallet'
        $current = [pscustomobject][ordered]@{
            AppType = 'codex'
            ProviderId = 'cs-other'
            Name = 'DeepSeek'
        }

        $rows = Merge-MonitorPresentationRows -OfficialRows @($official) -RelayRows @($relay) `
            -CurrentProviders @($current)

        @($rows | Where-Object { [bool]$_.InUse }) | Should -HaveCount 0
    }

    It 'chooses the lowest percentage automatically and honors an absolute pinned row' {
        $official80 = New-TestSharedRow -Key 'official:80' -SourceKind Official `
            -ProgressValue ([double]80) -ValueText '80%'
        $relay20 = New-TestSharedRow -Key 'relay:20' -SourceKind Relay `
            -ProgressValue ([double]20) -ValueText '20%'
        $wallet = New-TestSharedRow -Key 'relay:wallet' -SourceKind Relay `
            -ProgressValue $null -ValueText '$18.42 USD'

        (Get-CompactFocusRow -Rows @($official80, $relay20, $wallet) -PinnedKey $null).Key |
            Should -BeExactly $relay20.Key
        (Get-CompactFocusRow -Rows @($official80, $wallet) -PinnedKey $wallet.Key).Key |
            Should -BeExactly $wallet.Key
        Get-CompactFocusRow -Rows @($wallet) -PinnedKey $null | Should -BeNullOrEmpty
    }

    It 'does not fall back when a specific pinned key is missing or unusable' {
        $available = New-TestSharedRow -Key 'relay:available' -SourceKind Relay `
            -ProgressValue ([double]20) -ValueText '20%'
        $missingKey = Get-CompactFocusRow -Rows @($available) -PinnedKey 'official:missing'
        $missingKey | Should -BeNullOrEmpty

        $invalid = New-TestSharedRow -Key 'official:invalid' -SourceKind Official `
            -ProgressValue $null -ValueText '--%' -State AuthRequired
        $invalidResult = Get-CompactFocusRow -Rows @($invalid, $available) -PinnedKey $invalid.Key
        $invalidResult | Should -BeNullOrEmpty
    }

    It 'uses the worst comparable percentage and reports stale separately from severity' {
        $official = New-TestSharedRow -Key 'official:80' -SourceKind Official `
            -ProgressValue ([double]80) -ValueText '80%'
        $staleRelay = New-TestSharedRow -Key 'relay:10' -SourceKind Relay `
            -ProgressValue ([double]10) -ValueText '10%' -IsStale $true -State Stale

        $severity = Get-CombinedQuotaSeverity -Rows @($official, $staleRelay)

        $severity.Severity | Should -BeExactly 'Red'
        $severity.HasStale | Should -BeTrue
        $severity.HasUsableData | Should -BeTrue
    }

    It 'does not rank incompatible absolute units and keeps usable absolute data non-gray' {
        $usd = New-TestSharedRow -Key 'relay:usd' -SourceKind Relay `
            -ProgressValue $null -ValueText '$5 USD'
        $cny = New-TestSharedRow -Key 'relay:cny' -SourceKind Relay `
            -ProgressValue $null -ValueText '¥1 CNY'

        Get-CompactFocusRow -Rows @($usd, $cny) -PinnedKey $null | Should -BeNullOrEmpty
        (Get-CombinedQuotaSeverity -Rows @($usd, $cny)).Severity | Should -BeExactly 'Green'
    }

    It 'keeps last-good InvalidScript data usable as stale' {
        $row = New-TestSharedRow -Key 'relay:stale' -SourceKind Relay `
            -ProgressValue ([double]25) -ValueText '25%' -State InvalidScript -IsStale $true

        (Get-CompactFocusRow -Rows @($row) -PinnedKey $null).Key | Should -BeExactly $row.Key
        $severity = Get-CombinedQuotaSeverity -Rows @($row)
        $severity.Severity | Should -BeExactly 'Yellow'
        $severity.HasStale | Should -BeTrue
    }

    It 'treats official unknown percentage text as unavailable data' {
        $row = New-TestSharedRow -Key 'official:unknown' -SourceKind Official `
            -ProgressValue $null -ValueText '--%'

        Get-CompactFocusRow -Rows @($row) -PinnedKey $row.Key | Should -BeNullOrEmpty
        (Get-CombinedQuotaSeverity -Rows @($row)).Severity | Should -BeExactly 'Gray'
    }

    It 'builds a bounded tooltip from official focus and at most two relays' {
        $official = New-TestSharedRow -Key 'official:80' -SourceKind Official `
            -ProgressValue ([double]80) -ValueText '80%' -Label '5h'
        $relayOne = New-TestSharedRow -Key 'relay:one' -SourceKind Relay `
            -ProgressValue ([double]20) -ValueText '20%' -Label 'Wakaka'
        $relayTwo = New-TestSharedRow -Key 'relay:two' -SourceKind Relay `
            -ProgressValue $null -ValueText '$18 USD' -Label 'Wallet'
        $relayThree = New-TestSharedRow -Key 'relay:three' -SourceKind Relay `
            -ProgressValue ([double]5) -ValueText '5%' -Label 'Excluded'

        $tooltip = Get-CombinedTrayTooltip -Rows @($official, $relayOne, $relayTwo, $relayThree)

        $tooltip.Length | Should -BeLessOrEqual 63
        $tooltip | Should -Match '5h 80%'
        $tooltip | Should -Match 'Wakaka 20%'
        $tooltip | Should -Match 'Wallet \$18 USD'
        $tooltip | Should -Not -Match 'Excluded'
    }
}
