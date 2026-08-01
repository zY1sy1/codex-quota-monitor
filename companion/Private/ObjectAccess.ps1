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

function Test-IsNumericClrPrimitive {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or $Value.GetType().IsEnum) {
        return $false
    }

    return [Type]::GetTypeCode($Value.GetType()) -in @(
        [TypeCode]::SByte,
        [TypeCode]::Byte,
        [TypeCode]::Int16,
        [TypeCode]::UInt16,
        [TypeCode]::Int32,
        [TypeCode]::UInt32,
        [TypeCode]::Int64,
        [TypeCode]::UInt64,
        [TypeCode]::Single,
        [TypeCode]::Double,
        [TypeCode]::Decimal
    )
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
        elseif (Test-IsNumericClrPrimitive -Value $Value) {
            $converted = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
        }
        else {
            return $null
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

    [decimal]$numericValue = 0
    try {
        if ($Value -is [string]) {
            [int]$converted = 0
            $parsed = [int]::TryParse(
                $Value,
                [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$converted
            )
            if (-not $parsed) {
                return [int]0
            }

            return [int]$converted
        }
        elseif (Test-IsNumericClrPrimitive -Value $Value) {
            $numericValue = [Convert]::ToDecimal($Value, [Globalization.CultureInfo]::InvariantCulture)
        }
        else {
            return [int]0
        }
    }
    catch {
        return [int]0
    }

    if ($numericValue -ne [decimal]::Truncate($numericValue) -or
        $numericValue -lt [decimal]([int]::MinValue) -or
        $numericValue -gt [decimal]([int]::MaxValue)) {
        return [int]0
    }

    return [int]$numericValue
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

    [decimal]$numericValue = 0
    try {
        if ($Value -is [string]) {
            [long]$converted = 0
            $parsed = [long]::TryParse(
                $Value,
                [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$converted
            )
            if (-not $parsed) {
                return [long]0
            }

            return [long]$converted
        }
        elseif (Test-IsNumericClrPrimitive -Value $Value) {
            $numericValue = [Convert]::ToDecimal($Value, [Globalization.CultureInfo]::InvariantCulture)
        }
        else {
            return [long]0
        }
    }
    catch {
        return [long]0
    }

    if ($numericValue -ne [decimal]::Truncate($numericValue) -or
        $numericValue -lt [decimal]([long]::MinValue) -or
        $numericValue -gt [decimal]([long]::MaxValue)) {
        return [long]0
    }

    return [long]$numericValue
}
