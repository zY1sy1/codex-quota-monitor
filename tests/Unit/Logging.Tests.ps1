BeforeAll {
    $loggingScript = "$PSScriptRoot\..\..\companion\Private\Logging.ps1"
    if (Test-Path -LiteralPath $loggingScript -PathType Leaf) {
        . $loggingScript
    }
}

Describe 'Write-MonitorLog' {
    It 'creates a compact UTF-8 JSON line with a UTC timestamp and safe Unicode data' {
        $directory = Join-Path $TestDrive 'unicode-log'
        $now = [DateTimeOffset]'2026-07-14T01:02:03+08:00'
        $data = [ordered]@{
            Message = '配额正常 ✅'
            Remaining = [double]42.5
            Connected = $true
            Optional = $null
        }

        Write-MonitorLog -LogDirectory $directory -Level 'Info' -Event 'quota.updated' -Data $data -Now $now

        $path = Join-Path $directory 'monitor.log'
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($path)
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $text | Should -Match '配额正常 ✅'
        @($text -split "`n" | Where-Object { $_.Length -gt 0 }).Count | Should -Be 1
        $text.TrimEnd("`r", "`n") | Should -Not -Match "`r|`n"

        $record = $text | ConvertFrom-Json
        $timestampText = [regex]::Match($text, '"Timestamp":"(?<Timestamp>[^"]+)"').Groups['Timestamp'].Value
        $timestampText | Should -BeExactly '2026-07-13T17:02:03.0000000Z'
        $record.Level | Should -BeExactly 'Info'
        $record.Event | Should -BeExactly 'quota.updated'
        $record.Data.Message | Should -BeExactly '配额正常 ✅'
        $record.Data.Remaining | Should -Be 42.5
        $record.Data.Connected | Should -BeTrue
        $record.Data.PSObject.Properties.Name | Should -Contain 'Optional'
        $record.Data.Optional | Should -BeNullOrEmpty
    }

    It 'writes an empty data object when optional data is omitted' {
        $directory = Join-Path $TestDrive 'empty-data'

        Write-MonitorLog -LogDirectory $directory -Level 'Warning' -Event 'connection.waiting'

        $record = Get-Content -LiteralPath (Join-Path $directory 'monitor.log') -Raw | ConvertFrom-Json
        $record.PSObject.Properties.Name | Should -Contain 'Data'
        @($record.Data.PSObject.Properties).Count | Should -Be 0
    }

    It 'rotates before writing and retains current plus monitor.1 through monitor.5 in newest order' {
        $directory = Join-Path $TestDrive 'rotation'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $directory 'unrelated.txt'), 'keep me')

        foreach ($sequence in 1..7) {
            Write-MonitorLog -LogDirectory $directory -Level 'Info' -Event 'rotation.entry' -Data ([ordered]@{
                Sequence = $sequence
                Padding = 'x' * 256
            }) -Now ([DateTimeOffset]'2026-07-14T00:00:00Z').AddSeconds($sequence) -MaximumBytes 128 -RetainedFiles 5
        }

        $expected = [ordered]@{
            'monitor.log' = 7
            'monitor.1.log' = 6
            'monitor.2.log' = 5
            'monitor.3.log' = 4
            'monitor.4.log' = 3
            'monitor.5.log' = 2
        }
        @(Get-ChildItem -LiteralPath $directory -File -Filter 'monitor*.log').Name | Sort-Object | Should -Be @($expected.Keys | Sort-Object)
        foreach ($fileName in $expected.Keys) {
            $record = Get-Content -LiteralPath (Join-Path $directory $fileName) -Raw | ConvertFrom-Json
            $record.Data.Sequence | Should -Be $expected[$fileName]
        }
        Test-Path -LiteralPath (Join-Path $directory 'monitor.6.log') | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $directory 'unrelated.txt')) | Should -BeExactly 'keep me'
    }

    It 'uses UTF-8 byte count rather than character count for the rotation threshold' {
        $directory = Join-Path $TestDrive 'byte-threshold'
        $now = [DateTimeOffset]'2026-07-14T00:00:00Z'
        $data = [ordered]@{ Message = '配' * 40 }

        Write-MonitorLog -LogDirectory $directory -Level 'Info' -Event 'unicode-byte-1' -Data $data -Now $now -MaximumBytes 4096
        $path = Join-Path $directory 'monitor.log'
        $firstByteCount = (Get-Item -LiteralPath $path).Length
        $firstCharacterCount = [IO.File]::ReadAllText($path).Length
        $firstByteCount | Should -BeGreaterThan $firstCharacterCount
        $threshold = $firstByteCount + $firstCharacterCount

        Write-MonitorLog -LogDirectory $directory -Level 'Info' -Event 'unicode-byte-2' -Data $data -Now $now -MaximumBytes $threshold

        $current = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $rotated = Get-Content -LiteralPath (Join-Path $directory 'monitor.1.log') -Raw | ConvertFrom-Json
        $current.Event | Should -BeExactly 'unicode-byte-2'
        $rotated.Event | Should -BeExactly 'unicode-byte-1'
    }

    It 'rejects sensitive field names without writing the rejected key or value anywhere' -ForEach @(
        @{ Key = 'accessToken'; Value = 'secret-token-value' }
        @{ Key = 'AUTHORIZATION'; Value = 'Bearer hidden-value' }
        @{ Key = 'customerEmail'; Value = 'person@example.invalid' }
        @{ Key = 'rawPayload'; Value = 'raw-server-secret' }
        @{ Key = 'sessionCookie'; Value = 'cookie-secret-value' }
    ) {
        $directory = Join-Path $TestDrive "rejected-$Key"
        $data = [ordered]@{ Safe = 'allowed' }
        $data[$Key] = $Value
        $caught = $null

        try {
            Write-MonitorLog -LogDirectory $directory -Level 'Error' -Event 'rejected.data' -Data $data
            throw 'Expected Write-MonitorLog to reject sensitive data.'
        }
        catch {
            $caught = $_
        }

        $caught.Exception.Message | Should -BeExactly 'Log data contains a prohibited field name.'
        ($caught | Out-String) | Should -Not -Match ([regex]::Escape($Key))
        ($caught | Out-String) | Should -Not -Match ([regex]::Escape($Value))
        $fileText = @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue | ForEach-Object {
            [IO.File]::ReadAllText($_.FullName)
        }) -join "`n"
        $fileText | Should -Not -Match ([regex]::Escape($Key))
        $fileText | Should -Not -Match ([regex]::Escape($Value))
    }

    It 'rejects dictionaries, collections, and custom objects as nested data values' -ForEach @(
        @{ Name = 'dictionary'; Value = [ordered]@{ Detail = 'nested-secret-one' }; Secret = 'nested-secret-one' }
        @{ Name = 'collection'; Value = @('nested-secret-two'); Secret = 'nested-secret-two' }
        @{ Name = 'object'; Value = [pscustomobject]@{ Detail = 'nested-secret-three' }; Secret = 'nested-secret-three' }
        @{ Name = 'structured-value'; Value = [TimeSpan]::FromMinutes(5); Secret = 'not-present' }
    ) {
        $directory = Join-Path $TestDrive "nested-$Name"
        $caught = $null

        try {
            Write-MonitorLog -LogDirectory $directory -Level 'Info' -Event 'nested.data' -Data ([ordered]@{ Context = $Value })
            throw 'Expected Write-MonitorLog to reject nested data.'
        }
        catch {
            $caught = $_
        }

        $caught.Exception.Message | Should -BeExactly 'Log data values must be flat scalar values.'
        ($caught | Out-String) | Should -Not -Match ([regex]::Escape($Secret))
        $fileText = @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue | ForEach-Object {
            [IO.File]::ReadAllText($_.FullName)
        }) -join "`n"
        $fileText | Should -Not -Match ([regex]::Escape($Secret))
    }
}
