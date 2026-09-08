function New-SettingsController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$View,

        [Parameter(Mandatory)]
        [scriptblock]$GetSnapshot,

        [Parameter(Mandatory)]
        [scriptblock]$SetDisplayMode,

        [Parameter(Mandatory)]
        [scriptblock]$SetTheme,

        [Parameter(Mandatory)]
        [scriptblock]$SetFullLayout,

        [Parameter(Mandatory)]
        [scriptblock]$ToggleTopmost,

        [Parameter(Mandatory)]
        [scriptblock]$ToggleStartup,

        [Parameter(Mandatory)]
        [scriptblock]$ToggleTodaySpend,

        [Parameter(Mandatory)]
        [scriptblock]$RequestRefresh,

        [Parameter()]
        [AllowNull()]
        [scriptblock]$ManageRelays
    )

    $state = [pscustomobject][ordered]@{
        Disposed = $false
        Showing = $false
    }

    $render = {
        if ($state.Disposed) { return }
        $snapshot = & $GetSnapshot
        & $View.SetSnapshot `
            -Mode ([string]$snapshot.Mode) `
            -Theme ([string]$snapshot.Theme) `
            -FullLayout ([string]$snapshot.FullLayout) `
            -Topmost ([bool]$snapshot.Topmost) `
            -Startup ([bool]$snapshot.Startup) `
            -ShowTodaySpend ([bool]$snapshot.ShowTodaySpend)
    }.GetNewClosure()

    $completeSetting = {
        if ($state.Disposed) { return }
        & $render
        & $View.SetStatus '设置已同步' 'Success'
    }.GetNewClosure()

    $failWith = {
        param([string]$Prefix, [Exception]$ErrorRecord)
        if ($state.Disposed) { return }
        & $render
        & $View.SetStatus ("$Prefix" + [string]$ErrorRecord.Message) 'Error'
    }.GetNewClosure()

    $setModeAction = {
        param([string]$Mode)
        if ($state.Disposed) { return }
        try {
            & $SetDisplayMode $Mode
            & $completeSetting
        }
        catch {
            & $failWith '无法应用显示模式：' $_.Exception
        }
    }.GetNewClosure()

    $setThemeAction = {
        param([string]$Theme)
        if ($state.Disposed) { return }
        try {
            & $SetTheme $Theme
            & $completeSetting
        }
        catch {
            & $failWith '无法应用主题：' $_.Exception
        }
    }.GetNewClosure()

    $setLayoutAction = {
        param([string]$Layout)
        if ($state.Disposed) { return }
        try {
            & $SetFullLayout $Layout
            & $completeSetting
        }
        catch {
            & $failWith '无法应用布局：' $_.Exception
        }
    }.GetNewClosure()

    $topmostAction = {
        if ($state.Disposed) { return }
        try {
            & $ToggleTopmost
            & $completeSetting
        }
        catch {
            & $failWith '无法切换置顶：' $_.Exception
        }
    }.GetNewClosure()

    $startupAction = {
        if ($state.Disposed) { return }
        try {
            & $ToggleStartup
            & $completeSetting
        }
        catch {
            & $failWith '无法切换开机启动：' $_.Exception
        }
    }.GetNewClosure()

    $todaySpendAction = {
        if ($state.Disposed) { return }
        try {
            & $ToggleTodaySpend
            & $completeSetting
        }
        catch {
            & $failWith '无法切换今日消耗显示：' $_.Exception
        }
    }.GetNewClosure()

    $refreshAction = {
        if ($state.Disposed) { return }
        try {
            & $RequestRefresh
            & $View.SetStatus '已请求刷新。' 'Success'
        }
        catch {
            & $failWith '无法刷新：' $_.Exception
        }
    }.GetNewClosure()

    $manageRelaysAction = {
        if ($state.Disposed -or $null -eq $ManageRelays) { return }
        try {
            & $ManageRelays
        }
        catch {
            & $failWith '无法打开管理中转站：' $_.Exception
        }
    }.GetNewClosure()

    $closingAction = { }.GetNewClosure()

    $show = {
        if ($state.Disposed -or $state.Showing) { return }
        $state.Showing = $true
        try {
            & $render
            $null = & $View.ShowDialog
        }
        finally {
            $state.Showing = $false
        }
    }.GetNewClosure()

    $dispose = {
        if ($state.Disposed) { return }
        $state.Disposed = $true
        try {
            & $View.SetCallbacks `
                -OnSetDisplayMode $null -OnSetTheme $null -OnSetFullLayout $null `
                -OnToggleTopmost $null -OnToggleStartup $null -OnToggleTodaySpend $null `
                -OnRefresh $null `
                -OnManageRelays $null -OnClosing $null
        }
        catch { }
        try { & $View.Dispose } catch { }
    }.GetNewClosure()

    & $View.SetCallbacks `
        -OnSetDisplayMode $setModeAction `
        -OnSetTheme $setThemeAction `
        -OnSetFullLayout $setLayoutAction `
        -OnToggleTopmost $topmostAction `
        -OnToggleStartup $startupAction `
        -OnToggleTodaySpend $todaySpendAction `
        -OnRefresh $refreshAction `
        -OnManageRelays $manageRelaysAction `
        -OnClosing $closingAction

    return [pscustomobject][ordered]@{
        State = $state
        Show = $show
        Dispose = $dispose
    }
}
