BeforeAll {
    $script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
    $script:CompanionRoot = Join-Path $script:RepoRoot 'companion'
    $script:BinRoot = Join-Path $script:CompanionRoot 'Bin'
    function Get-PeMachine {
        param([Parameter(Mandatory)][string]$Path)

        $stream = [IO.File]::OpenRead($Path)
        $reader = [IO.BinaryReader]::new($stream)
        try {
            $stream.Position = 0x3c
            $peOffset = $reader.ReadInt32()
            $stream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x00004550) {
                throw 'The packaged relay host is not a PE image.'
            }
            return $reader.ReadUInt16()
        }
        finally {
            $reader.Dispose()
            $stream.Dispose()
        }
    }
}

Describe 'Packaged relay quota host' {
    It 'ships a hash-matched self-testing Windows x64 host' {
        $exe = Join-Path $BinRoot 'relay-quota-host.exe'
        $manifest = Join-Path $BinRoot 'relay-quota-host.sha256'

        Test-Path -LiteralPath $exe -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $manifest -PathType Leaf | Should -BeTrue

        $manifestText = [IO.File]::ReadAllText($manifest)
        $manifestText | Should -Match '^[0-9A-Fa-f]{64}\r?\n?$'
        $manifestText.Trim() | Should -BeExactly ([IO.File]::ReadAllText($manifest).Trim().ToUpperInvariant())
        (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash |
            Should -BeExactly $manifestText.Trim()
        (Get-PeMachine -Path $exe) | Should -Be 0x8664

        $stdoutPath = Join-Path $TestDrive 'relay-host.stdout'
        $stderrPath = Join-Path $TestDrive 'relay-host.stderr'
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $exe
        $startInfo.ArgumentList.Add('--self-test')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($startInfo)
        try {
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit(5000) | Should -BeTrue
            $process.ExitCode | Should -Be 0
            $stdout | Should -BeExactly "relay-quota-host: ok`n"
            $stderr | Should -BeExactly ''
        }
        finally {
            $process.Dispose()
        }
    }

    It 'ships notices for every runtime dependency with source and license references' {
        $noticesPath = Join-Path $CompanionRoot 'ThirdPartyNotices.txt'
        Test-Path -LiteralPath $noticesPath -PathType Leaf | Should -BeTrue
        $notices = [IO.File]::ReadAllText($noticesPath)
        foreach ($dependency in @('QuickJS', 'rquickjs', 'reqwest', 'serde', 'rustls', 'url')) {
            $notices | Should -Match ([regex]::Escape($dependency))
        }
        $notices | Should -Match '(?i)https?://'
        $notices | Should -Match '(?i)MIT|Apache-2\.0|ISC'
    }
}
