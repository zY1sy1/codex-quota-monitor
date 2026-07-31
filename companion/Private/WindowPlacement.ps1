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

function Get-MonitorWorkAreas {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Screens,

        [Parameter()]
        [AllowNull()]
        [object]$PrimaryLogicalWorkArea,

        [Parameter()]
        [AllowNull()]
        [object]$PrimaryLogicalScreenWidth,

        [Parameter()]
        [AllowNull()]
        [object]$PrimaryLogicalScreenHeight
    )

    if (-not $PSBoundParameters.ContainsKey('Screens')) {
        Add-Type -AssemblyName System.Windows.Forms
        $Screens = @([Windows.Forms.Screen]::AllScreens)
    }
    if ($null -eq $PrimaryLogicalWorkArea -or
        $null -eq $PrimaryLogicalScreenWidth -or
        $null -eq $PrimaryLogicalScreenHeight) {
        Add-Type -AssemblyName PresentationFramework
        $PrimaryLogicalWorkArea = [Windows.SystemParameters]::WorkArea
        $PrimaryLogicalScreenWidth = [Windows.SystemParameters]::PrimaryScreenWidth
        $PrimaryLogicalScreenHeight = [Windows.SystemParameters]::PrimaryScreenHeight
    }

    $orderedScreens = @(
        @($Screens | Where-Object { $null -ne $_ }) |
            Sort-Object -Property @(
                @{ Expression = { -not $_.Primary } }
                @{ Expression = { [string]$_.DeviceName } }
            )
    )
    if ($orderedScreens.Count -eq 0) {
        return @()
    }

    $primaryScreen = @($orderedScreens | Where-Object { [bool]$_.Primary })[0]
    if ($null -eq $primaryScreen) {
        $primaryScreen = $orderedScreens[0]
    }
    $primaryBounds = Get-WindowPlacementField -InputObject $primaryScreen -Name 'Bounds'
    $primaryDeviceWorkArea = Get-WindowPlacementField -InputObject $primaryScreen -Name 'WorkingArea'
    $primaryDeviceWidth = ConvertTo-WindowPlacementFiniteDouble (
        Get-WindowPlacementField -InputObject $primaryBounds -Name 'Width'
    )
    $primaryDeviceHeight = ConvertTo-WindowPlacementFiniteDouble (
        Get-WindowPlacementField -InputObject $primaryBounds -Name 'Height'
    )
    $logicalScreenWidth = ConvertTo-WindowPlacementFiniteDouble $PrimaryLogicalScreenWidth
    $logicalScreenHeight = ConvertTo-WindowPlacementFiniteDouble $PrimaryLogicalScreenHeight
    $scaleX = if ($null -ne $primaryDeviceWidth -and $primaryDeviceWidth -gt 0 -and
        $null -ne $logicalScreenWidth -and $logicalScreenWidth -gt 0) {
        $primaryDeviceWidth / $logicalScreenWidth
    }
    else {
        1.0
    }
    $scaleY = if ($null -ne $primaryDeviceHeight -and $primaryDeviceHeight -gt 0 -and
        $null -ne $logicalScreenHeight -and $logicalScreenHeight -gt 0) {
        $primaryDeviceHeight / $logicalScreenHeight
    }
    else {
        1.0
    }

    $primaryDeviceLeft = ConvertTo-WindowPlacementFiniteDouble (
        Get-WindowPlacementField -InputObject $primaryDeviceWorkArea -Name 'Left'
    )
    $primaryDeviceTop = ConvertTo-WindowPlacementFiniteDouble (
        Get-WindowPlacementField -InputObject $primaryDeviceWorkArea -Name 'Top'
    )
    $primaryLogicalLeft = ConvertTo-WindowPlacementFiniteDouble (
        Get-WindowPlacementField -InputObject $PrimaryLogicalWorkArea -Name 'Left'
    )
    $primaryLogicalTop = ConvertTo-WindowPlacementFiniteDouble (
        Get-WindowPlacementField -InputObject $PrimaryLogicalWorkArea -Name 'Top'
    )
    if ($null -eq $primaryDeviceLeft) { $primaryDeviceLeft = 0.0 }
    if ($null -eq $primaryDeviceTop) { $primaryDeviceTop = 0.0 }
    if ($null -eq $primaryLogicalLeft) { $primaryLogicalLeft = 0.0 }
    if ($null -eq $primaryLogicalTop) { $primaryLogicalTop = 0.0 }

    return @(
        foreach ($screen in $orderedScreens) {
            $area = Get-WindowPlacementField -InputObject $screen -Name 'WorkingArea'
            $deviceLeft = ConvertTo-WindowPlacementFiniteDouble (
                Get-WindowPlacementField -InputObject $area -Name 'Left'
            )
            $deviceTop = ConvertTo-WindowPlacementFiniteDouble (
                Get-WindowPlacementField -InputObject $area -Name 'Top'
            )
            $deviceWidth = ConvertTo-WindowPlacementFiniteDouble (
                Get-WindowPlacementField -InputObject $area -Name 'Width'
            )
            $deviceHeight = ConvertTo-WindowPlacementFiniteDouble (
                Get-WindowPlacementField -InputObject $area -Name 'Height'
            )
            if ($null -eq $deviceLeft -or $null -eq $deviceTop -or
                $null -eq $deviceWidth -or $null -eq $deviceHeight) {
                continue
            }

            [pscustomobject][ordered]@{
                Left = [double]($primaryLogicalLeft + (($deviceLeft - $primaryDeviceLeft) / $scaleX))
                Top = [double]($primaryLogicalTop + (($deviceTop - $primaryDeviceTop) / $scaleY))
                Width = [double]($deviceWidth / $scaleX)
                Height = [double]($deviceHeight / $scaleY)
            }
        }
    )
}

function Get-WindowPlacementDimension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$Window,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string[]]$CandidateNames
    )

    foreach ($name in $CandidateNames) {
        $value = ConvertTo-WindowPlacementFiniteDouble (
            Get-WindowPlacementField -InputObject $Window -Name $name
        )
        if ($null -ne $value -and $value -gt 0) {
            return [double]$value
        }
    }

    return 1.0
}

function Set-ResolvedWindowPlacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$Window,

        [Parameter(Position = 1)]
        [AllowNull()]
        [object]$Left,

        [Parameter(Position = 2)]
        [AllowNull()]
        [object]$Top,

        [Parameter(Position = 3)]
        [AllowEmptyCollection()]
        [object[]]$WorkAreas = @()
    )

    $width = Get-WindowPlacementDimension `
        -Window $Window `
        -CandidateNames @('ActualWidth', 'Width', 'MinWidth')
    $height = Get-WindowPlacementDimension `
        -Window $Window `
        -CandidateNames @('ActualHeight', 'Height', 'MinHeight')
    $placement = Resolve-WindowPlacement `
        -Left $Left `
        -Top $Top `
        -WindowWidth $width `
        -WindowHeight $height `
        -WorkAreas $WorkAreas

    $Window.Left = [double]$placement.Left
    $Window.Top = [double]$placement.Top
    return $placement
}

function Initialize-MonitorDesktopPresentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$WindowView,

        [Parameter(Mandatory, Position = 1)]
        [object]$TrayView,

        [Parameter(Mandatory, Position = 2)]
        [object]$Settings,

        [Parameter(Mandatory, Position = 3)]
        [scriptblock]$GetWorkAreas,

        [Parameter(Mandatory, Position = 4)]
        [scriptblock]$SetPlacement
    )

    & $WindowView.SetTopmost ([bool]$Settings.Window.Topmost) | Out-Null
    $workAreas = @(& $GetWorkAreas)
    & $SetPlacement `
        -Window $WindowView.Window `
        -Left $Settings.Window.Left `
        -Top $Settings.Window.Top `
        -WorkAreas $workAreas | Out-Null
    & $TrayView.SetVisible $true | Out-Null
    if ([bool]$Settings.Window.Visible) {
        & $WindowView.Show | Out-Null
    }
    else {
        & $WindowView.Hide | Out-Null
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
