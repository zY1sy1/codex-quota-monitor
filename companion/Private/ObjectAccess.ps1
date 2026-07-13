function Get-ObjectField {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if (([System.Collections.IDictionary]$InputObject).Contains($Name)) {
            return ([System.Collections.IDictionary]$InputObject)[$Name]
        }

        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function ConvertTo-InvariantFiniteDouble {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    [double]$converted = 0.0
    try {
        if ($Value -is [string]) {
            $parsed = [double]::TryParse(
                $Value,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$converted
            )
            if (-not $parsed) {
                return $null
            }
        }
        else {
            $converted = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    catch {
        return $null
    }

    if ([double]::IsNaN($converted) -or [double]::IsInfinity($converted)) {
        return $null
    }

    return [double]$converted
}

function ConvertTo-InvariantInt32OrZero {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return [int]0
    }

    [int]$converted = 0
    try {
        if ($Value -is [string]) {
            $parsed = [int]::TryParse(
                $Value,
                [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$converted
            )
            if (-not $parsed) {
                return [int]0
            }
        }
        else {
            $converted = [Convert]::ToInt32($Value, [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    catch {
        return [int]0
    }

    return [int]$converted
}

function ConvertTo-InvariantInt64OrZero {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return [long]0
    }

    [long]$converted = 0
    try {
        if ($Value -is [string]) {
            $parsed = [long]::TryParse(
                $Value,
                [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$converted
            )
            if (-not $parsed) {
                return [long]0
            }
        }
        else {
            $converted = [Convert]::ToInt64($Value, [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    catch {
        return [long]0
    }

    return [long]$converted
}
