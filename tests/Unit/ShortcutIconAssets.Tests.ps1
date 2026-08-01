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
        if ($reserved -ne 0 -or $type -ne 1 -or $bytes.Length -lt (6 + 16 * $count)) {
            throw 'ICO directory is invalid.'
        }

        $entries = for ($index = 0; $index -lt $count; $index++) {
            $offset = 6 + (16 * $index)
            $width = if ($bytes[$offset] -eq 0) { 256 } else { [int]$bytes[$offset] }
            $height = if ($bytes[$offset + 1] -eq 0) { 256 } else { [int]$bytes[$offset + 1] }
            $length = [BitConverter]::ToUInt32($bytes, $offset + 8)
            $imageOffset = [BitConverter]::ToUInt32($bytes, $offset + 12)
            if ($width -ne $height -or $length -eq 0 -or
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
}

Describe 'shortcut icon assets' {
    It 'matches the <Name> SVG design contract' -TestCases @(
        @{
            Name = 'white'
            File = 'codex-quota-monitor-white.svg'
            Colors = @('#FFFFFF', '#D7DDE5', '#E7EBF0', '#64748B', '#1F2937')
        }
        @{
            Name = 'white-blue'
            File = 'codex-quota-monitor-white-blue.svg'
            Colors = @('#FFFFFF', '#BFDBFE', '#DBEAFE', '#60A5FA', '#2563EB', '#1E3A8A')
        }
    ) {
        param($Name, $File, $Colors)

        $path = Join-Path $RepoRoot "assets\$File"
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $svg = [IO.File]::ReadAllText($path)
        $svg | Should -Match 'viewBox="0 0 128 128"'
        $svg | Should -Match '<rect x="5" y="5" width="118" height="118" rx="29"'
        $svg | Should -Match '<circle cx="64" cy="64" r="41"'
        $svg | Should -Match 'M64 23a41 41 0 1 1-37\.9 56\.5'
        $svg | Should -Match 'm47 51 13 13-13 13M66 78h18'
        foreach ($color in $Colors) {
            $svg | Should -Match ([regex]::Escape($color))
        }
        $svg | Should -Not -Match '(?i)openai|blossom|wordmark'
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
