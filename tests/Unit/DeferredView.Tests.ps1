BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\companion\Private\DeferredView.ps1')
    function New-TestDeferredFixture {
        $box = [pscustomobject]@{ Creations = 0; Disposals = 0; Theme = $null; Callbacks = $null; Placement = $null }
        $proxy = New-DeferredMonitorView -CreateView ({
            $box = $box
            $box.Creations++
            [pscustomobject]@{
                Window = [pscustomobject]@{ Left = 0; Top = 0 }
                Show = { }
                Hide = { }
                Activate = { }
                SetTheme = { param($Theme) $box.Theme = $Theme }.GetNewClosure()
                SetCallbacks = {
                    param($OnOpenFull, $OnDrag, $OnCloseRequested)
                    $box.Callbacks = @($OnOpenFull, $OnDrag, $OnCloseRequested)
                }.GetNewClosure()
                Dispose = { $box.Disposals++ }.GetNewClosure()
            }
        }.GetNewClosure())
        [pscustomobject]@{ View = $proxy; Box = $box }
    }
}

Describe 'deferred desktop views' {
    It 'does not allocate a window for theme callbacks placement or hide' {
        $fixture = New-TestDeferredFixture
        & $fixture.View.SetTheme Light
        & $fixture.View.SetCallbacks -OnDrag { 'drag' }
        & $fixture.View.ConfigurePlacement -Action { throw 'Placement must be deferred.' } -Arguments @{}
        & $fixture.View.Hide
        $fixture.View.Window | Should -BeNullOrEmpty
        $fixture.Box.Creations | Should -Be 0
        & $fixture.View.Dispose
        $fixture.Box.Disposals | Should -Be 0
    }

    It 'applies the latest preferences and named callbacks when first shown' {
        $fixture = New-TestDeferredFixture
        & $fixture.View.SetTheme Dark
        & $fixture.View.SetTheme Light
        $drag = { 'drag' }
        $open = { 'open' }
        & $fixture.View.SetCallbacks -OnDrag $drag -OnOpenFull $open
        $placement = { param($Window, $Left, $Top) $Window.Left = $Left; $Window.Top = $Top }
        & $fixture.View.ConfigurePlacement -Action $placement -Arguments @{ Left = 123; Top = 456 }
        & $fixture.View.Show
        & $fixture.View.Activate
        $fixture.Box.Creations | Should -Be 1
        $fixture.Box.Theme | Should -BeExactly Light
        $fixture.Box.Callbacks[0] | Should -Be $open
        $fixture.Box.Callbacks[1] | Should -Be $drag
        $fixture.View.Window.Left | Should -Be 123
        $fixture.View.Window.Top | Should -Be 456
        & $fixture.View.Dispose
    }

    It 'releases the outgoing tree and recreates it with the updated theme' {
        $fixture = New-TestDeferredFixture
        & $fixture.View.Show
        & $fixture.View.Release
        $fixture.View.Window | Should -BeNullOrEmpty
        $fixture.Box.Disposals | Should -Be 1
        & $fixture.View.SetTheme Dark
        & $fixture.View.Show
        $fixture.Box.Creations | Should -Be 2
        $fixture.Box.Theme | Should -BeExactly Dark
        & $fixture.View.Dispose
        & $fixture.View.Dispose
        $fixture.Box.Disposals | Should -Be 2
        { & $fixture.View.Show } | Should -Throw '*disposed*'
    }
}
