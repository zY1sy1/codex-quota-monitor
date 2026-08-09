BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\companion\Private\ObjectAccess.ps1')
    . (Join-Path $PSScriptRoot '..\..\companion\Private\Presentation.ps1')
    . (Join-Path $PSScriptRoot '..\..\companion\Private\RelayPresentation.ps1')
    $script:ControllerPath = Join-Path $PSScriptRoot '..\..\companion\Private\DisplayModeController.ps1'
    if (Test-Path -LiteralPath $script:ControllerPath -PathType Leaf) {
        . $script:ControllerPath
    }

    function New-TestDisplayRow {
        param(
            [string]$Key,
            [ValidateSet('Official', 'Relay')][string]$SourceKind,
            [double]$ProgressValue
        )

        [pscustomobject][ordered]@{
            Key = $Key
            SourceKind = $SourceKind
            SourceId = $SourceKind.ToLowerInvariant()
            GroupLabel = if ($SourceKind -eq 'Official') { 'Codex 官方额度' } else { '中转站额度' }
            Label = $Key
            ValueText = "$ProgressValue%"
            SecondaryText = ''
            ProgressValue = $ProgressValue
            Countdown = ''
            ResetTime = ''
            IsStale = $false
            UpdatedAt = [DateTimeOffset]::UtcNow
            State = 'Live'
        }
    }
}

Describe 'display mode controller' {
    BeforeEach {
        $script:Settings = [ordered]@{
            SchemaVersion = 2
            Appearance = [ordered]@{
                Theme = 'Dark'
                DisplayMode = 'Full'
                FullLayout = 'Overview'
                RememberLastMode = $true
            }
            Window = [ordered]@{
                Full = [ordered]@{ Left = $null; Top = $null; Width = 420.0; Height = 560.0; Topmost = $true; Visible = $true }
                CompactBar = [ordered]@{ Left = $null; Top = $null }
                Orb = [ordered]@{ Left = $null; Top = $null }
            }
            Compact = [ordered]@{ FocusMetric = 'Auto' }
            Startup = $true
        }
        $script:SaveCalls = 0
        $script:FailSave = $false
        $script:Views = [ordered]@{}

        foreach ($mode in @('Full', 'CompactBar', 'Orb')) {
            $viewState = [ordered]@{
                Mode = $mode
                ShowCalls = 0
                HideCalls = 0
                ActivateCalls = 0
                DisposeCalls = 0
                Theme = $null
                Layout = $null
                Topmost = $null
                FocusRow = $null
                PinnedKey = $null
                OfficialRows = @()
                RelayRows = @()
                Callbacks = $null
            }
            $view = [pscustomobject][ordered]@{
                State = $viewState
                Show = { $viewState.ShowCalls++ }.GetNewClosure()
                Hide = { $viewState.HideCalls++ }.GetNewClosure()
                Activate = { $viewState.ActivateCalls++ }.GetNewClosure()
                SetTheme = { param($Theme) $viewState.Theme = $Theme }.GetNewClosure()
                SetLayout = { param($Layout) $viewState.Layout = $Layout }.GetNewClosure()
                SetTopmost = { param($Topmost) $viewState.Topmost = $Topmost }.GetNewClosure()
                RenderGroups = {
                    param($OfficialRows, $RelayRows, $State, $FocusKey)
                    $viewState.OfficialRows = @($OfficialRows)
                    $viewState.RelayRows = @($RelayRows)
                }.GetNewClosure()
                RenderFocus = {
                    param($Row, $PinnedKey)
                    $viewState.FocusRow = $Row
                    $viewState.PinnedKey = $PinnedKey
                }.GetNewClosure()
                SetCallbacks = {
                    param(
                        $OnDrag, $OnToggleTopmost, $OnHide, $OnCloseRequested,
                        $OnThemeRequested, $OnModeRequested, $OnLayoutRequested,
                        $OnFocusRequested, $OnOpenFull
                    )
                    $viewState.Callbacks = [pscustomobject][ordered]@{}
                    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
                        $viewState.Callbacks | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
                    }
                }.GetNewClosure()
                GetPlacement = { [pscustomobject]@{ Left = 11.0; Top = 22.0; Visible = $true } }
                Dispose = { $viewState.DisposeCalls++ }.GetNewClosure()
            }
            $script:Views[$mode] = $view
        }

        $script:Controller = New-MonitorDisplayModeController `
            -Settings $script:Settings `
            -FullView $script:Views.Full `
            -CompactBarView $script:Views.CompactBar `
            -OrbView $script:Views.Orb `
            -SaveSettings {
                param($Settings)
                $script:SaveCalls++
                if ($script:FailSave) { throw 'Synthetic settings failure.' }
            }
    }

    AfterEach {
        if ($null -ne $script:Controller -and -not $script:Controller.State.Disposed) {
            & $script:Controller.Dispose
        }
    }

    It 'renders one snapshot into all views and switches modes without refreshing data' {
        $rows = @(
            New-TestDisplayRow -Key 'official:weekly' -SourceKind Official -ProgressValue 74
            New-TestDisplayRow -Key 'relay:one' -SourceKind Relay -ProgressValue 31
        )

        & $Controller.SetSnapshot $rows
        & $Controller.SetMode CompactBar

        @($Views.Full.State.OfficialRows).Count | Should -Be 1
        @($Views.Full.State.RelayRows).Count | Should -Be 1
        $Views.CompactBar.State.FocusRow.Key | Should -BeExactly 'relay:one'
        $Views.Orb.State.FocusRow.Key | Should -BeExactly 'relay:one'
        $Views.Full.State.HideCalls | Should -BeGreaterThan 0
        $Views.CompactBar.State.ShowCalls | Should -BeGreaterThan 0
        $Controller.State.Mode | Should -BeExactly 'CompactBar'
        $Settings.Appearance.DisplayMode | Should -BeExactly 'CompactBar'
    }

    It 'applies theme layout focus topmost and hidden state to the appropriate views' {
        $rows = @(
            New-TestDisplayRow -Key 'official:weekly' -SourceKind Official -ProgressValue 74
            New-TestDisplayRow -Key 'relay:one' -SourceKind Relay -ProgressValue 31
        )
        & $Controller.SetSnapshot $rows

        & $Controller.SetTheme Light
        & $Controller.SetFullLayout Tabs
        & $Controller.SetFocusKey 'official:weekly'
        & $Controller.SetTopmost $false
        & $Controller.HideAll

        foreach ($view in $Views.Values) {
            $view.State.Theme | Should -BeExactly 'Light'
            $view.State.Topmost | Should -BeFalse
            $view.State.HideCalls | Should -BeGreaterThan 0
        }
        $Views.Full.State.Layout | Should -BeExactly 'Tabs'
        $Views.CompactBar.State.FocusRow.Key | Should -BeExactly 'official:weekly'
        $Views.Orb.State.PinnedKey | Should -BeExactly 'official:weekly'
        $Controller.State.Visible | Should -BeFalse
        $Settings.Window.Full.Visible | Should -BeFalse
    }

    It 'opens full from a compact view without requesting a new snapshot' {
        & $Controller.SetMode Orb
        & $Controller.OpenFull

        $Controller.State.Mode | Should -BeExactly 'Full'
        $Controller.State.Visible | Should -BeTrue
        $Views.Full.State.ShowCalls | Should -BeGreaterThan 0
        $Views.Full.State.ActivateCalls | Should -Be 1
        $Views.Orb.State.HideCalls | Should -BeGreaterThan 0
    }

    It 'persists finite placement under the matching mode only' {
        & $Controller.PersistPlacement -Mode Orb -Placement ([pscustomobject]@{ Left = 123.5; Top = 456.25 })

        $Settings.Window.Orb.Left | Should -Be 123.5
        $Settings.Window.Orb.Top | Should -Be 456.25
        $Settings.Window.CompactBar.Left | Should -BeNullOrEmpty
    }

    It 'notifies one observer when a window callback changes display state' {
        $changes = [Collections.Generic.List[string]]::new()
        & $Controller.SetStateChangedCallback {
            param($value)
            $changes.Add("$($value.Mode)|$($value.Theme)|$($value.FullLayout)")
        }

        & $Views.Full.State.Callbacks.OnModeRequested
        & $Views.Full.State.Callbacks.OnThemeRequested
        & $Views.Full.State.Callbacks.OnLayoutRequested

        @($changes) | Should -Be @(
            'CompactBar|Dark|Overview',
            'CompactBar|Light|Overview',
            'CompactBar|Light|Tabs'
        )
    }

    It 'does not persist display mode when remember-last-mode is disabled' {
        $Settings.Appearance.RememberLastMode = $false

        & $Controller.SetMode Orb

        $Controller.State.Mode | Should -BeExactly 'Orb'
        $Settings.Appearance.DisplayMode | Should -BeExactly 'Full'
    }

    It 'rolls mode and theme back when settings persistence fails' {
        $script:FailSave = $true

        { & $Controller.SetMode CompactBar } | Should -Throw 'Synthetic settings failure.'
        $Controller.State.Mode | Should -BeExactly 'Full'
        $Settings.Appearance.DisplayMode | Should -BeExactly 'Full'

        { & $Controller.SetTheme Light } | Should -Throw 'Synthetic settings failure.'
        $Controller.State.Theme | Should -BeExactly 'Dark'
        $Settings.Appearance.Theme | Should -BeExactly 'Dark'
        foreach ($view in $Views.Values) { $view.State.Theme | Should -BeExactly 'Dark' }
    }

    It 'clears callbacks before disposing all views idempotently' {
        { & $Controller.Dispose; & $Controller.Dispose } | Should -Not -Throw

        foreach ($view in $Views.Values) {
            $view.State.DisposeCalls | Should -Be 1
            foreach ($callback in $view.State.Callbacks.PSObject.Properties.Value) {
                $callback | Should -BeNullOrEmpty
            }
        }
        $Controller.State.Disposed | Should -BeTrue
        $script:Controller = $null
    }
}
