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
            RelayAutoQueryIntervalMinutes = 10
        }
        $script:SetIntervalCalls = [Collections.Generic.List[object]]::new()
        $script:ViewState = [pscustomobject][ordered]@{
            Snapshot = $null
            Status = ''
            Callbacks = $null
            ShowCalls = 0
            DisposeCalls = 0
        }
        $viewState = $script:ViewState
        $script:View = [pscustomobject][ordered]@{
            SetSnapshot = {
                param($Mode, $Theme, $FullLayout, $Topmost, $Startup, $RelayAutoQueryIntervalMinutes)
                $viewState.Snapshot = [pscustomobject][ordered]@{
                    Mode = $Mode
                    Theme = $Theme
                    FullLayout = $FullLayout
                    Topmost = $Topmost
                    Startup = $Startup
                    RelayAutoQueryIntervalMinutes = $RelayAutoQueryIntervalMinutes
                }
                $viewState.Status = ''
            }.GetNewClosure()
            SetStatus = { param($Message) $viewState.Status = $Message }.GetNewClosure()
            SetCallbacks = {
                param(
                    $OnSetDisplayMode, $OnSetTheme, $OnSetFullLayout,
                    $OnToggleTopmost, $OnToggleStartup, $OnSetRelayAutoQueryInterval,
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
            -SetDisplayMode { param($value) } `
            -SetTheme { param($value) } `
            -SetFullLayout { param($value) } `
            -ToggleTopmost { } `
            -ToggleStartup { } `
            -SetRelayAutoQueryInterval {
                param($value)
                $script:SetIntervalCalls.Add($value)
                $script:Snapshot.RelayAutoQueryIntervalMinutes = $value
            } `
            -RequestRefresh { }
    }

    AfterEach {
        if ($null -ne $script:Controller -and -not $script:Controller.State.Disposed) {
            & $script:Controller.Dispose
        }
    }

    It 'renders the relay interval from the settings snapshot' {
        & $Controller.Show

        $ViewState.Snapshot.RelayAutoQueryIntervalMinutes | Should -Be 10
        $ViewState.ShowCalls | Should -Be 1
    }

    It 'passes a valid interval to the runtime as an integer and rerenders' {
        & $ViewState.Callbacks.OnSetRelayAutoQueryInterval '0'

        @($SetIntervalCalls).Count | Should -Be 1
        $SetIntervalCalls[0] | Should -Be 0
        $SetIntervalCalls[0] | Should -BeOfType ([int])
        $ViewState.Snapshot.RelayAutoQueryIntervalMinutes | Should -Be 0
        $ViewState.Status | Should -BeExactly '自动查询间隔已更新。'
    }

    It 'rejects an invalid interval and restores the current snapshot' -ForEach @(
        @{ Value = '' }
        @{ Value = 'abc' }
        @{ Value = '5.5' }
        @{ Value = '-1' }
        @{ Value = '1441' }
    ) {
        & $ViewState.Callbacks.OnSetRelayAutoQueryInterval $Value

        @($SetIntervalCalls).Count | Should -Be 0
        $ViewState.Snapshot.RelayAutoQueryIntervalMinutes | Should -Be 10
        $ViewState.Status | Should -BeExactly '自动查询间隔必须是 0 到 1440 之间的整数。'
    }

    It 'clears the interval callback before disposing the view' {
        & $Controller.Dispose

        $Controller.State.Disposed | Should -BeTrue
        $ViewState.Callbacks.OnSetRelayAutoQueryInterval | Should -BeNullOrEmpty
        $ViewState.DisposeCalls | Should -Be 1
        $script:Controller = $null
    }
}
