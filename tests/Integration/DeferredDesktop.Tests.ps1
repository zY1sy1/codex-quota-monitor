BeforeAll {
    $script:DeferredManifest = Join-Path $PSScriptRoot '..\..\companion\CodexQuotaMonitor.psd1'
}

Describe 'deferred WPF desktop lifecycle' {
    It 'creates only the selected window and releases previous modes while retaining their placement' {
        $module = Import-Module -Name $script:DeferredManifest -Force -PassThru
        try {
            & $module {
                $settings = New-DefaultSettings
                $settings.Window.Full.Topmost = $false
                $fullFactory = ${function:New-QuotaWindowView}
                $compactFactory = ${function:New-CompactBarView}
                $orbFactory = ${function:New-QuotaOrbView}
                $createInvisible = {
                    param($Factory)
                    $view = & $Factory
                    $view.Window.Opacity = 0
                    $view.Window.ShowInTaskbar = $false
                    return $view
                }
                $full = New-DeferredMonitorView -CreateView ({ & $createInvisible $fullFactory }.GetNewClosure())
                $compact = New-DeferredMonitorView -CreateView ({ & $createInvisible $compactFactory }.GetNewClosure())
                $orb = New-DeferredMonitorView -CreateView ({ & $createInvisible $orbFactory }.GetNewClosure())
                $display = New-MonitorDisplayModeController -Settings $settings -FullView $full `
                    -CompactBarView $compact -OrbView $orb -SaveSettings { } -DeferShow
                try {
                    $full.Window | Should -BeNullOrEmpty
                    $compact.Window | Should -BeNullOrEmpty
                    $orb.Window | Should -BeNullOrEmpty
                    Initialize-MonitorDesktopPresentation -WindowView $full -CompactBarView $compact `
                        -OrbView $orb -DisplayController $display -TrayView ([pscustomobject]@{ SetVisible = { param($Visible) } }) `
                        -Settings $settings -GetWorkAreas { [pscustomobject]@{ Left = 0; Top = 0; Width = 1920; Height = 1080 } } `
                        -SetPlacement ${function:Set-ResolvedWindowPlacement}
                    $full.Window | Should -BeOfType ([Windows.Window])
                    $compact.Window | Should -BeNullOrEmpty
                    $orb.Window | Should -BeNullOrEmpty
                    $full.Window.Left = 123
                    $full.Window.Top = 234
                    & $display.SetSnapshot @()
                    & $display.SetMode CompactBar
                    $full.Window | Should -BeNullOrEmpty
                    $compact.Window | Should -BeOfType ([Windows.Window])
                    $orb.Window | Should -BeNullOrEmpty
                    & $display.SetTheme Light
                    & $display.SetMode Orb
                    $compact.Window | Should -BeNullOrEmpty
                    $orb.Window | Should -BeOfType ([Windows.Window])
                    & $display.OpenFull
                    $orb.Window | Should -BeNullOrEmpty
                    $full.Window.Left | Should -Be 123
                    $full.Window.Top | Should -Be 234
                    $full.DeferredState.Instance.State.Theme | Should -BeExactly Light
                }
                finally { & $display.Dispose }
                $full.Window | Should -BeNullOrEmpty
                $compact.Window | Should -BeNullOrEmpty
                $orb.Window | Should -BeNullOrEmpty
            }
        }
        finally { Remove-Module -ModuleInfo $module -Force }
    }
}
