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
