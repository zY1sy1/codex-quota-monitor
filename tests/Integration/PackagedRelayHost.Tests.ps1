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

    It 'inspects a synthetic CC Switch database with a sanitized Ready descriptor' {
        $exe = Join-Path $BinRoot 'relay-quota-host.exe'
        $databasePath = Join-Path $TestDrive 'cc-switch-synthetic.db'
        $fixtureGzipBase64 = @'
H4sIAAAAAAACCu1WT1PTQBTftPwRHc7VA0MmHkKdSM2gg8SDFolMpRRpgyOnzJI8ykq6CZtNATM5iONH8CN58AP4TTx49CXQMhUcD3pR+GV3svv2N7v73svuL53NJpOg7oaiR6W6QEpEUcgzVSWEjGEdJ+con9kGUMjvMUbmP30pJikV/XHlO/kn8P6eMlmZnVVO7kq6E0Akwj7zQcTDRul52647turUl5u2OjSrc8xXHfuNo75qN9br7W11zd42VBpFrjyO4HSotYF1q9k0VE57F2wxSMl4N3a9kO+y7s/DPZB01FY1SxMVe1YhjPtwFB8EmFGXJjIs+u5wb645bOa5vJH7OV0k0iF5+Vv4UFUmZyp34GMnDhPhwX3TC3Ejh3Qfn1SjEVuDY83SXmy0lxsrK3bL7diO02itdrCBYXXcJXPh0aKWpVoS0y64sSdYJDUr1YDn2fA1S4oEDC2gvJsgAyd7S/v0jGdo+Xpom0sFHCQQSytNRGDpabpDY9gSQZbV+matmFw3MKB7oW/pq7ajG3tA8/hYaT1Bq2DvqGQht/RloAKEmqanu88yPcsMOJKCejIU1m7CvZw4JyCOQh5DFZeWieBqyuLXNGD+6Y4F9CjjmF1rQJzfoeiFB0bCmbT0rc6Knj3Jsip6IVkPwgT9Nh9gB3pRQCU4+BWha13gIGiArDzRmwmI4waXIPpoK/iXRHndduqDCC8+frhgall2M8+/8o1gucYVwa3yzNTgZBbnX/lKsFzjf0FVmSAzlaWpket3T8ootmo1vBjmD/f385cX9qZRkMtkjSi3lc/4+iPJfFmerJimcvJ0RDJd4H6EUiTji5axS0X0fLxQ00bLsVft9qigDrkDuT0XyF9pLUrABarvg+/ij89gjaGkXhX9/wGwtquqAAoAAA==
'@
        $compressedBytes = [Convert]::FromBase64String(($fixtureGzipBase64 -replace '\s', ''))
        $inputStream = [IO.MemoryStream]::new($compressedBytes, $false)
        $outputStream = [IO.MemoryStream]::new()
        $gzipStream = [IO.Compression.GZipStream]::new(
            $inputStream,
            [IO.Compression.CompressionMode]::Decompress
        )
        try {
            $gzipStream.CopyTo($outputStream)
            [IO.File]::WriteAllBytes($databasePath, $outputStream.ToArray())
        }
        finally {
            $gzipStream.Dispose()
            $outputStream.Dispose()
            $inputStream.Dispose()
            [Array]::Clear($compressedBytes, 0, $compressedBytes.Length)
        }

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $exe
        $startInfo.ArgumentList.Add('--inspect-cc-switch')
        $startInfo.ArgumentList.Add($databasePath)
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($startInfo)
        try {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit(5000) | Should -BeTrue
            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()

            $process.ExitCode | Should -Be 0
            $stderr | Should -BeExactly ''
            ([regex]::Matches($stdout, "`n")).Count | Should -Be 1
            $response = $stdout | ConvertFrom-Json -Depth 12
            $response.ok | Should -BeTrue
            @($response.providers).Count | Should -Be 1
            $response.providers[0].sourceProviderId | Should -BeExactly 'source-1'
            $response.providers[0].sourceAppType | Should -BeExactly 'codex'
            $response.providers[0].name | Should -BeExactly 'wakaka'
            @($response.providers[0].endpointCandidates) |
                Should -Be @('https://api.wkkapi.com')
            $response.providers[0].importStatus | Should -BeExactly 'ready'
            $response.providers[0].code | Should -Match '\{\{apiKey\}\}'
            $stdout | Should -Not -Match 'FORBIDDEN_META_SECRET_78431|FORBIDDEN_SETTINGS_SECRET_91357'
        }
        finally {
            $process.Dispose()
        }
    }

    It 'ships notices for every runtime dependency with source and license references' {
        $noticesPath = Join-Path $CompanionRoot 'ThirdPartyNotices.txt'
        Test-Path -LiteralPath $noticesPath -PathType Leaf | Should -BeTrue
        $notices = [IO.File]::ReadAllText($noticesPath)
        foreach ($dependency in @(
            'QuickJS', 'rquickjs', 'reqwest', 'serde', 'rustls', 'url',
            'SQLite', 'rusqlite', 'regex', 'zeroize'
        )) {
            $notices | Should -Match ([regex]::Escape($dependency))
        }
        $notices | Should -Match '(?i)https?://'
        $notices | Should -Match '(?i)MIT|Apache-2\.0|ISC'
    }
}
