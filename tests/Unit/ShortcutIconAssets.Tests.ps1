BeforeAll {
    $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

    function Read-TestIcoDirectory {
        param([Parameter(Mandatory)][string]$Path)

        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 6) {
            throw 'ICO header is truncated.'
        }

        $reserved = [BitConverter]::ToUInt16($bytes, 0)
        $type = [BitConverter]::ToUInt16($bytes, 2)
        $count = [BitConverter]::ToUInt16($bytes, 4)
        $directoryEnd = 6 + 16 * $count
        if ($reserved -ne 0 -or $type -ne 1 -or $bytes.Length -lt $directoryEnd) {
            throw 'ICO directory is invalid.'
        }

        $entries = for ($index = 0; $index -lt $count; $index++) {
            $offset = 6 + (16 * $index)
            $width = if ($bytes[$offset] -eq 0) { 256 } else { [int]$bytes[$offset] }
            $height = if ($bytes[$offset + 1] -eq 0) { 256 } else { [int]$bytes[$offset + 1] }
            $length = [BitConverter]::ToUInt32($bytes, $offset + 8)
            $imageOffset = [BitConverter]::ToUInt32($bytes, $offset + 12)
            if ($width -ne $height -or $length -eq 0 -or
                [uint64]$imageOffset -lt [uint64]$directoryEnd -or
                ([uint64]$imageOffset + [uint64]$length) -gt [uint64]$bytes.Length) {
                throw 'ICO image entry is invalid.'
            }
            [pscustomobject]@{
                Width = $width
                Height = $height
                Length = $length
                Offset = $imageOffset
            }
        }

        [pscustomobject]@{
            Count = [int]$count
            Entries = @($entries)
        }
    }

    function Get-TestSvgGeometry {
        param([Parameter(Mandatory)][xml]$Document)

        $geometryNames = @('rect', 'circle', 'path', 'ellipse', 'line', 'polyline', 'polygon')
        $Document.SelectNodes('//*') | Where-Object LocalName -In $geometryNames
    }
}

Describe 'ICO directory validation' {
    It 'rejects an image payload offset inside the ICO directory' {
        $path = Join-Path $TestDrive 'inside-directory.ico'
        $bytes = [byte[]]::new(26)
        [BitConverter]::GetBytes([uint16]1).CopyTo($bytes, 2)
        [BitConverter]::GetBytes([uint16]1).CopyTo($bytes, 4)
        $bytes[6] = 16
        $bytes[7] = 16
        [BitConverter]::GetBytes([uint32]2).CopyTo($bytes, 14)
        [BitConverter]::GetBytes([uint32]20).CopyTo($bytes, 18)
        [IO.File]::WriteAllBytes($path, $bytes)

        { Read-TestIcoDirectory -Path $path } |
            Should -Throw -ExpectedMessage 'ICO image entry is invalid.'
    }

    It 'rejects an image payload that extends beyond the ICO file' {
        $path = Join-Path $TestDrive 'out-of-bounds.ico'
        $bytes = [byte[]]::new(26)
        [BitConverter]::GetBytes([uint16]1).CopyTo($bytes, 2)
        [BitConverter]::GetBytes([uint16]1).CopyTo($bytes, 4)
        $bytes[6] = 16
        $bytes[7] = 16
        [BitConverter]::GetBytes([uint32]5).CopyTo($bytes, 14)
        [BitConverter]::GetBytes([uint32]22).CopyTo($bytes, 18)
        [IO.File]::WriteAllBytes($path, $bytes)

        { Read-TestIcoDirectory -Path $path } |
            Should -Throw -ExpectedMessage 'ICO image entry is invalid.'
    }
}

Describe 'SVG design contract validation' {
    It 'does not treat design strings in comments or metadata as geometry elements' {
        [xml]$svg = @'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <!-- <rect x="5" y="5" width="118" height="118" rx="29"/>
       <circle cx="64" cy="64" r="41"/>
       <path d="M64 23a41 41 0 1 1-37.9 56.5"/>
       <path d="m47 51 13 13-13 13M66 78h18"/> -->
  <metadata>#FFFFFF #D7DDE5 #E7EBF0 #64748B #1F2937</metadata>
</svg>
'@

        @(Get-TestSvgGeometry -Document $svg).Count | Should -Be 0
    }
}

Describe 'shortcut icon assets' {
    It 'matches the <Name> SVG design contract' -TestCases @(
        @{
            Name = 'white'
            File = 'codex-quota-monitor-white.svg'
            Colors = @('#FFFFFF', '#D7DDE5', '#E7EBF0', '#64748B', '#1F2937')
            Border = '#D7DDE5'
            Track = '#E7EBF0'
            Arc = '#64748B'
            Glyph = '#1F2937'
            GradientStops = @()
        }
        @{
            Name = 'white-blue'
            File = 'codex-quota-monitor-white-blue.svg'
            Colors = @('#FFFFFF', '#BFDBFE', '#DBEAFE', '#60A5FA', '#2563EB', '#1E3A8A')
            Border = '#BFDBFE'
            Track = '#DBEAFE'
            Arc = 'url(#quotaArc)'
            Glyph = '#1E3A8A'
            GradientStops = @('#60A5FA', '#2563EB')
        }
    ) {
        param($Name, $File, $Colors, $Border, $Track, $Arc, $Glyph, $GradientStops)

        $path = Join-Path $RepoRoot "assets\$File"
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $svgText = [IO.File]::ReadAllText($path)
        [xml]$svg = $svgText

        $root = $svg.DocumentElement
        $root.LocalName | Should -Be 'svg'
        $root.NamespaceURI | Should -Be 'http://www.w3.org/2000/svg'
        $root.GetAttribute('viewBox') | Should -Be '0 0 128 128'
        $root.GetAttribute('role') | Should -Be 'img'
        $root.GetAttribute('aria-label') | Should -Be 'Quota monitor gauge'

        $geometry = @(Get-TestSvgGeometry -Document $svg)
        $rects = @($geometry | Where-Object LocalName -EQ 'rect')
        $circles = @($geometry | Where-Object LocalName -EQ 'circle')
        $paths = @($geometry | Where-Object LocalName -EQ 'path')
        $geometry.Count | Should -Be 4
        $rects.Count | Should -Be 1
        $circles.Count | Should -Be 1
        $paths.Count | Should -Be 2

        $rect = $rects[0]
        $rect.GetAttribute('x') | Should -Be '5'
        $rect.GetAttribute('y') | Should -Be '5'
        $rect.GetAttribute('width') | Should -Be '118'
        $rect.GetAttribute('height') | Should -Be '118'
        $rect.GetAttribute('rx') | Should -Be '29'
        $rect.GetAttribute('fill') | Should -Be '#FFFFFF'
        $rect.GetAttribute('stroke') | Should -Be $Border
        $rect.GetAttribute('stroke-width') | Should -Be '4'

        $circle = $circles[0]
        $circle.GetAttribute('cx') | Should -Be '64'
        $circle.GetAttribute('cy') | Should -Be '64'
        $circle.GetAttribute('r') | Should -Be '41'
        $circle.GetAttribute('fill') | Should -Be 'none'
        $circle.GetAttribute('stroke') | Should -Be $Track
        $circle.GetAttribute('stroke-width') | Should -Be '12'

        $arcPaths = @($paths | Where-Object { $_.GetAttribute('d') -ceq 'M64 23a41 41 0 1 1-37.9 56.5' })
        $arcPaths.Count | Should -Be 1
        $arcPath = $arcPaths[0]
        $arcPath.GetAttribute('fill') | Should -Be 'none'
        $arcPath.GetAttribute('stroke') | Should -Be $Arc
        $arcPath.GetAttribute('stroke-width') | Should -Be '12'
        $arcPath.GetAttribute('stroke-linecap') | Should -Be 'round'

        $terminalPaths = @($paths | Where-Object { $_.GetAttribute('d') -ceq 'm47 51 13 13-13 13M66 78h18' })
        $terminalPaths.Count | Should -Be 1
        $terminalPath = $terminalPaths[0]
        $terminalPath.GetAttribute('fill') | Should -Be 'none'
        $terminalPath.GetAttribute('stroke') | Should -Be $Glyph
        $terminalPath.GetAttribute('stroke-width') | Should -Be '7'
        $terminalPath.GetAttribute('stroke-linecap') | Should -Be 'round'
        $terminalPath.GetAttribute('stroke-linejoin') | Should -Be 'round'

        $gradients = @($svg.SelectNodes('//*[local-name()="linearGradient"]'))
        $stops = @($svg.SelectNodes('//*[local-name()="stop"]'))
        if ($GradientStops.Count -eq 0) {
            $gradients.Count | Should -Be 0
            $stops.Count | Should -Be 0
        }
        else {
            $gradients.Count | Should -Be 1
            $gradient = $gradients[0]
            $gradient.GetAttribute('id') | Should -Be 'quotaArc'
            $gradient.GetAttribute('x1') | Should -Be '0'
            $gradient.GetAttribute('y1') | Should -Be '0'
            $gradient.GetAttribute('x2') | Should -Be '1'
            $gradient.GetAttribute('y2') | Should -Be '1'
            $stops.Count | Should -Be 2
            $stops[0].GetAttribute('offset') | Should -Be ''
            $stops[0].GetAttribute('stop-color') | Should -Be $GradientStops[0]
            $stops[1].GetAttribute('offset') | Should -Be '1'
            $stops[1].GetAttribute('stop-color') | Should -Be $GradientStops[1]
        }

        $paintValues = foreach ($element in @($svg.SelectNodes('//*'))) {
            foreach ($attributeName in @('fill', 'stroke', 'stop-color')) {
                if ($element.HasAttribute($attributeName)) {
                    $element.GetAttribute($attributeName)
                }
            }
        }
        $permittedPaintValues = @($Colors) + @('none', 'url(#quotaArc)')
        foreach ($paintValue in $paintValues) {
            $paintValue | Should -BeIn $permittedPaintValues
        }
        @($paintValues | Where-Object { $_ -match '^#[0-9A-F]{6}$' } | Sort-Object -Unique) |
            Should -Be @($Colors | Sort-Object)
        @($svg.SelectNodes('//*[@style]')).Count | Should -Be 0
        $svgText | Should -Not -Match '(?i)openai|blossom|wordmark'
    }

    It 'contains all required frames in <File>' -TestCases @(
        @{ File = 'codex-quota-monitor-white.ico' }
        @{ File = 'codex-quota-monitor-white-blue.ico' }
    ) {
        param($File)

        $path = Join-Path $RepoRoot "assets\$File"
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $directory = Read-TestIcoDirectory -Path $path
        $directory.Count | Should -Be 7
        @($directory.Entries.Width | Sort-Object) | Should -Be @(16, 24, 32, 48, 64, 128, 256)
    }
}
