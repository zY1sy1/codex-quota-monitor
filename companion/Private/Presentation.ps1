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

    $resetTime = [DateTimeOffset]::FromUnixTimeSeconds($ResetsAt)
    [long]$totalSeconds = [Math]::Floor(($resetTime - $Now.ToUniversalTime()).TotalSeconds)
    if ($totalSeconds -le 0) {
        return '正在刷新'
    }

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

    [double]$remaining = $MinimumRemaining
    if ($remaining -lt 15.0) {
        return 'Red'
    }

    if ($remaining -le 40.0) {
        return 'Yellow'
    }

    return 'Green'
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
        [int]$duration = if ($null -eq $durationValue) { 0 } else { [int]$durationValue }
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
        $remainingText = if ($null -eq $remainingValue) {
            '--'
        }
        else {
            [Math]::Round([double]$remainingValue, 0, [MidpointRounding]::AwayFromZero).ToString(
                '0',
                [Globalization.CultureInfo]::InvariantCulture
            )
        }

        $entries += "$label $remainingText%"
    }

    $tooltip = $entries -join ' | '
    if ($tooltip.Length -gt 63) {
        return $tooltip.Substring(0, 63)
    }

    return $tooltip
}
