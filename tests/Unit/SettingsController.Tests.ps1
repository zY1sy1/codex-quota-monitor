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
        }
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
                [CmdletBinding()]
                param($Mode, $Theme, $FullLayout, $Topmost, $Startup)
                $viewState.Snapshot = [pscustomobject][ordered]@{
                    Mode = $Mode
                    Theme = $Theme
                    FullLayout = $FullLayout
                    Topmost = $Topmost
                    Startup = $Startup
                }
                $viewState.Status = ''
            }.GetNewClosure()
            SetStatus = { param($Message) $viewState.Status = $Message }.GetNewClosure()
            SetCallbacks = {
                [CmdletBinding()]
                param(
                    $OnSetDisplayMode, $OnSetTheme, $OnSetFullLayout,
                    $OnToggleTopmost, $OnToggleStartup,
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
            -RequestRefresh { }
    }

    AfterEach {
        if ($null -ne $script:Controller -and -not $script:Controller.State.Disposed) {
            & $script:Controller.Dispose
        }
    }

    It 'renders only the five settings snapshot fields' {
        & $Controller.Show

        ($ViewState.Snapshot.PSObject.Properties.Name -join ',') |
            Should -BeExactly 'Mode,Theme,FullLayout,Topmost,Startup'
        $ViewState.ShowCalls | Should -Be 1
    }

    It 'binds only the remaining settings callbacks' {
        ($ViewState.Callbacks.PSObject.Properties.Name -join ',') |
            Should -BeExactly 'OnSetDisplayMode,OnSetTheme,OnSetFullLayout,OnToggleTopmost,OnToggleStartup,OnRefresh,OnManageRelays,OnClosing'
    }

    It 'clears callbacks before disposing the view' {
        & $Controller.Dispose

        $Controller.State.Disposed | Should -BeTrue
        $ViewState.Callbacks.OnRefresh | Should -BeNullOrEmpty
        $ViewState.DisposeCalls | Should -Be 1
        $script:Controller = $null
    }
}
