BeforeAll {
    $controllerPath = Join-Path $PSScriptRoot '..\..\companion\Private\SettingsController.ps1'
    if (Test-Path -LiteralPath $controllerPath -PathType Leaf) {
        . $controllerPath
    }
}

Describe 'settings controller' {
    BeforeEach {
        $script:Snapshot = [pscustomobject][ordered]@{
            Mode = 'Full'
            Theme = 'Dark'
            FullLayout = 'Overview'
            Topmost = $true
            Startup = $true
            ShowTodaySpend = $true
        }
        $script:RefreshCalls = 0
        $script:ViewState = [pscustomobject][ordered]@{
            Snapshot = $null
            Status = ''
            StatusKind = 'Idle'
            Callbacks = $null
            RenderCalls = 0
            ShowCalls = 0
            DisposeCalls = 0
        }
        $viewState = $script:ViewState
        $script:View = [pscustomobject][ordered]@{
            SetSnapshot = {
                param($Mode, $Theme, $FullLayout, $Topmost, $Startup, $ShowTodaySpend)
                $viewState.RenderCalls++
                $viewState.Snapshot = [pscustomobject][ordered]@{
                    Mode = $Mode
                    Theme = $Theme
                    FullLayout = $FullLayout
                    Topmost = $Topmost
                    Startup = $Startup
                    ShowTodaySpend = $ShowTodaySpend
                }
                $viewState.Status = '更改即时保存'
                $viewState.StatusKind = 'Idle'
            }.GetNewClosure()
            SetStatus = {
                param($Message, $Kind)
                $viewState.Status = $Message
                $viewState.StatusKind = $Kind
            }.GetNewClosure()
            SetCallbacks = {
                param(
                    $OnSetDisplayMode, $OnSetTheme, $OnSetFullLayout,
                    $OnToggleTopmost, $OnToggleStartup, $OnToggleTodaySpend,
                    $OnRefresh, $OnManageRelays, $OnClosing
                )
                $viewState.Callbacks = [pscustomobject][ordered]@{}
                foreach ($entry in $PSBoundParameters.GetEnumerator()) {
                    $viewState.Callbacks | Add-Member `
                        -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
                }
            }.GetNewClosure()
            ShowDialog = { $viewState.ShowCalls++ }.GetNewClosure()
            Dispose = { $viewState.DisposeCalls++ }.GetNewClosure()
        }

        $script:Controller = New-SettingsController `
            -View $script:View `
            -GetSnapshot { $script:Snapshot } `
            -SetDisplayMode { param($value) $script:Snapshot.Mode = $value } `
            -SetTheme { param($value) $script:Snapshot.Theme = $value } `
            -SetFullLayout { param($value) $script:Snapshot.FullLayout = $value } `
            -ToggleTopmost { $script:Snapshot.Topmost = -not $script:Snapshot.Topmost } `
            -ToggleStartup { $script:Snapshot.Startup = -not $script:Snapshot.Startup } `
            -ToggleTodaySpend { $script:Snapshot.ShowTodaySpend = -not $script:Snapshot.ShowTodaySpend } `
            -RequestRefresh { $script:RefreshCalls++ }
    }

    AfterEach {
        if ($null -ne $script:Controller -and -not $script:Controller.State.Disposed) {
            & $script:Controller.Dispose
        }
    }

    It 'renders only the active settings contract when shown' {
        & $Controller.Show

        ($ViewState.Snapshot.PSObject.Properties.Name -join ',') |
            Should -BeExactly 'Mode,Theme,FullLayout,Topmost,Startup,ShowTodaySpend'
        ($ViewState.Callbacks.PSObject.Properties.Name -join ',') |
            Should -BeExactly 'OnSetDisplayMode,OnSetTheme,OnSetFullLayout,OnToggleTopmost,OnToggleStartup,OnToggleTodaySpend,OnRefresh,OnManageRelays,OnClosing'
        $ViewState.RenderCalls | Should -Be 1
        $ViewState.ShowCalls | Should -Be 1
        $ViewState.StatusKind | Should -BeExactly 'Idle'
    }

    It 'rerenders the authoritative snapshot after every successful setting change' {
        & $ViewState.Callbacks.OnSetDisplayMode 'CompactBar'
        & $ViewState.Callbacks.OnSetTheme 'Light'
        & $ViewState.Callbacks.OnSetFullLayout 'Tabs'
        & $ViewState.Callbacks.OnToggleTopmost
        & $ViewState.Callbacks.OnToggleStartup

        $ViewState.RenderCalls | Should -Be 5
        $ViewState.Snapshot.Mode | Should -BeExactly 'CompactBar'
        $ViewState.Snapshot.Theme | Should -BeExactly 'Light'
        $ViewState.Snapshot.FullLayout | Should -BeExactly 'Tabs'
        $ViewState.Snapshot.Topmost | Should -BeFalse
        $ViewState.Snapshot.Startup | Should -BeFalse
        $ViewState.Status | Should -BeExactly '设置已同步'
        $ViewState.StatusKind | Should -BeExactly 'Success'
    }

    It 'toggles the today-spend preference and rerenders' {
        & $ViewState.Callbacks.OnToggleTodaySpend

        $ViewState.Snapshot.ShowTodaySpend | Should -BeFalse
        $ViewState.Status | Should -BeExactly '设置已同步'
        $ViewState.StatusKind | Should -BeExactly 'Success'
    }

    It 'restores the snapshot and reports an error when toggling today-spend fails' {
        & $script:Controller.Dispose
        $script:Controller = New-SettingsController `
            -View $script:View `
            -GetSnapshot { $script:Snapshot } `
            -SetDisplayMode { param($value) } `
            -SetTheme { param($value) } `
            -SetFullLayout { param($value) } `
            -ToggleTopmost { } `
            -ToggleStartup { } `
            -ToggleTodaySpend { throw 'today spend failed' } `
            -RequestRefresh { }

        & $ViewState.Callbacks.OnToggleTodaySpend

        $ViewState.RenderCalls | Should -Be 1
        $ViewState.Snapshot.ShowTodaySpend | Should -Be $true
        $ViewState.Status | Should -BeExactly '无法切换今日消耗显示：today spend failed'
        $ViewState.StatusKind | Should -BeExactly 'Error'
    }

    It 'restores the snapshot and reports an error when a setting action fails' {
        & $script:Controller.Dispose
        $script:Controller = New-SettingsController `
            -View $script:View `
            -GetSnapshot { $script:Snapshot } `
            -SetDisplayMode { param($value) } `
            -SetTheme { param($value) throw 'theme failed' } `
            -SetFullLayout { param($value) } `
            -ToggleTopmost { } `
            -ToggleStartup { } `
            -ToggleTodaySpend { } `
            -RequestRefresh { }

        & $ViewState.Callbacks.OnSetTheme 'Light'

        $ViewState.RenderCalls | Should -Be 1
        $ViewState.Snapshot.Theme | Should -BeExactly 'Dark'
        $ViewState.Status | Should -BeExactly '无法应用主题：theme failed'
        $ViewState.StatusKind | Should -BeExactly 'Error'
    }

    It 'reports refresh as requested without claiming completion' {
        & $ViewState.Callbacks.OnRefresh

        $script:RefreshCalls | Should -Be 1
        $ViewState.Status | Should -BeExactly '已请求刷新。'
        $ViewState.StatusKind | Should -BeExactly 'Success'
    }

    It 'clears every active callback before disposing the view' {
        & $Controller.Dispose

        $Controller.State.Disposed | Should -BeTrue
        foreach ($callback in $ViewState.Callbacks.PSObject.Properties) {
            $callback.Value | Should -BeNullOrEmpty
        }
        $ViewState.DisposeCalls | Should -Be 1
        $script:Controller = $null
    }
}
