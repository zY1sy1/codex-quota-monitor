function Get-RemainingPercent {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$UsedPercent
    )

    if ($null -eq $UsedPercent) {
        return $null
    }

    [double]$remaining = 100.0 - [double]$UsedPercent
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
            $usedPercent = if ($null -eq $usedValue) { $null } else { [double]$usedValue }

            $durationValue = Get-ObjectField -InputObject $window -Name 'windowDurationMins'
            [int]$duration = if ($null -eq $durationValue) { 0 } else { [int]$durationValue }

            $resetsValue = Get-ObjectField -InputObject $window -Name 'resetsAt'
            [long]$resetsAt = if ($null -eq $resetsValue) { 0 } else { [long]$resetsValue }

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

    $sortedRows = @(
        $rows | Sort-Object -Property @(
            @{ Expression = 'WindowDurationMins'; Ascending = $true },
            @{ Expression = 'LimitId'; Ascending = $true },
            @{ Expression = 'WindowKind'; Ascending = $true },
            @{ Expression = 'ResetsAt'; Ascending = $true },
            @{ Expression = 'Key'; Ascending = $true }
        )
    )

    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($row in $sortedRows) {
        if ($seenKeys.Add($row.Key)) {
            $row
        }
    }
}
