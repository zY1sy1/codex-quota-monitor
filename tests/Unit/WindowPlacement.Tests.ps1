BeforeAll {
    $placementScript = "$PSScriptRoot\..\..\companion\Private\WindowPlacement.ps1"
    if (Test-Path -LiteralPath $placementScript -PathType Leaf) {
        . $placementScript
    }

    function New-TestWorkArea {
        param(
            [object]$Left,
            [object]$Top,
            [object]$Width,
            [object]$Height
        )

        [pscustomobject]@{
            Left = $Left
            Top = $Top
            Width = $Width
            Height = $Height
        }
    }

    function New-TestScreen {
        param(
            [bool]$Primary,
            [string]$DeviceName,
            [object]$Bounds,
            [object]$WorkingArea
        )

        [pscustomobject]@{
            Primary = $Primary
            DeviceName = $DeviceName
            Bounds = $Bounds
            WorkingArea = $WorkingArea
        }
    }
}

Describe 'Resolve-WindowPlacement' {
    It 'selects saved placement and dimensions for every display mode' -ForEach @(
        @{ Mode = 'Full'; Left = 10; Top = 20; Width = 420; Height = 560 }
        @{ Mode = 'CompactBar'; Left = 30; Top = 40; Width = 280; Height = 64 }
        @{ Mode = 'Orb'; Left = 50; Top = 60; Width = 112; Height = 112 }
    ) {
        $settings = [ordered]@{
            Window = [ordered]@{
                Full = [ordered]@{ Left = 10; Top = 20; Width = 420; Height = 560 }
                CompactBar = [ordered]@{ Left = 30; Top = 40 }
                Orb = [ordered]@{ Left = 50; Top = 60 }
            }
        }
        $areas = @(New-TestWorkArea -Left 0 -Top 0 -Width 1920 -Height 1040)

        $result = Resolve-MonitorModePlacement -Settings $settings -Mode $Mode -WorkAreas $areas

        $result.Left | Should -Be $Left
        $result.Top | Should -Be $Top
        $result.Width | Should -Be $Width
        $result.Height | Should -Be $Height
    }

    It 'leaves an already visible saved placement unchanged' {
        $areas = @(New-TestWorkArea -Left 0 -Top 0 -Width 1920 -Height 1040)

        $result = Resolve-WindowPlacement -Left 100 -Top 80 -WindowWidth 420 -WindowHeight 300 -WorkAreas $areas

        $result.Left | Should -Be 100
        $result.Top | Should -Be 80
    }

    It 'clamps only enough to keep 48 horizontal pixels and the title strip reachable' {
        $areas = @(New-TestWorkArea -Left 0 -Top 0 -Width 1920 -Height 1040)

        $result = Resolve-WindowPlacement -Left 1900 -Top -25 -WindowWidth 300 -WindowHeight 200 -WorkAreas $areas

        $result.Left | Should -Be 1872
        $result.Top | Should -Be 0
    }

    It 'clamps a low title strip without otherwise moving the window' {
        $areas = @(New-TestWorkArea -Left 0 -Top 0 -Width 1920 -Height 1040)

        $result = Resolve-WindowPlacement -Left 400 -Top 1025 -WindowWidth 300 -WindowHeight 200 -WorkAreas $areas

        $result.Left | Should -Be 400
        $result.Top | Should -Be 992
    }

    It 'recovers a placement that is completely off every monitor inside the primary area' {
        $areas = @(
            New-TestWorkArea -Left 0 -Top 0 -Width 1920 -Height 1040
            New-TestWorkArea -Left 1920 -Top 0 -Width 1280 -Height 1024
        )

        $result = Resolve-WindowPlacement -Left 5000 -Top 3000 -WindowWidth 400 -WindowHeight 300 -WorkAreas $areas

        $result.Left | Should -Be 24
        $result.Top | Should -Be 24
    }

    It 'supports a visible window on a secondary monitor with negative coordinates' {
        $areas = @(
            New-TestWorkArea -Left 0 -Top 0 -Width 1920 -Height 1040
            New-TestWorkArea -Left -1280 -Top -200 -Width 1280 -Height 1024
        )

        $result = Resolve-WindowPlacement -Left -1200 -Top -150 -WindowWidth 400 -WindowHeight 300 -WorkAreas $areas

        $result.Left | Should -Be -1200
        $result.Top | Should -Be -150
    }

    It 'clamps an oversized window only enough to expose 48 pixels and its title strip' {
        $areas = @(New-TestWorkArea -Left 0 -Top 0 -Width 800 -Height 600)

        $result = Resolve-WindowPlacement -Left -1190 -Top -20 -WindowWidth 1200 -WindowHeight 900 -WorkAreas $areas

        $result.Left | Should -Be -1152
        $result.Top | Should -Be 0
    }

    It 'uses the primary inset for null or non-finite saved coordinates' -ForEach @(
        @{ Left = $null; Top = 100 }
        @{ Left = 100; Top = $null }
        @{ Left = [double]::NaN; Top = 100 }
        @{ Left = 100; Top = [double]::PositiveInfinity }
    ) {
        $areas = @(New-TestWorkArea -Left 100 -Top 50 -Width 1200 -Height 800)

        $result = Resolve-WindowPlacement -Left $Left -Top $Top -WindowWidth 400 -WindowHeight 300 -WorkAreas $areas

        $result.Left | Should -Be 124
        $result.Top | Should -Be 74
    }

    It 'ignores invalid work areas and uses the first usable one as primary' {
        $areas = @(
            $null
            New-TestWorkArea -Left 0 -Top 0 -Width 0 -Height 1080
            New-TestWorkArea -Left 0 -Top 0 -Width ([double]::NaN) -Height 1080
            New-TestWorkArea -Left -100 -Top 50 -Width 800 -Height 600
        )

        $result = Resolve-WindowPlacement -Left $null -Top $null -WindowWidth 400 -WindowHeight 300 -WorkAreas $areas

        $result.Left | Should -Be -76
        $result.Top | Should -Be 74
    }

    It 'returns a deterministic safe origin when no usable work area exists' {
        $areas = @(
            New-TestWorkArea -Left 0 -Top 0 -Width -1 -Height 1080
            New-TestWorkArea -Left 'invalid' -Top 0 -Width 1920 -Height 1080
        )

        $result = Resolve-WindowPlacement -Left 10 -Top 20 -WindowWidth 400 -WindowHeight 300 -WorkAreas $areas

        $result.Left | Should -Be 24
        $result.Top | Should -Be 24
    }

    It 'falls back to another mode placement when the saved position is off every work area' {
        $areas = @(New-TestWorkArea -Left 0 -Top 0 -Width 1920 -Height 1040)
        $fallbacks = @(
            [pscustomobject]@{ Left = 150; Top = 100 }
            [pscustomobject]@{ Left = 300; Top = 200 }
        )

        $result = Resolve-WindowPlacement `
            -Left 2000 -Top 50 -WindowWidth 420 -WindowHeight 300 -WorkAreas $areas `
            -FallbackPositions $fallbacks

        $result.Left | Should -Be 150
        $result.Top | Should -Be 100
    }

    It 'keeps the saved placement when a fallback position is also present' {
        $areas = @(New-TestWorkArea -Left 0 -Top 0 -Width 1920 -Height 1040)
        $fallbacks = @([pscustomobject]@{ Left = 150; Top = 100 })

        $result = Resolve-WindowPlacement `
            -Left 100 -Top 80 -WindowWidth 420 -WindowHeight 300 -WorkAreas $areas `
            -FallbackPositions $fallbacks

        $result.Left | Should -Be 100
        $result.Top | Should -Be 80
    }

    It 'uses a fallback position when the saved coordinates are null' {
        $areas = @(New-TestWorkArea -Left 0 -Top 0 -Width 1920 -Height 1040)
        $fallbacks = @(
            [pscustomobject]@{ Left = $null; Top = $null }
            [pscustomobject]@{ Left = 640; Top = 480 }
        )

        $result = Resolve-WindowPlacement `
            -Left $null -Top $null -WindowWidth 420 -WindowHeight 300 -WorkAreas $areas `
            -FallbackPositions $fallbacks

        $result.Left | Should -Be 640
        $result.Top | Should -Be 480
    }

    It 'returns the safe origin when every candidate is off every work area' {
        $areas = @(New-TestWorkArea -Left 0 -Top 0 -Width 1920 -Height 1040)
        $fallbacks = @(
            [pscustomobject]@{ Left = 2100; Top = 2000 }
            [pscustomobject]@{ Left = 2500; Top = 50 }
        )

        $result = Resolve-WindowPlacement `
            -Left 2000 -Top 50 -WindowWidth 420 -WindowHeight 300 -WorkAreas $areas `
            -FallbackPositions $fallbacks

        $result.Left | Should -Be 24
        $result.Top | Should -Be 24
    }

    It 'selects the intersecting work area with the largest overlap' {
        $areas = @(
            New-TestWorkArea -Left 0 -Top 0 -Width 1000 -Height 700
            New-TestWorkArea -Left 900 -Top 100 -Width 1000 -Height 700
        )

        $result = Resolve-WindowPlacement -Left 850 -Top 50 -WindowWidth 1000 -WindowHeight 300 -WorkAreas $areas

        $result.Left | Should -Be 850
        $result.Top | Should -Be 100
    }

    It 'applies recovered coordinates to a size-to-content window before it is shown' {
        $window = [pscustomobject]@{
            ActualWidth = 0.0
            Width = 300.0
            MinWidth = 0.0
            ActualHeight = 0.0
            Height = [double]::NaN
            MinHeight = 150.0
            Left = 5000.0
            Top = 3000.0
        }
        $areas = @(New-TestWorkArea -Left 100 -Top 50 -Width 1200 -Height 800)

        $result = Set-ResolvedWindowPlacement `
            -Window $window `
            -Left 5000 `
            -Top 3000 `
            -WorkAreas $areas

        $result.Left | Should -Be 124
        $result.Top | Should -Be 74
        $window.Left | Should -Be 124
        $window.Top | Should -Be 74
    }

    It 'converts device-pixel work areas into one WPF logical desktop coordinate space' {
        $screens = @(
            New-TestScreen `
                -Primary $true `
                -DeviceName '\\.\DISPLAY1' `
                -Bounds (New-TestWorkArea -Left 0 -Top 0 -Width 3840 -Height 2160) `
                -WorkingArea (New-TestWorkArea -Left 0 -Top 0 -Width 3840 -Height 2070)
            New-TestScreen `
                -Primary $false `
                -DeviceName '\\.\DISPLAY2' `
                -Bounds (New-TestWorkArea -Left -1920 -Top 0 -Width 1920 -Height 1080) `
                -WorkingArea (New-TestWorkArea -Left -1920 -Top 0 -Width 1920 -Height 1080)
        )
        $logicalPrimary = New-TestWorkArea -Left 0 -Top 0 -Width 2560 -Height 1380

        $result = @(Get-MonitorWorkAreas `
            -Screens $screens `
            -PrimaryLogicalWorkArea $logicalPrimary `
            -PrimaryLogicalScreenWidth 2560 `
            -PrimaryLogicalScreenHeight 1440)

        $result.Count | Should -Be 2
        $result[0].Left | Should -Be 0
        $result[0].Top | Should -Be 0
        $result[0].Width | Should -Be 2560
        $result[0].Height | Should -Be 1380
        $result[1].Left | Should -Be -1280
        $result[1].Top | Should -Be 0
        $result[1].Width | Should -Be 1280
        $result[1].Height | Should -Be 720
    }

    It 'resolves placement before the first visible desktop presentation' {
        $calls = [Collections.Generic.List[string]]::new()
        $window = [pscustomobject]@{
            ActualWidth = 0.0
            Width = 300.0
            MinWidth = 0.0
            ActualHeight = 0.0
            Height = [double]::NaN
            MinHeight = 150.0
            Left = 5000.0
            Top = 3000.0
        }
        $windowView = [pscustomobject]@{
            Window = $window
            SetTopmost = { param([bool]$Value) $calls.Add("topmost:$Value") }.GetNewClosure()
            Show = { $calls.Add('show') }.GetNewClosure()
            Hide = { $calls.Add('hide') }.GetNewClosure()
        }
        $trayView = [pscustomobject]@{
            SetVisible = { param([bool]$Value) $calls.Add("tray-visible:$Value") }.GetNewClosure()
        }
        $settings = [ordered]@{
            Window = [ordered]@{
                Full = [ordered]@{
                    Left = 5000.0
                    Top = 3000.0
                    Topmost = $true
                    Visible = $true
                }
            }
        }
        $testWorkAreas = @(
            New-TestWorkArea -Left 100 -Top 50 -Width 1200 -Height 800
        )
        $getWorkAreas = {
            $calls.Add('work-areas')
            return $testWorkAreas
        }.GetNewClosure()
        $setPlacement = {
            param($Window, $Left, $Top, $WorkAreas)
            $calls.Add('placement')
            $Window.Left = 124.0
            $Window.Top = 74.0
        }.GetNewClosure()

        Initialize-MonitorDesktopPresentation `
            -WindowView $windowView `
            -TrayView $trayView `
            -Settings $settings `
            -GetWorkAreas $getWorkAreas `
            -SetPlacement $setPlacement

        @($calls) | Should -Be @(
            'topmost:True'
            'work-areas'
            'placement'
            'tray-visible:True'
            'show'
        )
        $window.Left | Should -Be 124
        $window.Top | Should -Be 74
    }
}
