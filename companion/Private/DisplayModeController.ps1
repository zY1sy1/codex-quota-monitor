function Get-MonitorDisplayField {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) {
        if (([Collections.IDictionary]$InputObject).Contains($Name)) {
            return ([Collections.IDictionary]$InputObject)[$Name]
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Set-MonitorDisplayField {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Value
    )
    if ($InputObject -is [Collections.IDictionary]) {
        ([Collections.IDictionary]$InputObject)[$Name] = $Value
        return
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $property.Value = $Value
    }
}

function ConvertTo-MonitorDisplayCoordinate {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value -is [bool] -or $Value.GetType().IsEnum) { return $null }
    if ([Type]::GetTypeCode($Value.GetType()) -notin @(
        [TypeCode]::SByte, [TypeCode]::Byte, [TypeCode]::Int16, [TypeCode]::UInt16,
        [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64,
        [TypeCode]::Single, [TypeCode]::Double, [TypeCode]::Decimal
    )) { return $null }
    try { $number = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture) }
    catch { return $null }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
    return [double]$number
}

function New-MonitorDisplayModeController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Settings,
        [Parameter(Mandatory)][object]$FullView,
        [Parameter(Mandatory)][object]$CompactBarView,
        [Parameter(Mandatory)][object]$OrbView,
        [Parameter(Mandatory)][scriptblock]$SaveSettings,
        [Parameter()][AllowNull()][scriptblock]$OnRefreshRequested,
        [switch]$DeferShow
    )

    $getField = ${function:Get-MonitorDisplayField}
    $setField = ${function:Set-MonitorDisplayField}
    $convertCoordinate = ${function:ConvertTo-MonitorDisplayCoordinate}
    $getFocusRow = ${function:Get-CompactFocusRow}
    $appearance = & $getField $Settings 'Appearance'
    $windowSettings = & $getField $Settings 'Window'
    $compactSettings = & $getField $Settings 'Compact'
    if ($null -eq $appearance -or $null -eq $windowSettings -or $null -eq $compactSettings) {
        throw 'Display mode controller requires schema-2 monitor settings.'
    }

    $views = [ordered]@{
        Full = $FullView
        CompactBar = $CompactBarView
        Orb = $OrbView
    }
    $fullWindowSettings = & $getField $windowSettings 'Full'
    $state = [pscustomobject][ordered]@{
        Mode = [string](& $getField $appearance 'DisplayMode')
        Theme = [string](& $getField $appearance 'Theme')
        FullLayout = [string](& $getField $appearance 'FullLayout')
        Visible = [bool](& $getField $fullWindowSettings 'Visible')
        Topmost = [bool](& $getField $fullWindowSettings 'Topmost')
        Snapshot = [object[]]@()
        SnapshotReceived = $false
        RenderedMode = $null
        FocusKey = [string](& $getField $compactSettings 'FocusMetric')
        Disposed = $false
    }
    if ($state.Mode -notin @('Full', 'CompactBar', 'Orb')) { $state.Mode = 'Full' }
    if ($state.Theme -notin @('Light', 'Dark')) { $state.Theme = 'Dark' }
    if ($state.FullLayout -notin @('Overview', 'Tabs')) { $state.FullLayout = 'Overview' }
    if ([string]::IsNullOrWhiteSpace($state.FocusKey)) { $state.FocusKey = 'Auto' }
    $observer = [pscustomobject]@{ Callback = $null; PersistPlacement = $null }
    $notifyStateChanged = {
        if (-not $state.Disposed -and $observer.Callback -is [scriptblock]) {
            & $observer.Callback $state
        }
    }.GetNewClosure()

    $hideViews = {
        foreach ($view in $views.Values) { & $view.Hide }
    }.GetNewClosure()
    $renderView = {
        param([Parameter(Mandatory)][ValidateSet('Full', 'CompactBar', 'Orb')][string]$Mode)
        if ($state.Disposed) { return }
        # Only the requested view is rendered. The 1 Hz snapshot call used to
        # re-text all three views; hidden views are now refreshed by
        # applyVisibility when they are shown again.
        if ($Mode -eq 'Full') {
            $officialRows = @($state.Snapshot | Where-Object {
                [string](& $getField $_ 'SourceKind') -eq 'Official'
            })
            $relayRows = @($state.Snapshot | Where-Object {
                [string](& $getField $_ 'SourceKind') -eq 'Relay'
            })
            & $FullView.RenderGroups -OfficialRows $officialRows -RelayRows $relayRows `
                -State $null -FocusKey $state.FocusKey
        }
        else {
            $pinnedKey = if ($state.FocusKey -eq 'Auto') { $null } else { $state.FocusKey }
            $focus = & $getFocusRow -Rows $state.Snapshot -PinnedKey $pinnedKey
            if ($Mode -eq 'CompactBar') {
                & $CompactBarView.RenderFocus -Row $focus -PinnedKey $pinnedKey
            }
            else {
                & $OrbView.RenderFocus -Row $focus -PinnedKey $pinnedKey
            }
        }
        $state.RenderedMode = $Mode
    }.GetNewClosure()
    $applyVisibility = {
        & $hideViews
        if ($state.Visible) {
            & $views[$state.Mode].Show
            if ($state.SnapshotReceived -and $state.RenderedMode -cne $state.Mode) {
                & $renderView $state.Mode
            }
        }
    }.GetNewClosure()
    $renderSnapshot = {
        if (-not $state.Visible) {
            # Nothing on screen; the next show re-renders from the snapshot.
            $state.RenderedMode = $null
            return
        }
        & $renderView $state.Mode
    }.GetNewClosure()
    $persist = { & $SaveSettings $Settings }.GetNewClosure()

    $setSnapshot = {
        param([Parameter(Position = 0)][AllowEmptyCollection()][object[]]$Rows = @())
        if ($state.Disposed) { return }
        $state.Snapshot = [object[]]@($Rows | Where-Object { $null -ne $_ })
        $state.SnapshotReceived = $true
        & $renderSnapshot
    }.GetNewClosure()

    $setMode = {
        param([Parameter(Mandatory, Position = 0)][ValidateSet('Full', 'CompactBar', 'Orb')][string]$Mode)
        if ($state.Disposed -or $state.Mode -eq $Mode) { return }
        $oldMode = $state.Mode
        # Preserve the outgoing view's current position before its WPF tree
        # is released. Update deferred placement for a later recreation.
        $oldView = $views[$oldMode]
        if ($null -ne $oldView.PSObject.Properties['Release']) {
            $placement = & $oldView.GetPlacement
            if ($null -ne $placement) {
                & $observer.PersistPlacement -Mode $oldMode -Placement $placement
                if ($null -ne $oldView.DeferredState.Placement) {
                    $oldView.DeferredState.Placement.Arguments.Left = $placement.Left
                    $oldView.DeferredState.Placement.Arguments.Top = $placement.Top
                }
            }
        }
        $remember = [bool](& $getField $appearance 'RememberLastMode')
        $oldSetting = [string](& $getField $appearance 'DisplayMode')
        $state.Mode = $Mode
        if ($remember) { & $setField $appearance 'DisplayMode' $Mode }
        try {
            & $applyVisibility
            if ($remember) { & $persist }
            & $notifyStateChanged
        }
        catch {
            $state.Mode = $oldMode
            if ($remember) { & $setField $appearance 'DisplayMode' $oldSetting }
            & $applyVisibility
            $failedView = $views[$Mode]
            if ($null -ne $failedView.PSObject.Properties['Release']) {
                try { & $failedView.Release } catch { }
            }
            throw
        }
        if ($null -ne $oldView.PSObject.Properties['Release']) { & $oldView.Release }
    }.GetNewClosure()

    $setTheme = {
        param([Parameter(Mandatory, Position = 0)][ValidateSet('Light', 'Dark')][string]$Theme)
        if ($state.Disposed -or $state.Theme -eq $Theme) { return }
        $old = $state.Theme
        $state.Theme = $Theme
        & $setField $appearance 'Theme' $Theme
        try {
            foreach ($view in $views.Values) { & $view.SetTheme $Theme }
            & $persist
            & $notifyStateChanged
        }
        catch {
            $state.Theme = $old
            & $setField $appearance 'Theme' $old
            foreach ($view in $views.Values) { & $view.SetTheme $old }
            throw
        }
    }.GetNewClosure()

    $setFullLayout = {
        param([Parameter(Mandatory, Position = 0)][ValidateSet('Overview', 'Tabs')][string]$Layout)
        if ($state.Disposed -or $state.FullLayout -eq $Layout) { return }
        $old = $state.FullLayout
        $state.FullLayout = $Layout
        & $setField $appearance 'FullLayout' $Layout
        try { & $FullView.SetLayout $Layout; & $persist; & $notifyStateChanged }
        catch {
            $state.FullLayout = $old
            & $setField $appearance 'FullLayout' $old
            & $FullView.SetLayout $old
            throw
        }
    }.GetNewClosure()

    $setFocusKey = {
        param([Parameter(Mandatory, Position = 0)][ValidateNotNullOrEmpty()][string]$FocusKey)
        if ($state.Disposed -or $state.FocusKey -ceq $FocusKey) { return }
        $old = $state.FocusKey
        $state.FocusKey = $FocusKey
        & $setField $compactSettings 'FocusMetric' $FocusKey
        try { & $renderSnapshot; & $persist }
        catch {
            $state.FocusKey = $old
            & $setField $compactSettings 'FocusMetric' $old
            & $renderSnapshot
            throw
        }
    }.GetNewClosure()

    $setTopmost = {
        param([Parameter(Mandatory, Position = 0)][bool]$Topmost)
        if ($state.Disposed -or $state.Topmost -eq $Topmost) { return }
        $old = $state.Topmost
        $state.Topmost = $Topmost
        & $setField $fullWindowSettings 'Topmost' $Topmost
        try {
            foreach ($view in $views.Values) { & $view.SetTopmost $Topmost }
            & $persist
            & $notifyStateChanged
        }
        catch {
            $state.Topmost = $old
            & $setField $fullWindowSettings 'Topmost' $old
            foreach ($view in $views.Values) { & $view.SetTopmost $old }
            throw
        }
    }.GetNewClosure()

    $hideAll = {
        if ($state.Disposed -or -not $state.Visible) { return }
        $state.Visible = $false
        $state.RenderedMode = $null
        & $setField $fullWindowSettings 'Visible' $false
        try { & $hideViews; & $persist }
        catch {
            $state.Visible = $true
            & $setField $fullWindowSettings 'Visible' $true
            & $applyVisibility
            throw
        }
    }.GetNewClosure()

    $showCurrent = {
        if ($state.Disposed) { return }
        $wasVisible = $state.Visible
        $state.Visible = $true
        & $setField $fullWindowSettings 'Visible' $true
        try { & $applyVisibility; & $views[$state.Mode].Activate; if (-not $wasVisible) { & $persist } }
        catch {
            $state.Visible = $wasVisible
            & $setField $fullWindowSettings 'Visible' $wasVisible
            & $applyVisibility
            throw
        }
    }.GetNewClosure()

    $openFull = {
        if ($state.Disposed) { return }
        if ($state.Mode -ne 'Full') { & $setMode Full }
        if (-not $state.Visible) { & $showCurrent }
        else { & $applyVisibility; & $FullView.Activate }
    }.GetNewClosure()

    $persistPlacement = {
        param(
            [Parameter(Mandatory)][ValidateSet('Full', 'CompactBar', 'Orb')][string]$Mode,
            [Parameter(Mandatory)][object]$Placement
        )
        if ($state.Disposed) { return }
        $node = & $getField $windowSettings $Mode
        $changed = $false
        foreach ($name in @('Left', 'Top')) {
            $coordinate = & $convertCoordinate (& $getField $Placement $name)
            if ($null -ne $coordinate) {
                & $setField $node $name $coordinate
                $changed = $true
            }
        }
        if ($changed) { & $persist }
    }.GetNewClosure()

    $observer.PersistPlacement = $persistPlacement
    $persistCurrentPlacement = {
        if ($state.Disposed) { return }
        $mode = [string]$state.Mode
        $view = $views[$mode]
        if ($null -eq $view -or $null -eq $view.PSObject.Properties['GetPlacement']) { return }
        try {
            $placement = & $view.GetPlacement
            if ($null -ne $placement) {
                & $persistPlacement -Mode $mode -Placement $placement
            }
        }
        catch { }
    }.GetNewClosure()

    $cycleMode = {
        $next = switch ($state.Mode) { 'Full' { 'CompactBar' }; 'CompactBar' { 'Orb' }; default { 'Full' } }
        & $setMode $next
    }.GetNewClosure()
    $toggleTheme = { & $setTheme $(if ($state.Theme -eq 'Dark') { 'Light' } else { 'Dark' }) }.GetNewClosure()
    $toggleLayout = { & $setFullLayout $(if ($state.FullLayout -eq 'Overview') { 'Tabs' } else { 'Overview' }) }.GetNewClosure()
    $toggleTopmost = { & $setTopmost (-not $state.Topmost) }.GetNewClosure()
    $toggleFocus = {
        param([string]$Key)
        & $setFocusKey $(if ($state.FocusKey -ceq $Key) { 'Auto' } else { $Key })
    }.GetNewClosure()
    $resetFocusForProvider = {
        param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderId)
        if ($state.Disposed -or $state.FocusKey -eq 'Auto') { return }
        $prefix = 'relay:{0}:' -f $ProviderId
        if ($state.FocusKey.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            & $setFocusKey 'Auto'
        }
    }.GetNewClosure()
    $fullDrag = { param($placement) & $persistPlacement -Mode Full -Placement $placement }.GetNewClosure()
    $compactDrag = { param($placement) & $persistPlacement -Mode CompactBar -Placement $placement }.GetNewClosure()
    $orbDrag = { param($placement) & $persistPlacement -Mode Orb -Placement $placement }.GetNewClosure()
    $setStateChangedCallback = {
        param([Parameter(Position = 0)][AllowNull()][scriptblock]$Callback)
        if (-not $state.Disposed) { $observer.Callback = $Callback }
    }.GetNewClosure()

    $dispose = {
        if ($state.Disposed) { return }
        $state.Disposed = $true
        $observer.Callback = $null
        $firstError = $null
        try {
            & $FullView.SetCallbacks -OnDrag $null -OnToggleTopmost $null -OnHide $null `
                -OnCloseRequested $null -OnThemeRequested $null -OnModeRequested $null `
                -OnLayoutRequested $null -OnFocusRequested $null -OnRefreshRequested $null
        } catch { $firstError = $_ }
        foreach ($view in @($CompactBarView, $OrbView)) {
            try { & $view.SetCallbacks -OnDrag $null -OnOpenFull $null -OnModeRequested $null -OnCloseRequested $null }
            catch { if ($null -eq $firstError) { $firstError = $_ } }
        }
        foreach ($view in $views.Values) {
            try { & $view.Dispose }
            catch { if ($null -eq $firstError) { $firstError = $_ } }
        }
        if ($null -ne $firstError) { throw $firstError }
    }.GetNewClosure()

    foreach ($view in $views.Values) { & $view.SetTheme $state.Theme; & $view.SetTopmost $state.Topmost }
    & $FullView.SetLayout $state.FullLayout
    & $FullView.SetCallbacks -OnDrag $fullDrag -OnToggleTopmost $toggleTopmost -OnHide $hideAll `
        -OnCloseRequested $hideAll -OnThemeRequested $toggleTheme -OnModeRequested $cycleMode `
        -OnLayoutRequested $toggleLayout -OnFocusRequested $toggleFocus `
        -OnRefreshRequested $OnRefreshRequested
    & $CompactBarView.SetCallbacks -OnDrag $compactDrag -OnOpenFull $openFull `
        -OnModeRequested $cycleMode -OnCloseRequested $hideAll
    & $OrbView.SetCallbacks -OnDrag $orbDrag -OnOpenFull $openFull `
        -OnModeRequested $cycleMode -OnCloseRequested $hideAll
    if (-not $DeferShow) { & $applyVisibility }

    return [pscustomobject][ordered]@{
        State = $state
        SetSnapshot = $setSnapshot
        SetMode = $setMode
        SetTheme = $setTheme
        SetFullLayout = $setFullLayout
        SetFocusKey = $setFocusKey
        ResetFocusForProvider = $resetFocusForProvider
        SetTopmost = $setTopmost
        HideAll = $hideAll
        ShowCurrent = $showCurrent
        OpenFull = $openFull
        PersistPlacement = $persistPlacement
        PersistCurrentPlacement = $persistCurrentPlacement
        ApplyVisibility = $applyVisibility
        SetStateChangedCallback = $setStateChangedCallback
        Dispose = $dispose
    }
}
