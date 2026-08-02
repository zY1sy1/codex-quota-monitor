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

        [Parameter()]
        [AllowNull()]
        [object]$DisplayController,

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

        [Parameter()]
        [AllowNull()]
        [scriptblock]$OnManageRelays,

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
    $usesDisplayController = $null -ne $DisplayController
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

        if ($usesDisplayController) {
            & $DisplayController.PersistPlacement `
                -Mode ([string]$DisplayController.State.Mode) `
                -Placement $Placement
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

        if ($usesDisplayController) {
            & $DisplayController.HideAll
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

        if ($usesDisplayController) {
            & $DisplayController.ShowCurrent
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

        $isVisible = if ($usesDisplayController) {
            [bool]$DisplayController.State.Visible
        }
        else {
            $placement = & $WindowView.GetPlacement
            [bool](& $getField -InputObject $placement -Name 'Visible')
        }
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

        if ($usesDisplayController) {
            $current = [bool]$DisplayController.State.Topmost
            $desired = -not $current
            try {
                & $DisplayController.SetTopmost $desired
                & $TrayView.SetTopmostChecked $desired
            }
            catch {
                try { & $DisplayController.SetTopmost $current } catch { }
                try { & $TrayView.SetTopmostChecked $current } catch { }
                throw
            }
            return
        }

        $current = [bool](& $getField -InputObject $windowSettings -Name 'Topmost')
        $desired = -not $current
        $windowApplied = $false
        $trayAttempted = $false
        try {
            & $WindowView.SetTopmost $desired
            $windowApplied = $true
            $trayAttempted = $true
            & $TrayView.SetTopmostChecked $desired
            & $setField -InputObject $windowSettings -Name 'Topmost' -Value $desired
            & $SaveSettings $Settings
        }
        catch {
            $primaryError = $_
            & $setField -InputObject $windowSettings -Name 'Topmost' -Value $current
            $rollbackErrors = [Collections.Generic.List[Exception]]::new()
            $rollbackErrors.Add($primaryError.Exception)

            if ($trayAttempted) {
                try { & $TrayView.SetTopmostChecked $current } catch {
                    $rollbackErrors.Add($_.Exception)
                }
            }
            if ($windowApplied) {
                try { & $WindowView.SetTopmost $current } catch {
                    $rollbackErrors.Add($_.Exception)
                }
            }

            if ($rollbackErrors.Count -gt 1) {
                throw [AggregateException]::new(
                    'Changing the always-on-top preference failed and rollback was incomplete.',
                    [Exception[]]$rollbackErrors.ToArray()
                )
            }
            throw $primaryError
        }
    }.GetNewClosure()

    $toggleStartup = {
        if ($state.Disposed) {
            return
        }

        $current = [bool](& $getField -InputObject $Settings -Name 'Startup')
        $desired = -not $current
        $systemApplied = $false
        $trayAttempted = $false

        # The system operation is authoritative. Do not persist a check mark that failed to apply.
        try {
            & $ApplyStartupPreference $desired
            $systemApplied = $true
            $trayAttempted = $true
            & $TrayView.SetStartupChecked $desired
            & $setField -InputObject $Settings -Name 'Startup' -Value $desired
            & $SaveSettings $Settings
        }
        catch {
            $primaryError = $_
            & $setField -InputObject $Settings -Name 'Startup' -Value $current
            $rollbackErrors = [Collections.Generic.List[Exception]]::new()
            $rollbackErrors.Add($primaryError.Exception)

            if ($trayAttempted) {
                try { & $TrayView.SetStartupChecked $current } catch {
                    $rollbackErrors.Add($_.Exception)
                }
            }
            if ($systemApplied) {
                try { & $ApplyStartupPreference $current } catch {
                    $rollbackErrors.Add($_.Exception)
                }
            }

            if ($rollbackErrors.Count -gt 1) {
                throw [AggregateException]::new(
                    'Changing the startup preference failed and rollback was incomplete.',
                    [Exception[]]$rollbackErrors.ToArray()
                )
            }
            throw $primaryError
        }
    }.GetNewClosure()

    $refresh = {
        if (-not $state.Disposed) {
            & $RequestRefresh
        }
    }.GetNewClosure()

    $setDisplayMode = {
        param([ValidateSet('Full', 'CompactBar', 'Orb')][string]$Mode)
        if ($state.Disposed -or -not $usesDisplayController) { return }
        $old = [string]$DisplayController.State.Mode
        try { & $DisplayController.SetMode $Mode; & $TrayView.SetDisplayModeChecked $Mode }
        catch {
            try { & $DisplayController.SetMode $old } catch { }
            try { & $TrayView.SetDisplayModeChecked $old } catch { }
            throw
        }
    }.GetNewClosure()
    $setTheme = {
        param([ValidateSet('Light', 'Dark')][string]$Theme)
        if ($state.Disposed -or -not $usesDisplayController) { return }
        $old = [string]$DisplayController.State.Theme
        try { & $DisplayController.SetTheme $Theme; & $TrayView.SetThemeChecked $Theme }
        catch {
            try { & $DisplayController.SetTheme $old } catch { }
            try { & $TrayView.SetThemeChecked $old } catch { }
            throw
        }
    }.GetNewClosure()
    $setFullLayout = {
        param([ValidateSet('Overview', 'Tabs')][string]$Layout)
        if ($state.Disposed -or -not $usesDisplayController) { return }
        $old = [string]$DisplayController.State.FullLayout
        try { & $DisplayController.SetFullLayout $Layout; & $TrayView.SetFullLayoutChecked $Layout }
        catch {
            try { & $DisplayController.SetFullLayout $old } catch { }
            try { & $TrayView.SetFullLayoutChecked $old } catch { }
            throw
        }
    }.GetNewClosure()
    $manageRelays = {
        if (-not $state.Disposed -and $null -ne $OnManageRelays) { & $OnManageRelays }
    }.GetNewClosure()
    $displayStateChanged = {
        param($displayState)
        if ($state.Disposed) { return }
        & $TrayView.SetDisplayModeChecked ([string]$displayState.Mode)
        & $TrayView.SetThemeChecked ([string]$displayState.Theme)
        & $TrayView.SetFullLayoutChecked ([string]$displayState.FullLayout)
        & $TrayView.SetTopmostChecked ([bool]$displayState.Topmost)
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
        if ($usesDisplayController -and
            $null -ne $DisplayController.PSObject.Properties['SetStateChangedCallback']) {
            try { & $DisplayController.SetStateChangedCallback $null }
            catch { $firstError = $_ }
        }
        if (-not $usesDisplayController) {
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
        }

        try {
            if ($usesDisplayController) {
                & $TrayView.SetCallbacks `
                    -OnToggleVisibility $null -OnSetDisplayMode $null -OnSetTheme $null `
                    -OnSetFullLayout $null -OnManageRelays $null -OnToggleTopmost $null `
                    -OnRefresh $null -OnToggleStartup $null -OnOpenUsage $null `
                    -OnOpenLogs $null -OnExit $null
            }
            else {
                & $TrayView.SetCallbacks `
                    -OnToggleVisibility $null `
                    -OnToggleTopmost $null `
                    -OnRefresh $null `
                    -OnToggleStartup $null `
                    -OnOpenUsage $null `
                    -OnOpenLogs $null `
                    -OnExit $null
            }
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
        if ($usesDisplayController) {
            & $TrayView.SetCallbacks `
                -OnToggleVisibility $toggleVisibility -OnSetDisplayMode $setDisplayMode `
                -OnSetTheme $setTheme -OnSetFullLayout $setFullLayout `
                -OnManageRelays $manageRelays -OnToggleTopmost $toggleTopmost `
                -OnRefresh $refresh -OnToggleStartup $toggleStartup `
                -OnOpenUsage $openUsage -OnOpenLogs $openLogs -OnExit $exit
            & $TrayView.SetDisplayModeChecked ([string]$DisplayController.State.Mode)
            & $TrayView.SetThemeChecked ([string]$DisplayController.State.Theme)
            & $TrayView.SetFullLayoutChecked ([string]$DisplayController.State.FullLayout)
            & $TrayView.SetTopmostChecked ([bool]$DisplayController.State.Topmost)
            if ($null -ne $DisplayController.PSObject.Properties['SetStateChangedCallback']) {
                & $DisplayController.SetStateChangedCallback $displayStateChanged
            }
        }
        else {
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
        }
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
