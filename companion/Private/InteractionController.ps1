function Get-MonitorInteractionField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name
    )

    if ($InputObject -is [Collections.IDictionary]) {
        return ([Collections.IDictionary]$InputObject)[$Name]
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Set-MonitorInteractionField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name,

        [Parameter(Position = 2)]
        [AllowNull()]
        [object]$Value
    )

    if ($InputObject -is [Collections.IDictionary]) {
        ([Collections.IDictionary]$InputObject)[$Name] = $Value
        return
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
        return
    }

    $property.Value = $Value
}

function ConvertTo-MonitorFiniteCoordinate {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or $Value -is [bool] -or $Value.GetType().IsEnum) {
        return $null
    }

    $typeCode = [Type]::GetTypeCode($Value.GetType())
    if ($typeCode -notin @(
        [TypeCode]::SByte, [TypeCode]::Byte, [TypeCode]::Int16, [TypeCode]::UInt16,
        [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64,
        [TypeCode]::Single, [TypeCode]::Double, [TypeCode]::Decimal
    )) {
        return $null
    }

    try {
        [double]$coordinate = [Convert]::ToDouble(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    catch {
        return $null
    }

    if ([double]::IsNaN($coordinate) -or [double]::IsInfinity($coordinate)) {
        return $null
    }

    return $coordinate
}

function New-MonitorInteractionController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Settings,

        [Parameter(Mandatory)]
        [object]$WindowView,

        [Parameter(Mandatory)]
        [object]$TrayView,

        [Parameter(Mandatory)]
        [scriptblock]$SaveSettings,

        [Parameter(Mandatory)]
        [scriptblock]$ApplyStartupPreference,

        [Parameter(Mandatory)]
        [scriptblock]$RequestRefresh,

        [Parameter(Mandatory)]
        [Threading.EventWaitHandle]$ExitEvent,

        [Parameter(Mandatory)]
        [scriptblock]$OpenTarget,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogDirectory,

        [ValidateNotNullOrEmpty()]
        [string]$UsageUri = 'https://chatgpt.com/codex/settings/usage'
    )

    $windowSettings = Get-MonitorInteractionField -InputObject $Settings -Name 'Window'
    if ($null -eq $windowSettings) {
        throw 'Monitor settings must contain a Window object.'
    }

    $state = [pscustomobject][ordered]@{
        Disposed = $false
    }
    $getField = ${function:Get-MonitorInteractionField}
    $setField = ${function:Set-MonitorInteractionField}
    $convertCoordinate = ${function:ConvertTo-MonitorFiniteCoordinate}

    $persistPlacement = {
        param(
            [Parameter(Position = 0)]
            [AllowNull()]
            [object]$Placement
        )

        if ($state.Disposed -or $null -eq $Placement) {
            return
        }

        $changed = $false
        foreach ($name in @('Left', 'Top')) {
            $coordinate = & $convertCoordinate -Value (
                & $getField -InputObject $Placement -Name $name
            )
            if ($null -eq $coordinate) {
                continue
            }

            & $setField -InputObject $windowSettings -Name $name -Value $coordinate
            $changed = $true
        }

        if ($changed) {
            & $SaveSettings $Settings
        }
    }.GetNewClosure()

    $hide = {
        if ($state.Disposed) {
            return
        }

        & $WindowView.Hide
        & $setField -InputObject $windowSettings -Name 'Visible' -Value $false
        & $SaveSettings $Settings
    }.GetNewClosure()

    $showAndActivate = {
        if ($state.Disposed) {
            return
        }

        if ($null -ne $WindowView.PSObject.Properties['Show']) {
            & $WindowView.Show
        }
        & $WindowView.Activate
        & $setField -InputObject $windowSettings -Name 'Visible' -Value $true
        & $SaveSettings $Settings
    }.GetNewClosure()

    $toggleVisibility = {
        if ($state.Disposed) {
            return
        }

        $placement = & $WindowView.GetPlacement
        $isVisible = [bool](& $getField -InputObject $placement -Name 'Visible')
        if ($isVisible) {
            & $hide
        }
        else {
            & $showAndActivate
        }
    }.GetNewClosure()

    $toggleTopmost = {
        if ($state.Disposed) {
            return
        }

        $current = [bool](& $getField -InputObject $windowSettings -Name 'Topmost')
        $desired = -not $current
        & $WindowView.SetTopmost $desired
        try {
            & $TrayView.SetTopmostChecked $desired
        }
        catch {
            try { & $WindowView.SetTopmost $current } catch { }
            throw
        }

        & $setField -InputObject $windowSettings -Name 'Topmost' -Value $desired
        & $SaveSettings $Settings
    }.GetNewClosure()

    $toggleStartup = {
        if ($state.Disposed) {
            return
        }

        $current = [bool](& $getField -InputObject $Settings -Name 'Startup')
        $desired = -not $current

        # The system operation is authoritative. Do not persist a check mark that failed to apply.
        & $ApplyStartupPreference $desired
        & $setField -InputObject $Settings -Name 'Startup' -Value $desired
        & $TrayView.SetStartupChecked $desired
        & $SaveSettings $Settings
    }.GetNewClosure()

    $refresh = {
        if (-not $state.Disposed) {
            & $RequestRefresh
        }
    }.GetNewClosure()

    $openUsage = {
        if (-not $state.Disposed) {
            & $OpenTarget $UsageUri
        }
    }.GetNewClosure()

    $openLogs = {
        if (-not $state.Disposed) {
            & $OpenTarget $LogDirectory
        }
    }.GetNewClosure()

    $exit = {
        if (-not $state.Disposed) {
            $ExitEvent.Set() | Out-Null
        }
    }.GetNewClosure()

    $dispose = {
        if ($state.Disposed) {
            return
        }

        $state.Disposed = $true
        $firstError = $null
        try {
            & $WindowView.SetCallbacks `
                -OnDrag $null `
                -OnToggleTopmost $null `
                -OnHide $null `
                -OnCloseRequested $null
        }
        catch {
            $firstError = $_
        }

        try {
            & $TrayView.SetCallbacks `
                -OnToggleVisibility $null `
                -OnToggleTopmost $null `
                -OnRefresh $null `
                -OnToggleStartup $null `
                -OnOpenUsage $null `
                -OnOpenLogs $null `
                -OnExit $null
        }
        catch {
            if ($null -eq $firstError) {
                $firstError = $_
            }
        }

        if ($null -ne $firstError) {
            throw $firstError
        }
    }.GetNewClosure()

    try {
        & $WindowView.SetCallbacks `
            -OnDrag $persistPlacement `
            -OnToggleTopmost $toggleTopmost `
            -OnHide $hide `
            -OnCloseRequested $hide

        & $TrayView.SetCallbacks `
            -OnToggleVisibility $toggleVisibility `
            -OnToggleTopmost $toggleTopmost `
            -OnRefresh $refresh `
            -OnToggleStartup $toggleStartup `
            -OnOpenUsage $openUsage `
            -OnOpenLogs $openLogs `
            -OnExit $exit

        & $TrayView.SetTopmostChecked ([bool](
            Get-MonitorInteractionField -InputObject $windowSettings -Name 'Topmost'
        ))
        & $TrayView.SetStartupChecked ([bool](
            Get-MonitorInteractionField -InputObject $Settings -Name 'Startup'
        ))
    }
    catch {
        try { & $dispose } catch { }
        throw
    }

    return [pscustomobject][ordered]@{
        State = $state
        ShowAndActivate = $showAndActivate
        Hide = $hide
        ToggleVisibility = $toggleVisibility
        ToggleTopmost = $toggleTopmost
        PersistPlacement = $persistPlacement
        ToggleStartup = $toggleStartup
        Refresh = $refresh
        OpenUsage = $openUsage
        OpenLogs = $openLogs
        Exit = $exit
        Dispose = $dispose
    }
}
