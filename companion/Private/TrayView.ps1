function Assert-MonitorTrayStaThread {
    [CmdletBinding()]
    param()

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'Codex quota tray view requires an STA thread.'
    }
}

function Assert-MonitorTrayOwnerThread {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$State
    )

    $current = [Threading.Thread]::CurrentThread
    if ($current.ManagedThreadId -ne $State.OwnerThreadId -or
        $current.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'Codex quota tray view must be used on its owning STA thread.'
    }
}

function Initialize-MonitorNativeIconMethods {
    [CmdletBinding()]
    param()

    if ($null -ne ('CodexQuotaMonitor.NativeIconMethodsV1' -as [type])) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexQuotaMonitor
{
    public static class NativeIconMethodsV1
    {
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DestroyIcon(IntPtr handle);
    }
}
'@
}

function Invoke-MonitorDestroyIconNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [IntPtr]$Handle
    )

    if ($Handle -eq [IntPtr]::Zero) {
        return $true
    }

    Initialize-MonitorNativeIconMethods
    return [CodexQuotaMonitor.NativeIconMethodsV1]::DestroyIcon($Handle)
}

function New-MonitorTrayIconResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Drawing.Color]$AccentColor
    )

    $bitmap = $null
    $graphics = $null
    $backgroundBrush = $null
    $accentBrush = $null
    $outlinePen = $null
    $icon = $null
    $handle = [IntPtr]::Zero

    try {
        $bitmap = [Drawing.Bitmap]::new(
            32,
            32,
            [Drawing.Imaging.PixelFormat]::Format32bppArgb
        )
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([Drawing.Color]::Transparent)

        $backgroundBrush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255, 15, 23, 42))
        $accentBrush = [Drawing.SolidBrush]::new($AccentColor)
        $outlinePen = [Drawing.Pen]::new([Drawing.Color]::FromArgb(230, 255, 255, 255), 1.25)

        $graphics.FillEllipse($backgroundBrush, 2, 2, 28, 28)
        $graphics.DrawEllipse($outlinePen, 2.5, 2.5, 27, 27)
        $graphics.FillEllipse($accentBrush, 8, 8, 16, 16)

        $handle = $bitmap.GetHicon()
        if ($handle -eq [IntPtr]::Zero) {
            throw 'Creating a native tray icon handle failed.'
        }

        $icon = [Drawing.Icon]::FromHandle($handle)
        return [pscustomobject][ordered]@{
            Bitmap = $bitmap
            Icon = $icon
            Handle = $handle
        }
    }
    catch {
        if ($null -ne $icon) {
            $icon.Dispose()
        }
        if ($handle -ne [IntPtr]::Zero) {
            Invoke-MonitorDestroyIconNative -Handle $handle | Out-Null
        }
        if ($null -ne $bitmap) {
            $bitmap.Dispose()
        }
        throw
    }
    finally {
        if ($null -ne $outlinePen) {
            $outlinePen.Dispose()
        }
        if ($null -ne $accentBrush) {
            $accentBrush.Dispose()
        }
        if ($null -ne $backgroundBrush) {
            $backgroundBrush.Dispose()
        }
        if ($null -ne $graphics) {
            $graphics.Dispose()
        }
    }
}

function New-TrayView {
    [CmdletBinding()]
    param(
        [bool]$Visible = $true,

        [scriptblock]$DestroyIconAction = {
            param([IntPtr]$Handle)
            Invoke-MonitorDestroyIconNative -Handle $Handle
        }
    )

    Assert-MonitorTrayStaThread
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    Initialize-MonitorNativeIconMethods

    $resources = [ordered]@{}
    $contextMenu = $null
    $notifyIcon = $null
    $state = $null
    $assertOwnerThread = ${function:Assert-MonitorTrayOwnerThread}
    $limitTextElementLength = ${function:Limit-TextElementLength}

    try {
        $colors = [ordered]@{
            Green = [Drawing.Color]::FromArgb(255, 34, 197, 94)
            Yellow = [Drawing.Color]::FromArgb(255, 234, 179, 8)
            Red = [Drawing.Color]::FromArgb(255, 239, 68, 68)
            Gray = [Drawing.Color]::FromArgb(255, 148, 163, 184)
        }
        foreach ($entry in $colors.GetEnumerator()) {
            $resources[$entry.Key] = New-MonitorTrayIconResource -AccentColor $entry.Value
        }

        $menuItems = [ordered]@{
            ToggleVisibility = [Windows.Forms.ToolStripMenuItem]::new('显示/隐藏')
            Settings = [Windows.Forms.ToolStripMenuItem]::new('设置')
            DisplayMode = [Windows.Forms.ToolStripMenuItem]::new('显示模式')
            FullMode = [Windows.Forms.ToolStripMenuItem]::new('完整窗口')
            CompactBarMode = [Windows.Forms.ToolStripMenuItem]::new('迷你条')
            OrbMode = [Windows.Forms.ToolStripMenuItem]::new('额度球')
            Theme = [Windows.Forms.ToolStripMenuItem]::new('主题')
            LightTheme = [Windows.Forms.ToolStripMenuItem]::new('浅色透明')
            DarkTheme = [Windows.Forms.ToolStripMenuItem]::new('深色透明')
            FullLayout = [Windows.Forms.ToolStripMenuItem]::new('完整窗口布局')
            OverviewLayout = [Windows.Forms.ToolStripMenuItem]::new('总览折叠')
            TabsLayout = [Windows.Forms.ToolStripMenuItem]::new('标签切换')
            ManageRelays = [Windows.Forms.ToolStripMenuItem]::new('管理中转站')
            Topmost = [Windows.Forms.ToolStripMenuItem]::new('始终置顶')
            Refresh = [Windows.Forms.ToolStripMenuItem]::new('立即刷新')
            Startup = [Windows.Forms.ToolStripMenuItem]::new('开机启动')
            Usage = [Windows.Forms.ToolStripMenuItem]::new('打开官方额度页面')
            Logs = [Windows.Forms.ToolStripMenuItem]::new('查看日志')
            Exit = [Windows.Forms.ToolStripMenuItem]::new('退出')
        }
        $menuItems.Topmost.CheckOnClick = $false
        $menuItems.Startup.CheckOnClick = $false
        foreach ($item in @(
            $menuItems.FullMode, $menuItems.CompactBarMode, $menuItems.OrbMode,
            $menuItems.LightTheme, $menuItems.DarkTheme,
            $menuItems.OverviewLayout, $menuItems.TabsLayout
        )) { $item.CheckOnClick = $false }
        foreach ($item in @($menuItems.FullMode, $menuItems.CompactBarMode, $menuItems.OrbMode)) {
            [void]$menuItems.DisplayMode.DropDownItems.Add($item)
        }
        foreach ($item in @($menuItems.LightTheme, $menuItems.DarkTheme)) {
            [void]$menuItems.Theme.DropDownItems.Add($item)
        }
        foreach ($item in @($menuItems.OverviewLayout, $menuItems.TabsLayout)) {
            [void]$menuItems.FullLayout.DropDownItems.Add($item)
        }

        $contextMenu = [Windows.Forms.ContextMenuStrip]::new()
        foreach ($item in @(
            $menuItems.ToggleVisibility, $menuItems.Settings, $menuItems.Usage,
            $menuItems.Logs, $menuItems.Exit
        )) {
            [void]$contextMenu.Items.Add($item)
        }

        $notifyIcon = [Windows.Forms.NotifyIcon]::new()
        $notifyIcon.ContextMenuStrip = $contextMenu
        $notifyIcon.Text = 'Codex 额度'
        $notifyIcon.Icon = $resources.Gray.Icon

        $state = [pscustomobject][ordered]@{
            OwnerThreadId = [Threading.Thread]::CurrentThread.ManagedThreadId
            ManagedDisposed = $false
            Disposed = $false
            Severity = 'Gray'
            Callbacks = [pscustomobject][ordered]@{
                OnToggleVisibility = $null
                OnOpenSettings = $null
                OnSetDisplayMode = $null
                OnSetTheme = $null
                OnSetFullLayout = $null
                OnManageRelays = $null
                OnToggleTopmost = $null
                OnRefresh = $null
                OnToggleStartup = $null
                OnOpenUsage = $null
                OnOpenLogs = $null
                OnExit = $null
            }
            Delegates = $null
        }

        $toggleVisibilityHandler = [EventHandler]{
            param($Sender, $EventArgs)
            $callback = $state.Callbacks.OnToggleVisibility
            if (-not $state.Disposed -and $callback -is [scriptblock]) {
                & $callback
            }
        }.GetNewClosure()
        $settingsHandler = [EventHandler]{
            param($Sender, $EventArgs)
            $callback = $state.Callbacks.OnOpenSettings
            if (-not $state.Disposed -and $callback -is [scriptblock]) {
                & $callback
            }
        }.GetNewClosure()
        $toggleTopmostHandler = [EventHandler]{
            param($Sender, $EventArgs)
            $callback = $state.Callbacks.OnToggleTopmost
            if (-not $state.Disposed -and $callback -is [scriptblock]) {
                & $callback
            }
        }.GetNewClosure()
        foreach ($definition in @(
            @($menuItems.FullMode, 'OnSetDisplayMode', 'Full'),
            @($menuItems.CompactBarMode, 'OnSetDisplayMode', 'CompactBar'),
            @($menuItems.OrbMode, 'OnSetDisplayMode', 'Orb'),
            @($menuItems.LightTheme, 'OnSetTheme', 'Light'),
            @($menuItems.DarkTheme, 'OnSetTheme', 'Dark'),
            @($menuItems.OverviewLayout, 'OnSetFullLayout', 'Overview'),
            @($menuItems.TabsLayout, 'OnSetFullLayout', 'Tabs')
        )) {
            $definition[0].Tag = [object[]]@($definition[1], $definition[2])
        }
        $selectionHandler = [EventHandler]{
            param($Sender, $EventArgs)
            $selection = [object[]]$Sender.Tag
            if ($state.Disposed -or $null -eq $state.Callbacks -or $selection.Count -ne 2) {
                return
            }
            $property = $state.Callbacks.PSObject.Properties[[string]$selection[0]]
            $callback = if ($null -eq $property) { $null } else { $property.Value }
            if ($callback -is [scriptblock]) { & $callback ([string]$selection[1]) }
        }.GetNewClosure()
        $fullModeHandler = $selectionHandler
        $compactBarModeHandler = $selectionHandler
        $orbModeHandler = $selectionHandler
        $lightThemeHandler = $selectionHandler
        $darkThemeHandler = $selectionHandler
        $overviewLayoutHandler = $selectionHandler
        $tabsLayoutHandler = $selectionHandler
        $manageRelaysHandler = [EventHandler]{
            param($Sender, $EventArgs)
            $callback = $state.Callbacks.OnManageRelays
            if (-not $state.Disposed -and $callback -is [scriptblock]) { & $callback }
        }.GetNewClosure()
        $refreshHandler = [EventHandler]{
            param($Sender, $EventArgs)
            $callback = $state.Callbacks.OnRefresh
            if (-not $state.Disposed -and $callback -is [scriptblock]) {
                & $callback
            }
        }.GetNewClosure()
        $toggleStartupHandler = [EventHandler]{
            param($Sender, $EventArgs)
            $callback = $state.Callbacks.OnToggleStartup
            if (-not $state.Disposed -and $callback -is [scriptblock]) {
                & $callback
            }
        }.GetNewClosure()
        $usageHandler = [EventHandler]{
            param($Sender, $EventArgs)
            $callback = $state.Callbacks.OnOpenUsage
            if (-not $state.Disposed -and $callback -is [scriptblock]) {
                & $callback
            }
        }.GetNewClosure()
        $logsHandler = [EventHandler]{
            param($Sender, $EventArgs)
            $callback = $state.Callbacks.OnOpenLogs
            if (-not $state.Disposed -and $callback -is [scriptblock]) {
                & $callback
            }
        }.GetNewClosure()
        $exitHandler = [EventHandler]{
            param($Sender, $EventArgs)
            $callback = $state.Callbacks.OnExit
            if (-not $state.Disposed -and $callback -is [scriptblock]) {
                & $callback
            }
        }.GetNewClosure()

        $state.Delegates = [pscustomobject][ordered]@{
            ToggleVisibility = $toggleVisibilityHandler
            Settings = $settingsHandler
            FullMode = $fullModeHandler
            CompactBarMode = $compactBarModeHandler
            OrbMode = $orbModeHandler
            LightTheme = $lightThemeHandler
            DarkTheme = $darkThemeHandler
            OverviewLayout = $overviewLayoutHandler
            TabsLayout = $tabsLayoutHandler
            ManageRelays = $manageRelaysHandler
            Topmost = $toggleTopmostHandler
            Refresh = $refreshHandler
            Startup = $toggleStartupHandler
            Usage = $usageHandler
            Logs = $logsHandler
            Exit = $exitHandler
            DoubleClick = $toggleVisibilityHandler
        }

        $menuItems.ToggleVisibility.add_Click($toggleVisibilityHandler)
        $menuItems.Settings.add_Click($settingsHandler)
        $menuItems.FullMode.add_Click($fullModeHandler)
        $menuItems.CompactBarMode.add_Click($compactBarModeHandler)
        $menuItems.OrbMode.add_Click($orbModeHandler)
        $menuItems.LightTheme.add_Click($lightThemeHandler)
        $menuItems.DarkTheme.add_Click($darkThemeHandler)
        $menuItems.OverviewLayout.add_Click($overviewLayoutHandler)
        $menuItems.TabsLayout.add_Click($tabsLayoutHandler)
        $menuItems.ManageRelays.add_Click($manageRelaysHandler)
        $menuItems.Topmost.add_Click($toggleTopmostHandler)
        $menuItems.Refresh.add_Click($refreshHandler)
        $menuItems.Startup.add_Click($toggleStartupHandler)
        $menuItems.Usage.add_Click($usageHandler)
        $menuItems.Logs.add_Click($logsHandler)
        $menuItems.Exit.add_Click($exitHandler)
        $notifyIcon.add_DoubleClick($toggleVisibilityHandler)

        $setCallbacks = {
            param(
                [AllowNull()][scriptblock]$OnToggleVisibility,
                [AllowNull()][scriptblock]$OnOpenSettings,
                [AllowNull()][scriptblock]$OnSetDisplayMode,
                [AllowNull()][scriptblock]$OnSetTheme,
                [AllowNull()][scriptblock]$OnSetFullLayout,
                [AllowNull()][scriptblock]$OnManageRelays,
                [AllowNull()][scriptblock]$OnToggleTopmost,
                [AllowNull()][scriptblock]$OnRefresh,
                [AllowNull()][scriptblock]$OnToggleStartup,
                [AllowNull()][scriptblock]$OnOpenUsage,
                [AllowNull()][scriptblock]$OnOpenLogs,
                [AllowNull()][scriptblock]$OnExit
            )

            & $assertOwnerThread -State $state
            if ($state.Disposed) {
                return
            }

            $state.Callbacks = [pscustomobject][ordered]@{
                OnToggleVisibility = $OnToggleVisibility
                OnOpenSettings = $OnOpenSettings
                OnSetDisplayMode = $OnSetDisplayMode
                OnSetTheme = $OnSetTheme
                OnSetFullLayout = $OnSetFullLayout
                OnManageRelays = $OnManageRelays
                OnToggleTopmost = $OnToggleTopmost
                OnRefresh = $OnRefresh
                OnToggleStartup = $OnToggleStartup
                OnOpenUsage = $OnOpenUsage
                OnOpenLogs = $OnOpenLogs
                OnExit = $OnExit
            }
        }.GetNewClosure()

        $setSeverity = {
            param(
                [Parameter(Mandatory, Position = 0)]
                [ValidateSet('Green', 'Yellow', 'Red', 'Gray')]
                [string]$Severity
            )

            & $assertOwnerThread -State $state
            if ($state.Disposed) {
                return
            }

            $notifyIcon.Icon = $resources[$Severity].Icon
            $state.Severity = $Severity
        }.GetNewClosure()

        $setTooltip = {
            param(
                [Parameter(Mandatory, Position = 0)]
                [AllowEmptyString()]
                [string]$Text
            )

            & $assertOwnerThread -State $state
            if ($state.Disposed) {
                return
            }

            $limited = & $limitTextElementLength -Text $Text -MaximumLength 63
            if ([string]::IsNullOrEmpty($limited)) {
                $limited = 'Codex 额度'
            }
            $notifyIcon.Text = $limited
        }.GetNewClosure()

        $setTopmostChecked = {
            param([Parameter(Mandatory, Position = 0)][bool]$Checked)
            & $assertOwnerThread -State $state
            if (-not $state.Disposed) {
                $menuItems.Topmost.Checked = $Checked
            }
        }.GetNewClosure()

        $setDisplayModeChecked = {
            param([Parameter(Mandatory, Position = 0)][ValidateSet('Full', 'CompactBar', 'Orb')][string]$Mode)
            & $assertOwnerThread -State $state
            if ($state.Disposed) { return }
            $menuItems.FullMode.Checked = $Mode -eq 'Full'
            $menuItems.CompactBarMode.Checked = $Mode -eq 'CompactBar'
            $menuItems.OrbMode.Checked = $Mode -eq 'Orb'
        }.GetNewClosure()
        $setThemeChecked = {
            param([Parameter(Mandatory, Position = 0)][ValidateSet('Light', 'Dark')][string]$Theme)
            & $assertOwnerThread -State $state
            if ($state.Disposed) { return }
            $menuItems.LightTheme.Checked = $Theme -eq 'Light'
            $menuItems.DarkTheme.Checked = $Theme -eq 'Dark'
        }.GetNewClosure()
        $setFullLayoutChecked = {
            param([Parameter(Mandatory, Position = 0)][ValidateSet('Overview', 'Tabs')][string]$Layout)
            & $assertOwnerThread -State $state
            if ($state.Disposed) { return }
            $menuItems.OverviewLayout.Checked = $Layout -eq 'Overview'
            $menuItems.TabsLayout.Checked = $Layout -eq 'Tabs'
        }.GetNewClosure()

        $setStartupChecked = {
            param([Parameter(Mandatory, Position = 0)][bool]$Checked)
            & $assertOwnerThread -State $state
            if (-not $state.Disposed) {
                $menuItems.Startup.Checked = $Checked
            }
        }.GetNewClosure()

        $setVisible = {
            param([Parameter(Mandatory, Position = 0)][bool]$IsVisible)
            & $assertOwnerThread -State $state
            if (-not $state.Disposed) {
                $notifyIcon.Visible = $IsVisible
            }
        }.GetNewClosure()

        $dispose = {
            & $assertOwnerThread -State $state
            if ($state.Disposed) {
                return
            }

            $state.Callbacks = $null
            $firstError = $null

            if (-not $state.ManagedDisposed) {
                try { $notifyIcon.Visible = $false } catch { $firstError = $_ }

                foreach ($binding in @(
                    @($menuItems.ToggleVisibility, $state.Delegates.ToggleVisibility),
                    @($menuItems.Settings, $state.Delegates.Settings),
                    @($menuItems.FullMode, $state.Delegates.FullMode),
                    @($menuItems.CompactBarMode, $state.Delegates.CompactBarMode),
                    @($menuItems.OrbMode, $state.Delegates.OrbMode),
                    @($menuItems.LightTheme, $state.Delegates.LightTheme),
                    @($menuItems.DarkTheme, $state.Delegates.DarkTheme),
                    @($menuItems.OverviewLayout, $state.Delegates.OverviewLayout),
                    @($menuItems.TabsLayout, $state.Delegates.TabsLayout),
                    @($menuItems.ManageRelays, $state.Delegates.ManageRelays),
                    @($menuItems.Topmost, $state.Delegates.Topmost),
                    @($menuItems.Refresh, $state.Delegates.Refresh),
                    @($menuItems.Startup, $state.Delegates.Startup),
                    @($menuItems.Usage, $state.Delegates.Usage),
                    @($menuItems.Logs, $state.Delegates.Logs),
                    @($menuItems.Exit, $state.Delegates.Exit)
                )) {
                    try { $binding[0].remove_Click([EventHandler]$binding[1]) } catch {
                        if ($null -eq $firstError) { $firstError = $_ }
                    }
                }
                try { $notifyIcon.remove_DoubleClick([EventHandler]$state.Delegates.DoubleClick) } catch {
                    if ($null -eq $firstError) { $firstError = $_ }
                }

                try { $notifyIcon.Icon = $null } catch {
                    if ($null -eq $firstError) { $firstError = $_ }
                }
                try { $notifyIcon.ContextMenuStrip = $null } catch {
                    if ($null -eq $firstError) { $firstError = $_ }
                }
                try { $notifyIcon.Dispose() } catch {
                    if ($null -eq $firstError) { $firstError = $_ }
                }
                try { $contextMenu.Dispose() } catch {
                    if ($null -eq $firstError) { $firstError = $_ }
                }

                foreach ($resource in $resources.Values) {
                    try { $resource.Icon.Dispose() } catch {
                        if ($null -eq $firstError) { $firstError = $_ }
                    }
                    try { $resource.Bitmap.Dispose() } catch {
                        if ($null -eq $firstError) { $firstError = $_ }
                    }
                }
                $state.Delegates = $null

                if ($null -eq $firstError) {
                    $state.ManagedDisposed = $true
                }
            }

            if ($null -ne $firstError) {
                throw $firstError
            }

            foreach ($resource in $resources.Values) {
                if ($resource.Handle -eq [IntPtr]::Zero) {
                    continue
                }

                try {
                    $destroyed = & $DestroyIconAction $resource.Handle
                    if ($destroyed -is [bool] -and -not $destroyed) {
                        throw [InvalidOperationException]::new(
                            'The native tray icon handle could not be released.'
                        )
                    }
                    $resource.Handle = [IntPtr]::Zero
                }
                catch {
                    if ($null -eq $firstError) { $firstError = $_ }
                }
            }

            $remainingHandles = @(
                $resources.Values | Where-Object Handle -ne ([IntPtr]::Zero)
            ).Count
            $state.Disposed = $state.ManagedDisposed -and $remainingHandles -eq 0

            if ($null -ne $firstError) {
                throw $firstError
            }
        }.GetNewClosure()

        $view = [pscustomobject][ordered]@{
            NotifyIcon = $notifyIcon
            ContextMenu = $contextMenu
            MenuItems = $menuItems
            Resources = $resources
            State = $state
            SetCallbacks = $setCallbacks
            SetSeverity = $setSeverity
            SetTooltip = $setTooltip
            SetTopmostChecked = $setTopmostChecked
            SetDisplayModeChecked = $setDisplayModeChecked
            SetThemeChecked = $setThemeChecked
            SetFullLayoutChecked = $setFullLayoutChecked
            SetStartupChecked = $setStartupChecked
            SetVisible = $setVisible
            Dispose = $dispose
        }

        $notifyIcon.Visible = $Visible
        return $view
    }
    catch {
        $constructionError = $_
        $unreleasedHandles = [Collections.Generic.List[long]]::new()
        if ($null -ne $notifyIcon) {
            try { $notifyIcon.Visible = $false } catch { }
            try { $notifyIcon.Dispose() } catch { }
        }
        if ($null -ne $contextMenu) {
            try { $contextMenu.Dispose() } catch { }
        }
        foreach ($resource in $resources.Values) {
            try { $resource.Icon.Dispose() } catch { }
            if ($resource.Handle -ne [IntPtr]::Zero) {
                try {
                    $destroyed = & $DestroyIconAction $resource.Handle
                    if ($destroyed -is [bool] -and -not $destroyed) {
                        $unreleasedHandles.Add($resource.Handle.ToInt64())
                    }
                    else {
                        $resource.Handle = [IntPtr]::Zero
                    }
                }
                catch {
                    $unreleasedHandles.Add($resource.Handle.ToInt64())
                }
            }
            try { $resource.Bitmap.Dispose() } catch { }
        }
        if ($unreleasedHandles.Count -gt 0) {
            $constructionError.Exception.Data['UnreleasedIconHandles'] = [long[]]$unreleasedHandles.ToArray()
        }
        throw $constructionError
    }
}
