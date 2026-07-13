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
}

Describe 'Resolve-WindowPlacement' {
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

    It 'selects the intersecting work area with the largest overlap' {
        $areas = @(
            New-TestWorkArea -Left 0 -Top 0 -Width 1000 -Height 700
            New-TestWorkArea -Left 900 -Top 100 -Width 1000 -Height 700
        )

        $result = Resolve-WindowPlacement -Left 850 -Top 50 -WindowWidth 1000 -WindowHeight 300 -WorkAreas $areas

        $result.Left | Should -Be 850
        $result.Top | Should -Be 100
    }
}
