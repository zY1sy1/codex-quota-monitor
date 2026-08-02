BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\companion\Private\ObjectAccess.ps1')
    . (Join-Path $PSScriptRoot '..\..\companion\Private\Presentation.ps1')

    $script:TrayViewPath = Join-Path $PSScriptRoot '..\..\companion\Private\TrayView.ps1'
    if (Test-Path -LiteralPath $script:TrayViewPath -PathType Leaf) {
        . $script:TrayViewPath
    }

    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
}

Describe 'system tray composition' {
    BeforeEach {
        $script:DestroyedHandles = [Collections.Generic.List[long]]::new()
        $script:View = New-TrayView -Visible:$false -DestroyIconAction {
            param([IntPtr]$Handle)

            $script:DestroyedHandles.Add($Handle.ToInt64())
            [CodexQuotaMonitor.NativeIconMethodsV1]::DestroyIcon($Handle) | Out-Null
        }
    }

    AfterEach {
        if ($null -ne $script:View -and -not $script:View.State.Disposed) {
            & $script:View.Dispose
        }
    }

    It 'requires an STA thread and starts hidden when requested' {
        [Threading.Thread]::CurrentThread.GetApartmentState().ToString() | Should -BeExactly 'STA'
        $View.NotifyIcon | Should -BeOfType ([Windows.Forms.NotifyIcon])
        $View.NotifyIcon.Visible | Should -BeFalse
        $View.ContextMenu | Should -BeOfType ([Windows.Forms.ContextMenuStrip])
    }

    It 'builds the exact ordered Chinese menu contract' {
        @($View.ContextMenu.Items | ForEach-Object Text) | Should -Be @(
            '显示/隐藏'
            '显示模式'
            '主题'
            '完整窗口布局'
            '管理中转站'
            '始终置顶'
            '立即刷新'
            '开机启动'
            '打开官方额度页面'
            '查看日志'
            '退出'
        )

        @($View.MenuItems.Keys) | Should -Be @(
            'ToggleVisibility', 'DisplayMode', 'FullMode', 'CompactBarMode', 'OrbMode',
            'Theme', 'LightTheme', 'DarkTheme', 'FullLayout', 'OverviewLayout', 'TabsLayout',
            'ManageRelays', 'Topmost', 'Refresh', 'Startup', 'Usage', 'Logs', 'Exit'
        )
        @($View.MenuItems.DisplayMode.DropDownItems | ForEach-Object Text) | Should -Be @(
            '完整窗口', '迷你条', '额度球'
        )
        @($View.MenuItems.Theme.DropDownItems | ForEach-Object Text) | Should -Be @(
            '浅色透明', '深色透明'
        )
        @($View.MenuItems.FullLayout.DropDownItems | ForEach-Object Text) | Should -Be @(
            '总览折叠', '标签切换'
        )
    }

    It 'creates four retained 32-pixel native icon resources' {
        @($View.Resources.Keys) | Should -Be @('Green', 'Yellow', 'Red', 'Gray')
        $handles = foreach ($severity in @('Green', 'Yellow', 'Red', 'Gray')) {
            $resource = $View.Resources[$severity]
            $resource.Bitmap | Should -BeOfType ([Drawing.Bitmap])
            $resource.Bitmap.Width | Should -Be 32
            $resource.Bitmap.Height | Should -Be 32
            $resource.Icon | Should -BeOfType ([Drawing.Icon])
            $resource.Handle | Should -Not -Be ([IntPtr]::Zero)
            $resource.Handle.ToInt64()
        }

        @($handles | Select-Object -Unique).Count | Should -Be 4
    }

    It 'replaces callbacks atomically and routes menu plus double-click exactly once' {
        $calls = [Collections.Generic.List[string]]::new()
        & $View.SetCallbacks `
            -OnToggleVisibility { $calls.Add('visibility') } `
            -OnSetDisplayMode { param($value) $calls.Add("mode:$value") } `
            -OnSetTheme { param($value) $calls.Add("theme:$value") } `
            -OnSetFullLayout { param($value) $calls.Add("layout:$value") } `
            -OnManageRelays { $calls.Add('relays') } `
            -OnToggleTopmost { $calls.Add('topmost') } `
            -OnRefresh { $calls.Add('refresh') } `
            -OnToggleStartup { $calls.Add('startup') } `
            -OnOpenUsage { $calls.Add('usage') } `
            -OnOpenLogs { $calls.Add('logs') } `
            -OnExit { $calls.Add('exit') }

        foreach ($key in @(
            'ToggleVisibility', 'CompactBarMode', 'LightTheme', 'TabsLayout', 'ManageRelays',
            'Topmost', 'Refresh', 'Startup', 'Usage', 'Logs', 'Exit'
        )) {
            $View.MenuItems[$key].PerformClick()
        }
        $View.State.Delegates.DoubleClick.Invoke($View.NotifyIcon, [EventArgs]::Empty)

        @($calls) | Should -Be @(
            'visibility', 'mode:CompactBar', 'theme:Light', 'layout:Tabs', 'relays',
            'topmost', 'refresh', 'startup', 'usage', 'logs', 'exit', 'visibility'
        )
        @($View.State.Callbacks.PSObject.Properties.Name) | Should -Be @(
            'OnToggleVisibility', 'OnSetDisplayMode', 'OnSetTheme', 'OnSetFullLayout',
            'OnManageRelays', 'OnToggleTopmost', 'OnRefresh', 'OnToggleStartup',
            'OnOpenUsage', 'OnOpenLogs', 'OnExit'
        )
    }

    It 'switches severity using retained handles that survive collection' {
        foreach ($severity in @('Green', 'Yellow', 'Red', 'Gray')) {
            & $View.SetSeverity $severity
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()

            $View.State.Severity | Should -BeExactly $severity
            $View.NotifyIcon.Icon.Handle | Should -Be $View.Resources[$severity].Icon.Handle
            $View.Resources[$severity].Handle | Should -Not -Be ([IntPtr]::Zero)
        }
    }

    It 'limits tooltip text without splitting Unicode text elements' {
        $text = ('额度🚀e' + [char]0x0301 + ' · ') * 20
        $expected = Limit-TextElementLength -Text $text -MaximumLength 63

        & $View.SetTooltip $text

        $View.NotifyIcon.Text | Should -BeExactly $expected
        $View.NotifyIcon.Text.Length | Should -BeLessOrEqual 63
        [Globalization.StringInfo]::ParseCombiningCharacters($View.NotifyIcon.Text) | Should -Not -BeNullOrEmpty
    }

    It 'updates check marks without invoking action callbacks' {
        $script:calls = 0
        & $View.SetCallbacks `
            -OnSetDisplayMode { $script:calls++ } `
            -OnSetTheme { $script:calls++ } `
            -OnSetFullLayout { $script:calls++ } `
            -OnToggleTopmost { $script:calls++ } `
            -OnToggleStartup { $script:calls++ }

        & $View.SetDisplayModeChecked Orb
        & $View.SetThemeChecked Light
        & $View.SetFullLayoutChecked Tabs
        & $View.SetTopmostChecked $true
        & $View.SetStartupChecked $true

        $View.MenuItems.FullMode.Checked | Should -BeFalse
        $View.MenuItems.CompactBarMode.Checked | Should -BeFalse
        $View.MenuItems.OrbMode.Checked | Should -BeTrue
        $View.MenuItems.LightTheme.Checked | Should -BeTrue
        $View.MenuItems.DarkTheme.Checked | Should -BeFalse
        $View.MenuItems.OverviewLayout.Checked | Should -BeFalse
        $View.MenuItems.TabsLayout.Checked | Should -BeTrue
        $View.MenuItems.Topmost.Checked | Should -BeTrue
        $View.MenuItems.Startup.Checked | Should -BeTrue
        $script:calls | Should -Be 0
    }

    It 'clears callbacks and destroys every retained native handle exactly once' {
        $expectedHandles = @($View.Resources.Values | ForEach-Object { $_.Handle.ToInt64() })

        { & $View.Dispose; & $View.Dispose } | Should -Not -Throw

        $View.State.Disposed | Should -BeTrue
        $View.State.Callbacks | Should -BeNullOrEmpty
        $View.NotifyIcon.Visible | Should -BeFalse
        $View.NotifyIcon.Icon | Should -BeNullOrEmpty
        @($script:DestroyedHandles).Count | Should -Be 4
        @($script:DestroyedHandles | Select-Object -Unique).Count | Should -Be 4
        @($script:DestroyedHandles | Sort-Object) | Should -Be @($expectedHandles | Sort-Object)
        $script:View = $null
    }

    It 'retains and retries a native handle when destruction reports <Mode>' -ForEach @(
        @{ Mode = 'False' }
        @{ Mode = 'Throw' }
    ) {
        & $View.Dispose
        $script:DestroyedHandles.Clear()
        $script:DestroyFailureMode = $Mode
        $script:FailureHandle = [long]0
        $script:FailureAttempts = 0

        $script:View = New-TrayView -Visible:$false -DestroyIconAction {
            param([IntPtr]$Handle)

            $numericHandle = $Handle.ToInt64()
            if ($script:FailureHandle -eq 0) {
                $script:FailureHandle = $numericHandle
            }
            if ($numericHandle -eq $script:FailureHandle -and $script:FailureAttempts -eq 0) {
                $script:FailureAttempts++
                if ($script:DestroyFailureMode -eq 'Throw') {
                    throw 'Synthetic DestroyIcon failure.'
                }
                return $false
            }

            if ($numericHandle -eq $script:FailureHandle) {
                $script:FailureAttempts++
            }
            $script:DestroyedHandles.Add($numericHandle)
            return [CodexQuotaMonitor.NativeIconMethodsV1]::DestroyIcon($Handle)
        }

        { & $View.Dispose } | Should -Throw
        $View.State.ManagedDisposed | Should -BeTrue
        $View.State.Disposed | Should -BeFalse
        @($View.Resources.Values | Where-Object Handle -ne ([IntPtr]::Zero)).Count | Should -Be 1
        @($script:DestroyedHandles).Count | Should -Be 3

        { & $View.Dispose } | Should -Not -Throw
        $View.State.Disposed | Should -BeTrue
        @($View.Resources.Values | Where-Object Handle -ne ([IntPtr]::Zero)).Count | Should -Be 0
        $script:FailureAttempts | Should -Be 2
        @($script:DestroyedHandles | Select-Object -Unique).Count | Should -Be 4
        $script:View = $null
    }

    It 'can be dot-sourced repeatedly without a native type collision' {
        { . $script:TrayViewPath; . $script:TrayViewPath } | Should -Not -Throw
        'CodexQuotaMonitor.NativeIconMethodsV1' -as [type] | Should -Not -BeNullOrEmpty
    }

    It 'rejects MTA deterministically in a separate PowerShell process' {
        $pwsh = (Get-Process -Id $PID).Path
        $escapedView = $TrayViewPath.Replace("'", "''")
        $command = @"
. '$escapedView'
try {
    New-TrayView -Visible:`$false | Out-Null
    exit 19
}
catch {
    if (`$_.Exception.Message -ne 'Codex quota tray view requires an STA thread.') {
        [Console]::Error.WriteLine(`$_.Exception.Message)
        exit 20
    }
    exit 0
}
"@

        $process = Start-Process -FilePath $pwsh -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-Mta', '-Command', $command
        ) -Wait -PassThru -WindowStyle Hidden
        try {
            $process.ExitCode | Should -Be 0
        }
        finally {
            $process.Dispose()
        }
    }
}
