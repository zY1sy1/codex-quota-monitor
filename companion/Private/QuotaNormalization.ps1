function Get-RemainingPercent {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$UsedPercent
    )

    $used = ConvertTo-InvariantFiniteDouble -Value $UsedPercent
    if ($null -eq $used) {
        return $null
    }

    [double]$remaining = 100.0 - $used
    if ($remaining -lt 0.0) {
        $remaining = 0.0
    }
    elseif ($remaining -gt 100.0) {
        $remaining = 100.0
    }

    return [Math]::Round($remaining, 1)
}

function Get-QuotaBucketEntry {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$BucketMap
    )

    if ($null -eq $BucketMap) {
        return
    }

    if ($BucketMap -is [System.Collections.IDictionary]) {
        foreach ($entry in $BucketMap.GetEnumerator()) {
            [pscustomobject]@{
                Name = [string]$entry.Key
                Value = $entry.Value
            }
        }

        return
    }

    foreach ($property in $BucketMap.PSObject.Properties) {
        [pscustomobject]@{
            Name = [string]$property.Name
            Value = $property.Value
        }
    }
}

function Compare-NullableQuotaNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [object]$Left,

        [Parameter(Mandatory, Position = 1)]
        [AllowNull()]
        [object]$Right
    )

    if ($null -eq $Left) {
        if ($null -eq $Right) {
            return 0
        }

        return -1
    }
    if ($null -eq $Right) {
        return 1
    }

    return ([double]$Left).CompareTo([double]$Right)
}

function Get-QuotaWindowCompleteness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$Row
    )

    $score = 0
    if (-not [string]::IsNullOrWhiteSpace($Row.LimitName)) { $score++ }
    if ($null -ne $Row.UsedPercent) { $score++ }
    if ($null -ne $Row.RemainingPercent) { $score++ }
    if (-not [string]::IsNullOrWhiteSpace($Row.RateLimitReached)) { $score++ }
    return $score
}

function Compare-QuotaWindowRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$Left,

        [Parameter(Mandatory, Position = 1)]
        [object]$Right
    )

    $comparison = $Left.WindowDurationMins.CompareTo($Right.WindowDurationMins)
    if ($comparison -ne 0) { return $comparison }

    $comparison = [StringComparer]::Ordinal.Compare($Left.LimitId, $Right.LimitId)
    if ($comparison -ne 0) { return $comparison }

    $comparison = [StringComparer]::Ordinal.Compare($Left.WindowKind, $Right.WindowKind)
    if ($comparison -ne 0) { return $comparison }

    $comparison = $Left.ResetsAt.CompareTo($Right.ResetsAt)
    if ($comparison -ne 0) { return $comparison }

    $comparison = [StringComparer]::Ordinal.Compare($Left.Key, $Right.Key)
    if ($comparison -ne 0) { return $comparison }

    # Equal identity keys prefer more complete metadata, then the lowest canonical non-key tuple.
    $leftCompleteness = Get-QuotaWindowCompleteness -Row $Left
    $rightCompleteness = Get-QuotaWindowCompleteness -Row $Right
    $comparison = $rightCompleteness.CompareTo($leftCompleteness)
    if ($comparison -ne 0) { return $comparison }

    $comparison = [StringComparer]::Ordinal.Compare($Left.LimitName, $Right.LimitName)
    if ($comparison -ne 0) { return $comparison }

    $comparison = Compare-NullableQuotaNumber -Left $Left.UsedPercent -Right $Right.UsedPercent
    if ($comparison -ne 0) { return $comparison }

    $comparison = Compare-NullableQuotaNumber -Left $Left.RemainingPercent -Right $Right.RemainingPercent
    if ($comparison -ne 0) { return $comparison }

    return [StringComparer]::Ordinal.Compare($Left.RateLimitReached, $Right.RateLimitReached)
}

function Sort-QuotaWindowRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyCollection()]
        [object[]]$Rows
    )

    $sorted = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Rows) {
        $insertAt = 0
        while ($insertAt -lt $sorted.Count) {
            $comparison = Compare-QuotaWindowRecord -Left $sorted[$insertAt] -Right $row
            if ($comparison -gt 0) {
                break
            }

            $insertAt++
        }

        $sorted.Insert($insertAt, $row)
    }

    return $sorted
}

function ConvertTo-QuotaWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [object]$RateLimitResult
    )

    $bucketEntries = @(Get-QuotaBucketEntry -BucketMap (Get-ObjectField -InputObject $RateLimitResult -Name 'rateLimitsByLimitId'))
    if ($bucketEntries.Count -eq 0) {
        $compatibilityBucket = Get-ObjectField -InputObject $RateLimitResult -Name 'rateLimits'
        if ($null -ne $compatibilityBucket) {
            $compatibilityLimitId = [string](Get-ObjectField -InputObject $compatibilityBucket -Name 'limitId')
            if ([string]::IsNullOrWhiteSpace($compatibilityLimitId)) {
                $compatibilityLimitId = 'codex'
            }

            $bucketEntries = @(
                [pscustomobject]@{
                    Name = $compatibilityLimitId
                    Value = $compatibilityBucket
                }
            )
        }
    }

    $rows = @()
    foreach ($entry in $bucketEntries) {
        $bucket = $entry.Value
        if ($null -eq $bucket) {
            continue
        }

        $limitId = [string](Get-ObjectField -InputObject $bucket -Name 'limitId')
        if ([string]::IsNullOrWhiteSpace($limitId)) {
            $limitId = [string]$entry.Name
        }
        if ([string]::IsNullOrWhiteSpace($limitId)) {
            $limitId = 'codex'
        }

        $limitName = [string](Get-ObjectField -InputObject $bucket -Name 'limitName')
        foreach ($windowKind in @('primary', 'secondary')) {
            $window = Get-ObjectField -InputObject $bucket -Name $windowKind
            if ($null -eq $window) {
                continue
            }

            $usedValue = Get-ObjectField -InputObject $window -Name 'usedPercent'
            $usedPercent = ConvertTo-InvariantFiniteDouble -Value $usedValue

            $durationValue = Get-ObjectField -InputObject $window -Name 'windowDurationMins'
            [int]$duration = ConvertTo-InvariantInt32OrZero -Value $durationValue

            $resetsValue = Get-ObjectField -InputObject $window -Name 'resetsAt'
            [long]$resetsAt = ConvertTo-InvariantInt64OrZero -Value $resetsValue

            $rows += [pscustomobject][ordered]@{
                Key = [string]"$limitId|$windowKind|$duration|$resetsAt"
                LimitId = [string]$limitId
                LimitName = [string]$limitName
                WindowKind = [string]$windowKind
                UsedPercent = $usedPercent
                RemainingPercent = Get-RemainingPercent -UsedPercent $usedPercent
                WindowDurationMins = [int]$duration
                ResetsAt = [long]$resetsAt
                RateLimitReached = [string](Get-ObjectField -InputObject $window -Name 'rateLimitReachedType')
            }
        }
    }

    $sortedRows = @(Sort-QuotaWindowRecord -Rows $rows)

    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($row in $sortedRows) {
        if ($seenKeys.Add($row.Key)) {
            $row
        }
    }
}
