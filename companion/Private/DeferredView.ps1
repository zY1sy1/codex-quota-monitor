function New-DeferredMonitorView {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$CreateView)

    $state = [pscustomobject]@{
        Instance = $null
        Configuration = [ordered]@{}
        Placement = $null
        CreateView = $CreateView
        Disposed = $false
    }
    $ensure = {
        if ($state.Disposed) { throw 'The deferred monitor view has been disposed.' }
        if ($null -eq $state.Instance) {
            $view = & $state.CreateView
            try {
                foreach ($entry in $state.Configuration.GetEnumerator()) {
                    $action = $view.($entry.Key)
                    if ($entry.Key -eq 'SetCallbacks') {
                        $callbackArguments = $entry.Value[0]
                        & $action @callbackArguments
                    }
                    else {
                        $arguments = $entry.Value
                        & $action @arguments
                    }
                }
                if ($null -ne $state.Placement) {
                    $placementArguments = $state.Placement.Arguments
                    & $state.Placement.Action -Window $view.Window @placementArguments | Out-Null
                }
                $state.Instance = $view
            }
            catch {
                try { & $view.Dispose } catch { }
                throw
            }
        }
        return $state.Instance
    }.GetNewClosure()
    $configure = {
        param([string]$Method, [object[]]$Arguments)
        if ($state.Disposed) { return }
        $state.Configuration[$Method] = $Arguments
        if ($null -ne $state.Instance) {
            $action = $state.Instance.$Method
            & $action @Arguments
        }
    }.GetNewClosure()
    $release = {
        if ($null -ne $state.Instance) {
            $view = $state.Instance
            $state.Instance = $null
            & $view.Dispose
        }
    }.GetNewClosure()
    $proxy = [pscustomobject][ordered]@{
        DeferredState = $state
        Show = { $view = & $ensure; & $view.Show }.GetNewClosure()
        Activate = { $view = & $ensure; & $view.Activate }.GetNewClosure()
        Hide = { if ($null -ne $state.Instance) { & $state.Instance.Hide } }.GetNewClosure()
        SetTheme = { param($Theme) & $configure 'SetTheme' @($Theme) }.GetNewClosure()
        SetTopmost = { param($Topmost) & $configure 'SetTopmost' @($Topmost) }.GetNewClosure()
        SetLayout = { param($Layout) & $configure 'SetLayout' @($Layout) }.GetNewClosure()
        SetFreshness = { param($IsLive, $Text) & $configure 'SetFreshness' @($IsLive, $Text) }.GetNewClosure()
        SetCallbacks = {
            param($OnDrag, $OnToggleTopmost, $OnHide, $OnCloseRequested, $OnThemeRequested,
                $OnModeRequested, $OnLayoutRequested, $OnFocusRequested, $OnRefreshRequested, $OnOpenFull)
            if ($state.Disposed) { return }
            # Callback arguments are named because Full and compact views
            # expose different positional signatures.
            $callbacks = @{}
            foreach ($entry in $PSBoundParameters.GetEnumerator()) { $callbacks[$entry.Key] = $entry.Value }
            $state.Configuration['SetCallbacks'] = @($callbacks)
            if ($null -ne $state.Instance) { & $state.Instance.SetCallbacks @callbacks }
        }.GetNewClosure()
        RenderGroups = {
            param($OfficialRows, $RelayRows, $State, $FocusKey)
            $view = & $ensure
            & $view.RenderGroups -OfficialRows $OfficialRows -RelayRows $RelayRows -State $State -FocusKey $FocusKey
        }.GetNewClosure()
        RenderFocus = {
            param($Row, $PinnedKey)
            $view = & $ensure
            & $view.RenderFocus -Row $Row -PinnedKey $PinnedKey
        }.GetNewClosure()
        GetPlacement = { if ($null -ne $state.Instance) { & $state.Instance.GetPlacement } }.GetNewClosure()
        ConfigurePlacement = {
            param([scriptblock]$Action, [hashtable]$Arguments)
            $state.Placement = [pscustomobject]@{ Action = $Action; Arguments = $Arguments }
        }.GetNewClosure()
        Release = $release
        Dispose = {
            if ($state.Disposed) { return }
            $state.Disposed = $true
            try { & $release }
            finally {
                $state.Configuration.Clear()
                $state.Placement = $null
                $state.CreateView = $null
            }
        }.GetNewClosure()
    }
    $proxy | Add-Member -MemberType ScriptProperty -Name Window -Value {
        if ($null -ne $this.DeferredState.Instance) { return $this.DeferredState.Instance.Window }
        return $null
    }
    return $proxy
}
