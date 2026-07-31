BeforeAll {
    $script:ControllerPath = Join-Path $PSScriptRoot '..\..\companion\Private\InteractionController.ps1'
    if (Test-Path -LiteralPath $script:ControllerPath -PathType Leaf) {
        . $script:ControllerPath
    }
}

Describe 'monitor interaction controller' {
    BeforeEach {
        $script:Settings = [ordered]@{
            SchemaVersion = 1
            Window = [ordered]@{
                Left = [double]10
                Top = [double]20
                Topmost = $true
                Visible = $true
            }
            Startup = $true
        }
        $script:WindowState = [ordered]@{
            Left = [double]10
            Top = [double]20
            Topmost = $true
            Visible = $true
            ActivateCalls = 0
            HideCalls = 0
            SetTopmostCalls = [Collections.Generic.List[bool]]::new()
        }
        $script:WindowCallbacks = $null
        $script:TrayCallbacks = $null
        $script:TrayState = [ordered]@{
            TopmostChecked = $null
            StartupChecked = $null
            DisposeCalls = 0
        }
        $script:SaveCalls = 0
        $script:ApplyStartupCalls = [Collections.Generic.List[bool]]::new()
        $script:StartupFailure = $false
        $script:RefreshCalls = 0
        $script:OpenedTargets = [Collections.Generic.List[string]]::new()
        $script:ExitEvent = [Threading.EventWaitHandle]::new(
            $false,
            [Threading.EventResetMode]::AutoReset
        )

        $script:WindowView = [pscustomobject]@{
            Show = {
                $script:WindowState.Visible = $true
            }
            Hide = {
                $script:WindowState.HideCalls++
                $script:WindowState.Visible = $false
            }
            Activate = {
                $script:WindowState.ActivateCalls++
                $script:WindowState.Visible = $true
            }
            SetTopmost = {
                param([bool]$Topmost)
                $script:WindowState.Topmost = $Topmost
                $script:WindowState.SetTopmostCalls.Add($Topmost)
            }
            GetPlacement = {
                [pscustomobject][ordered]@{
                    Left = $script:WindowState.Left
                    Top = $script:WindowState.Top
                    Topmost = $script:WindowState.Topmost
                    Visible = $script:WindowState.Visible
                }
            }
            SetCallbacks = {
                param($OnDrag, $OnToggleTopmost, $OnHide, $OnCloseRequested)
                $script:WindowCallbacks = [pscustomobject][ordered]@{
                    OnDrag = $OnDrag
                    OnToggleTopmost = $OnToggleTopmost
                    OnHide = $OnHide
                    OnCloseRequested = $OnCloseRequested
                }
            }
            Dispose = { throw 'The controller must not dispose the window view.' }
        }
        $script:TrayView = [pscustomobject]@{
            SetCallbacks = {
                param(
                    $OnToggleVisibility,
                    $OnToggleTopmost,
                    $OnRefresh,
                    $OnToggleStartup,
                    $OnOpenUsage,
                    $OnOpenLogs,
                    $OnExit
                )
                $script:TrayCallbacks = [pscustomobject][ordered]@{
                    OnToggleVisibility = $OnToggleVisibility
                    OnToggleTopmost = $OnToggleTopmost
                    OnRefresh = $OnRefresh
                    OnToggleStartup = $OnToggleStartup
                    OnOpenUsage = $OnOpenUsage
                    OnOpenLogs = $OnOpenLogs
                    OnExit = $OnExit
                }
            }
            SetTopmostChecked = {
                param([bool]$Checked)
                $script:TrayState.TopmostChecked = $Checked
            }
            SetStartupChecked = {
                param([bool]$Checked)
                $script:TrayState.StartupChecked = $Checked
            }
            Dispose = { $script:TrayState.DisposeCalls++ }
        }

        $script:Controller = New-MonitorInteractionController `
            -Settings $script:Settings `
            -WindowView $script:WindowView `
            -TrayView $script:TrayView `
            -SaveSettings { param($value) $script:SaveCalls++ } `
            -ApplyStartupPreference {
                param([bool]$enabled)
                $script:ApplyStartupCalls.Add($enabled)
                if ($script:StartupFailure) { throw 'Synthetic startup failure.' }
            } `
            -RequestRefresh { $script:RefreshCalls++ } `
            -ExitEvent $script:ExitEvent `
            -OpenTarget { param([string]$target) $script:OpenedTargets.Add($target) } `
            -LogDirectory 'C:\Users\测试\AppData\Local\CodexQuotaMonitor\logs'
    }

    AfterEach {
        if ($null -ne $script:Controller) {
            & $script:Controller.Dispose
        }
        if ($null -ne $script:ExitEvent) {
            $script:ExitEvent.Dispose()
        }
    }

    It 'attaches both views and synchronizes initial check state' {
        $script:WindowCallbacks | Should -Not -BeNullOrEmpty
        $script:TrayCallbacks | Should -Not -BeNullOrEmpty
        $script:TrayState.TopmostChecked | Should -BeTrue
        $script:TrayState.StartupChecked | Should -BeTrue
    }

    It 'toggles visible state by hiding or showing and activating, then persists it' {
        & $script:Controller.ToggleVisibility
        $script:WindowState.HideCalls | Should -Be 1
        $script:WindowState.ActivateCalls | Should -Be 0
        $script:Settings.Window.Visible | Should -BeFalse
        $script:SaveCalls | Should -Be 1

        & $script:Controller.ToggleVisibility
        $script:WindowState.ActivateCalls | Should -Be 1
        $script:Settings.Window.Visible | Should -BeTrue
        $script:SaveCalls | Should -Be 2
    }

    It 'always shows and activates an Activate request' {
        $script:WindowState.Visible = $true
        & $script:Controller.ShowAndActivate

        $script:WindowState.ActivateCalls | Should -Be 1
        $script:Settings.Window.Visible | Should -BeTrue
        $script:SaveCalls | Should -Be 1
    }

    It 'maps window Hide and Close to hiding only, never exit' {
        & $script:WindowCallbacks.OnHide
        & $script:WindowCallbacks.OnCloseRequested

        $script:WindowState.HideCalls | Should -Be 2
        $script:Settings.Window.Visible | Should -BeFalse
        $script:SaveCalls | Should -Be 2
        $script:ExitEvent.WaitOne(0) | Should -BeFalse
    }

    It 'toggles topmost across settings, window, tray, and persistence' {
        & $script:WindowCallbacks.OnToggleTopmost

        $script:Settings.Window.Topmost | Should -BeFalse
        @($script:WindowState.SetTopmostCalls) | Should -Be @($false)
        $script:TrayState.TopmostChecked | Should -BeFalse
        $script:SaveCalls | Should -Be 1
    }

    It 'persists only finite dragged coordinates' {
        & $script:WindowCallbacks.OnDrag ([pscustomobject]@{
            Left = [double]111.5
            Top = [double]222.25
            Topmost = $false
            Visible = $false
        })

        $script:Settings.Window.Left | Should -Be 111.5
        $script:Settings.Window.Top | Should -Be 222.25
        $script:Settings.Window.Topmost | Should -BeTrue
        $script:Settings.Window.Visible | Should -BeTrue
        $script:SaveCalls | Should -Be 1

        & $script:Controller.PersistPlacement ([pscustomobject]@{
            Left = [double]::NaN
            Top = [double]::PositiveInfinity
        })
        $script:Settings.Window.Left | Should -Be 111.5
        $script:Settings.Window.Top | Should -Be 222.25
        $script:SaveCalls | Should -Be 1
    }

    It 'requests one coalescible manual refresh' {
        & $script:TrayCallbacks.OnRefresh
        $script:RefreshCalls | Should -Be 1
    }

    It 'changes startup only after the injected operation succeeds' {
        & $script:TrayCallbacks.OnToggleStartup
        @($script:ApplyStartupCalls) | Should -Be @($false)
        $script:Settings.Startup | Should -BeFalse
        $script:TrayState.StartupChecked | Should -BeFalse
        $script:SaveCalls | Should -Be 1

        & $script:TrayCallbacks.OnToggleStartup
        @($script:ApplyStartupCalls) | Should -Be @($false, $true)
        $script:Settings.Startup | Should -BeTrue
        $script:TrayState.StartupChecked | Should -BeTrue
        $script:SaveCalls | Should -Be 2
    }

    It 'preserves startup state and check state when applying the preference fails' {
        $script:StartupFailure = $true

        { & $script:TrayCallbacks.OnToggleStartup } | Should -Throw 'Synthetic startup failure.'

        $script:Settings.Startup | Should -BeTrue
        $script:TrayState.StartupChecked | Should -BeTrue
        $script:SaveCalls | Should -Be 0
    }

    It 'opens only the injected official usage URL and log directory' {
        & $script:TrayCallbacks.OnOpenUsage
        & $script:TrayCallbacks.OnOpenLogs

        @($script:OpenedTargets) | Should -Be @(
            'https://chatgpt.com/codex/settings/usage',
            'C:\Users\测试\AppData\Local\CodexQuotaMonitor\logs'
        )
    }

    It 'signals Exit without disposing either view' {
        & $script:TrayCallbacks.OnExit

        $script:ExitEvent.WaitOne(0) | Should -BeTrue
        $script:TrayState.DisposeCalls | Should -Be 0
    }

    It 'clears callbacks idempotently without owning view disposal' {
        { & $script:Controller.Dispose; & $script:Controller.Dispose } | Should -Not -Throw

        foreach ($callback in $script:WindowCallbacks.PSObject.Properties.Value) {
            $callback | Should -BeNullOrEmpty
        }
        foreach ($callback in $script:TrayCallbacks.PSObject.Properties.Value) {
            $callback | Should -BeNullOrEmpty
        }
        $script:TrayState.DisposeCalls | Should -Be 0
        $script:Controller = $null
    }
}
