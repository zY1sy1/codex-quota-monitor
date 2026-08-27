function ConvertTo-QuotaDisplayValueText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Text
    )

    # Views show the amount without the trailing currency unit; the unit stays
    # in the hover tooltip, which renders the raw presentation text.
    return [regex]::Replace($Text, '\s+[A-Z]{3,4}(\s+used)?\s*$', '$1').Trim()
}

function Get-QuotaLabel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [int]$WindowDurationMins,

        [Parameter(Position = 1)]
        [AllowNull()]
        [string]$LimitName
    )

    if ($WindowDurationMins -ge 270 -and $WindowDurationMins -le 330) {
        return '5 小时额度'
    }

    if ($WindowDurationMins -ge 9000 -and $WindowDurationMins -le 11000) {
        return '周额度'
    }

    if (-not [string]::IsNullOrWhiteSpace($LimitName)) {
        return $LimitName
    }

    return "其他额度 · $WindowDurationMins 分钟"
}

function Format-ResetCountdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [long]$ResetsAt,

        [Parameter(Position = 1)]
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    $minimumUnixSeconds = [DateTimeOffset]::MinValue.ToUnixTimeSeconds()
    $maximumUnixSeconds = [DateTimeOffset]::MaxValue.ToUnixTimeSeconds()
    if ($ResetsAt -lt $minimumUnixSeconds -or $ResetsAt -gt $maximumUnixSeconds) {
        return '重置时间未知'
    }

    $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($ResetsAt)
    $timeRemaining = $resetTime - $Now.ToUniversalTime()
    if ($timeRemaining.TotalSeconds -le 0) {
        return '正在刷新'
    }

    [long]$totalSeconds = [Math]::Floor($timeRemaining.TotalSeconds)

    [long]$days = [Math]::Floor($totalSeconds / 86400.0)
    [long]$remainder = $totalSeconds % 86400
    [long]$hours = [Math]::Floor($remainder / 3600.0)
    [long]$minutes = [Math]::Floor(($remainder % 3600) / 60.0)
    [long]$seconds = $remainder % 60

    if ($days -ge 1) {
        return '{0}天 {1:00}:{2:00}:{3:00}' -f $days, $hours, $minutes, $seconds
    }

    return '{0:00}:{1:00}:{2:00}' -f $hours, $minutes, $seconds
}

function ConvertTo-ValidQuotaUnixSeconds {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    [long]$unixSeconds = 0
    try {
        if ($Value -is [string]) {
            if (-not [long]::TryParse(
                $Value,
                [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$unixSeconds
            )) {
                return $null
            }
        }
        elseif (Test-IsNumericClrPrimitive -Value $Value) {
            if ($Value -is [single] -or $Value -is [double]) {
                [double]$floatingPointValue = [Convert]::ToDouble(
                    $Value,
                    [Globalization.CultureInfo]::InvariantCulture
                )
                if ([double]::IsNaN($floatingPointValue) -or
                    [double]::IsInfinity($floatingPointValue) -or
                    $floatingPointValue -ne [Math]::Truncate($floatingPointValue)) {
                    return $null
                }
            }

            [decimal]$decimalValue = [Convert]::ToDecimal(
                $Value,
                [Globalization.CultureInfo]::InvariantCulture
            )
            if ($decimalValue -ne [decimal]::Truncate($decimalValue) -or
                $decimalValue -lt [decimal]([long]::MinValue) -or
                $decimalValue -gt [decimal]([long]::MaxValue)) {
                return $null
            }

            $unixSeconds = [long]$decimalValue
        }
        else {
            return $null
        }

        $minimumUnixSeconds = [DateTimeOffset]::MinValue.ToUnixTimeSeconds()
        $maximumUnixSeconds = [DateTimeOffset]::MaxValue.ToUnixTimeSeconds()
        # Codex reset timestamps are future Unix seconds. Normalization uses zero
        # when the field is absent, so non-positive values must remain unknown
        # instead of rendering an epoch date.
        if ($unixSeconds -le 0 -or
            $unixSeconds -lt $minimumUnixSeconds -or
            $unixSeconds -gt $maximumUnixSeconds) {
            return $null
        }

        # Validate conversion here so both countdown and reset-time fields share one boundary.
        [DateTimeOffset]::FromUnixTimeSeconds($unixSeconds) | Out-Null
        return [long]$unixSeconds
    }
    catch {
        return $null
    }
}

function ConvertTo-QuotaPresentationRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyCollection()]
        [object[]]$QuotaWindows,

        [Parameter(Position = 1)]
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    foreach ($window in $QuotaWindows) {
        if ($null -eq $window) {
            continue
        }

        [int]$duration = ConvertTo-InvariantInt32OrZero -Value (
            Get-ObjectField -InputObject $window -Name 'WindowDurationMins'
        )
        $limitName = [string](Get-ObjectField -InputObject $window -Name 'LimitName')

        $remaining = ConvertTo-InvariantFiniteDouble -Value (
            Get-ObjectField -InputObject $window -Name 'RemainingPercent'
        )
        if ($null -ne $remaining -and ($remaining -lt 0.0 -or $remaining -gt 100.0)) {
            $remaining = $null
        }

        if ($null -eq $remaining) {
            $remainingText = '--%'
            $progressValue = $null
        }
        else {
            $remainingText = $remaining.ToString(
                '0.#',
                [Globalization.CultureInfo]::InvariantCulture
            ) + '%'
            $progressValue = [double]$remaining
        }

        $resetsAt = ConvertTo-ValidQuotaUnixSeconds -Value (
            Get-ObjectField -InputObject $window -Name 'ResetsAt'
        )
        if ($null -eq $resetsAt) {
            $countdownText = '重置时间未知'
            $resetTimeText = '重置时间未知'
        }
        else {
            $countdownText = Format-ResetCountdown -ResetsAt $resetsAt -Now $Now
            $resetTimeText = [DateTimeOffset]::FromUnixTimeSeconds($resetsAt).ToLocalTime().ToString(
                "'重置时间：'yyyy-MM-dd HH:mm",
                [Globalization.CultureInfo]::InvariantCulture
            )
        }

        [pscustomobject][ordered]@{
            Key = [string](Get-ObjectField -InputObject $window -Name 'Key')
            Label = Get-QuotaLabel -WindowDurationMins $duration -LimitName $limitName
            RemainingText = [string]$remainingText
            ProgressValue = $progressValue
            CountdownText = [string]$countdownText
            ResetTimeText = [string]$resetTimeText
        }
    }
}

function Get-QuotaSeverity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [object]$MinimumRemaining,

        [Parameter(Position = 1)]
        [bool]$Offline = $false
    )

    if ($Offline) {
        return 'Gray'
    }

    $remaining = ConvertTo-InvariantFiniteDouble -Value $MinimumRemaining
    if ($null -eq $remaining) {
        return 'Gray'
    }

    if ($remaining -lt 15.0) {
        return 'Red'
    }

    if ($remaining -le 40.0) {
        return 'Yellow'
    }

    return 'Green'
}

function Limit-TextElementLength {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory, Position = 1)]
        [int]$MaximumLength
    )

    if ($MaximumLength -le 0 -or $Text.Length -eq 0) {
        return ''
    }
    if ($Text.Length -le $MaximumLength) {
        return $Text
    }

    $enumerator = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    $safeLength = 0
    while ($enumerator.MoveNext()) {
        $element = $enumerator.GetTextElement()
        if ($safeLength + $element.Length -gt $MaximumLength) {
            break
        }

        $safeLength += $element.Length
    }

    return $Text.Substring(0, $safeLength)
}

function Get-TrayTooltip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyCollection()]
        [object[]]$QuotaWindows
    )

    $entries = @()
    foreach ($window in $QuotaWindows) {
        if ($null -eq $window) {
            continue
        }

        $durationValue = Get-ObjectField -InputObject $window -Name 'WindowDurationMins'
        [int]$duration = ConvertTo-InvariantInt32OrZero -Value $durationValue
        $limitName = [string](Get-ObjectField -InputObject $window -Name 'LimitName')

        $label = if ($duration -ge 270 -and $duration -le 330) {
            '5h'
        }
        elseif ($duration -ge 9000 -and $duration -le 11000) {
            '周'
        }
        else {
            Get-QuotaLabel -WindowDurationMins $duration -LimitName $limitName
        }

        $remainingValue = Get-ObjectField -InputObject $window -Name 'RemainingPercent'
        $remaining = ConvertTo-InvariantFiniteDouble -Value $remainingValue
        $remainingText = if ($null -eq $remaining) {
            '--'
        }
        else {
            [Math]::Round($remaining, 0, [MidpointRounding]::AwayFromZero).ToString(
                '0',
                [Globalization.CultureInfo]::InvariantCulture
            )
        }

        $entries += "$label $remainingText%"
    }

    $tooltip = $entries -join ' | '
    return Limit-TextElementLength -Text $tooltip -MaximumLength 63
}

function ConvertTo-OfficialMonitorPresentationRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][object]$Row
    )
    process {
        $progress = ConvertTo-InvariantFiniteDouble -Value (
            Get-ObjectField -InputObject $Row -Name 'ProgressValue'
        )
        if ($null -ne $progress -and ($progress -lt 0 -or $progress -gt 100)) {
            $progress = $null
        }
        $updatedAtValue = Get-ObjectField -InputObject $Row -Name 'UpdatedAt'
        $updatedAt = if ($null -eq $updatedAtValue) {
            $null
        }
        else {
            try { ([DateTimeOffset]$updatedAtValue).ToUniversalTime() } catch { $null }
        }
        $state = [string](Get-ObjectField -InputObject $Row -Name 'State')
        if ([string]::IsNullOrWhiteSpace($state)) {
            $state = 'Live'
        }
        $sourceId = [string](Get-ObjectField -InputObject $Row -Name 'SourceId')
        if ([string]::IsNullOrWhiteSpace($sourceId)) {
            $sourceId = 'codex'
        }
        [pscustomobject][ordered]@{
            Key = [string](Get-ObjectField -InputObject $Row -Name 'Key')
            SourceKind = 'Official'
            SourceId = $sourceId
            SourceLabel = 'Codex 官方'
            GroupLabel = 'Codex 官方额度'
            Label = [string](Get-ObjectField -InputObject $Row -Name 'Label')
            ValueText = [string](Get-ObjectField -InputObject $Row -Name 'RemainingText')
            SecondaryText = ''
            ProgressValue = $progress
            Countdown = [string](Get-ObjectField -InputObject $Row -Name 'CountdownText')
            ResetTime = [string](Get-ObjectField -InputObject $Row -Name 'ResetTimeText')
            IsStale = [bool](Get-ObjectField -InputObject $Row -Name 'IsStale')
            UpdatedAt = $updatedAt
            State = $state
        }
    }
}
