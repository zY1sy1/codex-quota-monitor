function Get-WindowPlacementField {
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

function ConvertTo-WindowPlacementFiniteDouble {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or $Value.GetType().IsEnum) {
        return $null
    }

    [double]$number = 0.0
    if ($Value -is [string]) {
        $parsed = [double]::TryParse(
            $Value,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$number
        )
        if (-not $parsed) {
            return $null
        }
    }
    else {
        $typeCode = [Type]::GetTypeCode($Value.GetType())
        if ($typeCode -notin @(
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
        )) {
            return $null
        }

        try {
            $number = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
        }
        catch {
            return $null
        }
    }

    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        return $null
    }

    return [double]$number
}

function New-WindowPlacementFallback {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyCollection()]
        [object[]]$UsableWorkAreas = @()
    )

    if ($UsableWorkAreas.Count -gt 0) {
        return [pscustomobject][ordered]@{
            Left = [double]$UsableWorkAreas[0].Left + 24.0
            Top = [double]$UsableWorkAreas[0].Top + 24.0
        }
    }

    return [pscustomobject][ordered]@{
        Left = 24.0
        Top = 24.0
    }
}

function Resolve-WindowPlacement {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Left,

        [Parameter(Position = 1)]
        [AllowNull()]
        [object]$Top,

        [Parameter(Mandatory, Position = 2)]
        [object]$WindowWidth,

        [Parameter(Mandatory, Position = 3)]
        [object]$WindowHeight,

        [Parameter(Position = 4)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$WorkAreas = @()
    )

    $usableWorkAreas = @()
    foreach ($workArea in @($WorkAreas)) {
        $areaLeft = ConvertTo-WindowPlacementFiniteDouble (Get-WindowPlacementField -InputObject $workArea -Name 'Left')
        $areaTop = ConvertTo-WindowPlacementFiniteDouble (Get-WindowPlacementField -InputObject $workArea -Name 'Top')
        $areaWidth = ConvertTo-WindowPlacementFiniteDouble (Get-WindowPlacementField -InputObject $workArea -Name 'Width')
        $areaHeight = ConvertTo-WindowPlacementFiniteDouble (Get-WindowPlacementField -InputObject $workArea -Name 'Height')
        if ($null -eq $areaLeft -or $null -eq $areaTop -or
            $null -eq $areaWidth -or $null -eq $areaHeight -or
            $areaWidth -le 0 -or $areaHeight -le 0) {
            continue
        }

        $areaRight = $areaLeft + $areaWidth
        $areaBottom = $areaTop + $areaHeight
        if ([double]::IsInfinity($areaRight) -or [double]::IsInfinity($areaBottom)) {
            continue
        }

        $usableWorkAreas += [pscustomobject][ordered]@{
            Left = $areaLeft
            Top = $areaTop
            Width = $areaWidth
            Height = $areaHeight
            Right = $areaRight
            Bottom = $areaBottom
        }
    }

    $savedLeft = ConvertTo-WindowPlacementFiniteDouble $Left
    $savedTop = ConvertTo-WindowPlacementFiniteDouble $Top
    $width = ConvertTo-WindowPlacementFiniteDouble $WindowWidth
    $height = ConvertTo-WindowPlacementFiniteDouble $WindowHeight
    if ($null -eq $savedLeft -or $null -eq $savedTop -or
        $null -eq $width -or $null -eq $height -or
        $width -le 0 -or $height -le 0) {
        return New-WindowPlacementFallback -UsableWorkAreas $usableWorkAreas
    }

    $savedRight = $savedLeft + $width
    $savedBottom = $savedTop + $height
    if ([double]::IsInfinity($savedRight) -or [double]::IsInfinity($savedBottom)) {
        return New-WindowPlacementFallback -UsableWorkAreas $usableWorkAreas
    }

    $selectedArea = $null
    $largestIntersection = 0.0
    foreach ($area in $usableWorkAreas) {
        $intersectionWidth = [Math]::Max(
            0.0,
            [Math]::Min($savedRight, $area.Right) - [Math]::Max($savedLeft, $area.Left)
        )
        $intersectionHeight = [Math]::Max(
            0.0,
            [Math]::Min($savedBottom, $area.Bottom) - [Math]::Max($savedTop, $area.Top)
        )
        $intersection = $intersectionWidth * $intersectionHeight
        if ($intersection -gt $largestIntersection) {
            $largestIntersection = $intersection
            $selectedArea = $area
        }
    }

    if ($null -eq $selectedArea) {
        return New-WindowPlacementFallback -UsableWorkAreas $usableWorkAreas
    }

    $visibleWidth = [Math]::Min(48.0, $width)
    $minimumLeft = $selectedArea.Left - $width + $visibleWidth
    $maximumLeft = $selectedArea.Right - $visibleWidth
    if ($minimumLeft -le $maximumLeft) {
        $resolvedLeft = [Math]::Min([Math]::Max($savedLeft, $minimumLeft), $maximumLeft)
    }
    else {
        $resolvedLeft = $selectedArea.Left
    }

    $titleStripHeight = [Math]::Min(48.0, $height)
    $minimumTop = $selectedArea.Top
    $maximumTop = $selectedArea.Bottom - $titleStripHeight
    if ($minimumTop -le $maximumTop) {
        $resolvedTop = [Math]::Min([Math]::Max($savedTop, $minimumTop), $maximumTop)
    }
    else {
        $resolvedTop = $selectedArea.Top
    }

    return [pscustomobject][ordered]@{
        Left = [double]$resolvedLeft
        Top = [double]$resolvedTop
    }
}
