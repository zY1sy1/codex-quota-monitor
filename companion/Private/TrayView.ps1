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
            Topmost = [Windows.Forms.ToolStripMenuItem]::new('始终置顶')
            Refresh = [Windows.Forms.ToolStripMenuItem]::new('立即刷新')
            Startup = [Windows.Forms.ToolStripMenuItem]::new('开机启动')
            Usage = [Windows.Forms.ToolStripMenuItem]::new('打开官方额度页面')
            Logs = [Windows.Forms.ToolStripMenuItem]::new('查看日志')
            Exit = [Windows.Forms.ToolStripMenuItem]::new('退出')
        }
        $menuItems.Topmost.CheckOnClick = $false
        $menuItems.Startup.CheckOnClick = $false

        $contextMenu = [Windows.Forms.ContextMenuStrip]::new()
        foreach ($item in $menuItems.Values) {
            [void]$contextMenu.Items.Add($item)
        }

        $notifyIcon = [Windows.Forms.NotifyIcon]::new()
        $notifyIcon.ContextMenuStrip = $contextMenu
        $notifyIcon.Text = 'Codex 额度'
        $notifyIcon.Icon = $resources.Gray.Icon

        $state = [pscustomobject][ordered]@{
            OwnerThreadId = [Threading.Thread]::CurrentThread.ManagedThreadId
            Disposed = $false
            Severity = 'Gray'
            Callbacks = [pscustomobject][ordered]@{
                OnToggleVisibility = $null
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
        $toggleTopmostHandler = [EventHandler]{
            param($Sender, $EventArgs)
            $callback = $state.Callbacks.OnToggleTopmost
            if (-not $state.Disposed -and $callback -is [scriptblock]) {
                & $callback
            }
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
            Topmost = $toggleTopmostHandler
            Refresh = $refreshHandler
            Startup = $toggleStartupHandler
            Usage = $usageHandler
            Logs = $logsHandler
            Exit = $exitHandler
            DoubleClick = $toggleVisibilityHandler
        }

        $menuItems.ToggleVisibility.add_Click($toggleVisibilityHandler)
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

            $state.Disposed = $true
            $state.Callbacks = $null
            $firstError = $null

            try { $notifyIcon.Visible = $false } catch { $firstError = $_ }

            foreach ($binding in @(
                @($menuItems.ToggleVisibility, 'Click', $state.Delegates.ToggleVisibility),
                @($menuItems.Topmost, 'Click', $state.Delegates.Topmost),
                @($menuItems.Refresh, 'Click', $state.Delegates.Refresh),
                @($menuItems.Startup, 'Click', $state.Delegates.Startup),
                @($menuItems.Usage, 'Click', $state.Delegates.Usage),
                @($menuItems.Logs, 'Click', $state.Delegates.Logs),
                @($menuItems.Exit, 'Click', $state.Delegates.Exit)
            )) {
                try { $binding[0].remove_Click([EventHandler]$binding[2]) } catch {
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
                if ($resource.Handle -ne [IntPtr]::Zero) {
                    try { & $DestroyIconAction $resource.Handle | Out-Null } catch {
                        if ($null -eq $firstError) { $firstError = $_ }
                    }
                    $resource.Handle = [IntPtr]::Zero
                }
                try { $resource.Bitmap.Dispose() } catch {
                    if ($null -eq $firstError) { $firstError = $_ }
                }
            }
            $state.Delegates = $null

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
            SetStartupChecked = $setStartupChecked
            SetVisible = $setVisible
            Dispose = $dispose
        }

        $notifyIcon.Visible = $Visible
        return $view
    }
    catch {
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
                try { & $DestroyIconAction $resource.Handle | Out-Null } catch { }
                $resource.Handle = [IntPtr]::Zero
            }
            try { $resource.Bitmap.Dispose() } catch { }
        }
        throw
    }
}
