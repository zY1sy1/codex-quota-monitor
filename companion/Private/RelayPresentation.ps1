function Format-RelayPresentationNumber {
    param([Parameter(Mandatory)][double]$Value)
    return $Value.ToString('0.########', [Globalization.CultureInfo]::InvariantCulture)
}

function Format-RelayPresentationAmount {
    param(
        [Parameter(Mandatory)][double]$Value,
        [AllowNull()][string]$Unit
    )
    $number = Format-RelayPresentationNumber $Value
    switch -Regex ($Unit) {
        '^USD$' { return "`$$number USD" }
        '^CNY$' { return "¥$number CNY" }
        default {
            if ([string]::IsNullOrWhiteSpace($Unit)) {
                return $number
            }
            return "$number $Unit"
        }
    }
}

function Format-RelayPresentationRatio {
    param(
        [Parameter(Mandatory)][double]$First,
        [Parameter(Mandatory)][double]$Total,
        [AllowNull()][string]$Unit,
        [switch]$Used
    )
    $firstText = Format-RelayPresentationNumber $First
    $totalText = Format-RelayPresentationNumber $Total
    $suffix = if ($Used) { ' used' } else { '' }
    switch -Regex ($Unit) {
        '^USD$' { return "`$$firstText / `$$totalText USD$suffix" }
        '^CNY$' { return "¥$firstText / ¥$totalText CNY$suffix" }
        default {
            $unitText = if ([string]::IsNullOrWhiteSpace($Unit)) { '' } else { " $Unit" }
            return "$firstText / $totalText$unitText$suffix"
        }
    }
}

function Get-RelayPresentationFiniteNumber {
    param([AllowNull()][object]$Value)
    return ConvertTo-InvariantFiniteDouble -Value $Value
}

function New-RelaySharedPresentationRow {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$SourceId,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ValueText,
        [AllowEmptyString()][string]$SecondaryText = '',
        [AllowNull()][object]$ProgressValue = $null,
        [bool]$IsStale = $false,
        [AllowNull()][object]$UpdatedAt = $null,
        [Parameter(Mandatory)][string]$State
    )
    [pscustomobject][ordered]@{
        Key = $Key
        SourceKind = 'Relay'
        SourceId = $SourceId
        GroupLabel = '中转站额度'
        Label = $Label
        ValueText = $ValueText
        SecondaryText = $SecondaryText
        ProgressValue = $ProgressValue
        Countdown = ''
        ResetTime = ''
        IsStale = $IsStale
        UpdatedAt = $UpdatedAt
        State = $State
    }
}

function Get-RelayStatusSecondaryText {
    param([Parameter(Mandatory)][string]$Status)
    switch ($Status) {
        'Starting' { return '等待首次查询' }
        'AuthRequired' { return '需要重新验证凭据' }
        'InvalidScript' { return '脚本或配置无效' }
        'Unavailable' { return '暂无可用数据' }
        'Disabled' { return '已停用' }
        default { return '' }
    }
}

function ConvertTo-RelayPresentationRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][object]$State
    )
    $providerId = [string](Get-ObjectField -InputObject $Provider -Name 'Id')
    $providerName = [string](Get-ObjectField -InputObject $Provider -Name 'Name')
    $status = [string](Get-ObjectField -InputObject $State -Name 'Status')
    if ([string]::IsNullOrWhiteSpace($providerName)) {
        $providerName = $providerId
    }
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = 'Unavailable'
    }
    $lastSuccessValue = Get-ObjectField -InputObject $State -Name 'LastSuccessAt'
    $updatedAt = if ($null -eq $lastSuccessValue) {
        $null
    }
    else {
        try { ([DateTimeOffset]$lastSuccessValue).ToUniversalTime() } catch { $null }
    }
    $results = @(Get-ObjectField -InputObject $State -Name 'Results')
    if ($results.Count -eq 0) {
        New-RelaySharedPresentationRow -Key "relay:$providerId`:status" `
            -SourceId $providerId -Label $providerName -ValueText '--' `
            -SecondaryText (Get-RelayStatusSecondaryText $status) `
            -IsStale $false -UpdatedAt $updatedAt -State $status
        return
    }

    for ($index = 0; $index -lt $results.Count; $index++) {
        $result = $results[$index]
        $planName = [string](Get-ObjectField -InputObject $result -Name 'PlanName')
        $label = if ([string]::IsNullOrWhiteSpace($planName)) { $providerName } else { $planName }
        $unit = [string](Get-ObjectField -InputObject $result -Name 'Unit')
        $remaining = Get-RelayPresentationFiniteNumber (
            Get-ObjectField -InputObject $result -Name 'Remaining'
        )
        $total = Get-RelayPresentationFiniteNumber (
            Get-ObjectField -InputObject $result -Name 'Total'
        )
        $used = Get-RelayPresentationFiniteNumber (
            Get-ObjectField -InputObject $result -Name 'Used'
        )
        $isValid = [bool](Get-ObjectField -InputObject $result -Name 'IsValid')
        $progress = $null
        $valueText = '--'
        if ($isValid -and $null -ne $remaining) {
            if ($null -ne $total -and $total -gt 0) {
                $valueText = Format-RelayPresentationRatio -First $remaining -Total $total -Unit $unit
                $progress = [Math]::Max(0, [Math]::Min(100, ($remaining / $total) * 100))
            }
            else {
                $valueText = Format-RelayPresentationAmount -Value $remaining -Unit $unit
            }
        }
        elseif ($isValid -and $null -ne $used -and $null -ne $total -and $total -gt 0) {
            $valueText = Format-RelayPresentationRatio -First $used -Total $total -Unit $unit -Used
            $progress = [Math]::Max(0, [Math]::Min(100, (($total - $used) / $total) * 100))
        }

        $extra = [string](Get-ObjectField -InputObject $result -Name 'Extra')
        if ([string]::IsNullOrEmpty($extra) -and
            -not [bool](Get-ObjectField -InputObject $result -Name 'IsValid')) {
            $extra = [string](Get-ObjectField -InputObject $result -Name 'InvalidMessage')
        }
        $secondary = Limit-TextElementLength -Text $extra -MaximumLength 256
        $isStale = $status -ne 'Live' -and $null -ne $updatedAt
        New-RelaySharedPresentationRow -Key "relay:$providerId`:$index" `
            -SourceId $providerId -Label $label -ValueText $valueText `
            -SecondaryText $secondary -ProgressValue $progress -IsStale $isStale `
            -UpdatedAt $updatedAt -State $status
    }
}

function Copy-MonitorPresentationRow {
    param([Parameter(Mandatory)][object]$Row)
    [pscustomobject][ordered]@{
        Key = [string](Get-ObjectField -InputObject $Row -Name 'Key')
        SourceKind = [string](Get-ObjectField -InputObject $Row -Name 'SourceKind')
        SourceId = [string](Get-ObjectField -InputObject $Row -Name 'SourceId')
        GroupLabel = [string](Get-ObjectField -InputObject $Row -Name 'GroupLabel')
        Label = [string](Get-ObjectField -InputObject $Row -Name 'Label')
        ValueText = [string](Get-ObjectField -InputObject $Row -Name 'ValueText')
        SecondaryText = [string](Get-ObjectField -InputObject $Row -Name 'SecondaryText')
        ProgressValue = Get-ObjectField -InputObject $Row -Name 'ProgressValue'
        Countdown = [string](Get-ObjectField -InputObject $Row -Name 'Countdown')
        ResetTime = [string](Get-ObjectField -InputObject $Row -Name 'ResetTime')
        IsStale = [bool](Get-ObjectField -InputObject $Row -Name 'IsStale')
        UpdatedAt = Get-ObjectField -InputObject $Row -Name 'UpdatedAt'
        State = [string](Get-ObjectField -InputObject $Row -Name 'State')
    }
}

function Merge-MonitorPresentationRows {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$OfficialRows = @(),
        [AllowEmptyCollection()][object[]]$RelayRows = @()
    )
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($row in @($OfficialRows)) {
        if ($null -ne $row) {
            $rows.Add((ConvertTo-OfficialMonitorPresentationRow -Row $row))
        }
    }
    foreach ($row in @($RelayRows)) {
        if ($null -ne $row) {
            $rows.Add((Copy-MonitorPresentationRow $row))
        }
    }
    return [object[]]$rows.ToArray()
}

function Test-MonitorPresentationRowUsable {
    param([AllowNull()][object]$Row)
    if ($null -eq $Row) {
        return $false
    }
    $valueText = [string](Get-ObjectField $Row 'ValueText')
    if ([string]::IsNullOrWhiteSpace($valueText) -or $valueText -in @('--', '--%')) {
        return $false
    }
    $state = [string](Get-ObjectField $Row 'State')
    return $state -ne 'Disabled'
}

function Get-CompactFocusRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [AllowNull()][string]$PinnedKey = $null
    )
    if (-not [string]::IsNullOrWhiteSpace($PinnedKey)) {
        foreach ($row in @($Rows)) {
            if ([string](Get-ObjectField $row 'Key') -ceq $PinnedKey -and
                (Test-MonitorPresentationRowUsable $row)) {
                return $row
            }
        }
    }
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($row in @($Rows)) {
        if (-not (Test-MonitorPresentationRowUsable $row)) {
            continue
        }
        $progress = ConvertTo-InvariantFiniteDouble -Value (
            Get-ObjectField $row 'ProgressValue'
        )
        if ($null -ne $progress -and $progress -ge 0 -and $progress -le 100) {
            $candidates.Add([pscustomobject]@{
                Row = $row
                Progress = $progress
                Key = [string](Get-ObjectField $row 'Key')
            })
        }
    }
    if ($candidates.Count -eq 0) {
        return $null
    }
    return ($candidates | Sort-Object Progress, Key | Select-Object -First 1).Row
}

function Get-CombinedQuotaSeverity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    $usable = @($Rows | Where-Object { Test-MonitorPresentationRowUsable $_ })
    $progressValues = @(
        foreach ($row in $usable) {
            $value = ConvertTo-InvariantFiniteDouble -Value (
                Get-ObjectField $row 'ProgressValue'
            )
            if ($null -ne $value -and $value -ge 0 -and $value -le 100) {
                $value
            }
        }
    )
    $severity = if ($progressValues.Count -gt 0) {
        Get-QuotaSeverity -MinimumRemaining ($progressValues | Measure-Object -Minimum).Minimum
    }
    elseif ($usable.Count -gt 0) {
        'Green'
    }
    else {
        'Gray'
    }
    [pscustomobject][ordered]@{
        Severity = $severity
        HasStale = @($usable | Where-Object { [bool](Get-ObjectField $_ 'IsStale') }).Count -gt 0
        HasUsableData = $usable.Count -gt 0
    }
}

function Get-CombinedTrayTooltip {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    $official = @($Rows | Where-Object {
        [string](Get-ObjectField $_ 'SourceKind') -eq 'Official' -and
        (Test-MonitorPresentationRowUsable $_)
    })
    $relay = @($Rows | Where-Object {
        [string](Get-ObjectField $_ 'SourceKind') -eq 'Relay' -and
        (Test-MonitorPresentationRowUsable $_)
    })
    $selected = [Collections.Generic.List[object]]::new()
    if ($official.Count -gt 0) {
        $officialFocus = Get-CompactFocusRow -Rows $official
        if ($null -eq $officialFocus) {
            $officialFocus = $official[0]
        }
        $selected.Add($officialFocus)
    }
    foreach ($row in @($relay | Select-Object -First 2)) {
        $selected.Add($row)
    }
    $entries = foreach ($row in $selected) {
        $label = [string](Get-ObjectField $row 'Label')
        $value = [string](Get-ObjectField $row 'ValueText')
        "$label $value".Trim()
    }
    Limit-TextElementLength -Text ($entries -join ' | ') -MaximumLength 63
}
