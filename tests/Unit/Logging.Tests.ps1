BeforeAll {
    $loggingScript = "$PSScriptRoot\..\..\companion\Private\Logging.ps1"
    if (Test-Path -LiteralPath $loggingScript -PathType Leaf) {
        . $loggingScript
    }

    if (-not ('CodexQuotaMonitor.Tests.StatefulDictionary' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections;

namespace CodexQuotaMonitor.Tests
{
    public sealed class NonDictionaryLogData
    {
        public NonDictionaryLogData(string accessToken) { AccessToken = accessToken; }
        public string AccessToken { get; }
        public override string ToString() { return AccessToken; }
    }

    public sealed class StatefulDictionary : IDictionary
    {
        private readonly object[] firstKeys;
        private readonly object[] firstValues;
        private readonly object[] laterKeys;
        private readonly object[] laterValues;

        public StatefulDictionary(
            object[] firstKeys,
            object[] firstValues,
            object[] laterKeys,
            object[] laterValues)
        {
            if (firstKeys.Length != firstValues.Length || laterKeys.Length != laterValues.Length)
                throw new ArgumentException("Key and value counts must match.");
            this.firstKeys = firstKeys;
            this.firstValues = firstValues;
            this.laterKeys = laterKeys;
            this.laterValues = laterValues;
        }

        public int EnumeratorCount { get; private set; }
        public object this[object key]
        {
            get
            {
                for (var index = 0; index < laterKeys.Length; index++)
                    if (Equals(laterKeys[index], key)) return laterValues[index];
                return null;
            }
            set { throw new NotSupportedException(); }
        }
        public ICollection Keys { get { return laterKeys; } }
        public ICollection Values { get { return laterValues; } }
        public bool IsReadOnly { get { return true; } }
        public bool IsFixedSize { get { return true; } }
        public int Count { get { return firstKeys.Length; } }
        public object SyncRoot { get { return this; } }
        public bool IsSynchronized { get { return false; } }

        public IDictionaryEnumerator GetEnumerator()
        {
            EnumeratorCount++;
            return EnumeratorCount == 1
                ? new EntryEnumerator(firstKeys, firstValues)
                : new EntryEnumerator(laterKeys, laterValues);
        }

        IEnumerator IEnumerable.GetEnumerator() { return GetEnumerator(); }
        public bool Contains(object key) { return Array.IndexOf(laterKeys, key) >= 0; }
        public void CopyTo(Array array, int index)
        {
            var enumerator = GetEnumerator();
            while (enumerator.MoveNext()) array.SetValue(enumerator.Entry, index++);
        }
        public void Add(object key, object value) { throw new NotSupportedException(); }
        public void Clear() { throw new NotSupportedException(); }
        public void Remove(object key) { throw new NotSupportedException(); }

        private sealed class EntryEnumerator : IDictionaryEnumerator
        {
            private readonly object[] keys;
            private readonly object[] values;
            private int index = -1;

            public EntryEnumerator(object[] keys, object[] values)
            {
                this.keys = keys;
                this.values = values;
            }

            public DictionaryEntry Entry { get { return new DictionaryEntry(Key, Value); } }
            public object Key { get { return keys[index]; } }
            public object Value { get { return values[index]; } }
            public object Current { get { return Entry; } }
            public bool MoveNext() { return ++index < keys.Length; }
            public void Reset() { index = -1; }
        }
    }
}
'@
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

    It 'rejects non-dictionary data internally without rendering sensitive input' {
        $sentinel = 'SECRET_SENTINEL_ACCESS_TOKEN'
        $values = @(
            [pscustomobject]@{ accessToken = $sentinel },
            [CodexQuotaMonitor.Tests.NonDictionaryLogData]::new($sentinel)
        )

        for ($index = 0; $index -lt $values.Count; $index++) {
            $directory = Join-Path $TestDrive "non-dictionary-$index"
            $caught = $null
            try {
                Write-MonitorLog -LogDirectory $directory -Level 'Error' -Event 'rejected.data' -Data $values[$index]
                throw 'Expected Write-MonitorLog to reject non-dictionary data.'
            }
            catch {
                $caught = $_
            }

            $caught.Exception.Message | Should -BeExactly 'Log data must be a flat dictionary.'
            ($caught | Out-String) | Should -Not -Match ([regex]::Escape($sentinel))
            $fileText = @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue | ForEach-Object {
                [IO.File]::ReadAllText($_.FullName)
            }) -join "`n"
            $fileText | Should -Not -Match ([regex]::Escape($sentinel))
        }
    }

    It 'logs a normal dictionary entry whose key is Keys' {
        $directory = Join-Path $TestDrive 'keys-field'

        Write-MonitorLog -LogDirectory $directory -Level 'Info' -Event 'keys.field' -Data ([ordered]@{
            Keys = 'ordinary-value'
        })

        $record = Get-Content -LiteralPath (Join-Path $directory 'monitor.log') -Raw | ConvertFrom-Json
        $record.Data.Keys | Should -BeExactly 'ordinary-value'
    }

    It 'enumerates stateful dictionaries once and copies the first immutable snapshot' {
        $directory = Join-Path $TestDrive 'single-snapshot'
        $sentinel = 'SECRET_SENTINEL_LATER_ENUMERATION'
        $data = [CodexQuotaMonitor.Tests.StatefulDictionary]::new(
            [object[]]@('Message'),
            [object[]]@('first-snapshot'),
            [object[]]@('accessToken'),
            [object[]]@($sentinel)
        )

        Write-MonitorLog -LogDirectory $directory -Level 'Info' -Event 'snapshot.once' -Data $data

        $data.EnumeratorCount | Should -Be 1
        $text = [IO.File]::ReadAllText((Join-Path $directory 'monitor.log'))
        $record = $text | ConvertFrom-Json
        $record.Data.Message | Should -BeExactly 'first-snapshot'
        $record.Data.PSObject.Properties.Name | Should -Not -Contain 'accessToken'
        $text | Should -Not -Match ([regex]::Escape($sentinel))
    }

    It 'validates the same stateful snapshot and does not bypass a sensitive key' {
        $directory = Join-Path $TestDrive 'sensitive-first-snapshot'
        $sentinel = 'SECRET_SENTINEL_FIRST_ENUMERATION'
        $data = [CodexQuotaMonitor.Tests.StatefulDictionary]::new(
            [object[]]@('accessToken'),
            [object[]]@($sentinel),
            [object[]]@('Safe'),
            [object[]]@('allowed')
        )
        $caught = $null

        try {
            Write-MonitorLog -LogDirectory $directory -Level 'Error' -Event 'snapshot.rejected' -Data $data
            throw 'Expected Write-MonitorLog to reject the first snapshot.'
        }
        catch {
            $caught = $_
        }

        $data.EnumeratorCount | Should -Be 1
        $caught.Exception.Message | Should -BeExactly 'Log data contains a prohibited field name.'
        ($caught | Out-String) | Should -Not -Match ([regex]::Escape($sentinel))
        $fileText = @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue | ForEach-Object {
            [IO.File]::ReadAllText($_.FullName)
        }) -join "`n"
        $fileText | Should -Not -Match ([regex]::Escape($sentinel))
    }

    It 'rejects duplicate and nonstring keys from one snapshot with a constant error' -ForEach @(
        @{
            Name = 'duplicate'
            FirstKeys = [object[]]@('Safe', 'Safe')
            FirstValues = [object[]]@('DUPLICATE_VALUE_SENTINEL_A', 'DUPLICATE_VALUE_SENTINEL_B')
            SecretPattern = 'DUPLICATE_VALUE_SENTINEL_[AB]'
        }
        @{
            Name = 'nonstring'
            FirstKeys = [object[]]@(42)
            FirstValues = [object[]]@('NONSTRING_VALUE_SENTINEL')
            SecretPattern = 'NONSTRING_VALUE_SENTINEL'
        }
    ) {
        $directory = Join-Path $TestDrive "invalid-key-$Name"
        $data = [CodexQuotaMonitor.Tests.StatefulDictionary]::new(
            $FirstKeys,
            $FirstValues,
            [object[]]@('Safe'),
            [object[]]@('allowed')
        )
        $caught = $null

        try {
            Write-MonitorLog -LogDirectory $directory -Level 'Error' -Event 'invalid.key' -Data $data
            throw 'Expected Write-MonitorLog to reject the invalid key snapshot.'
        }
        catch {
            $caught = $_
        }

        $data.EnumeratorCount | Should -Be 1
        $caught.Exception.Message | Should -BeExactly 'Log data field names must be unique nonempty strings.'
        ($caught | Out-String) | Should -Not -Match $SecretPattern
    }

    It 'validates values from the same snapshot instead of rereading the dictionary' {
        $directory = Join-Path $TestDrive 'invalid-first-value'
        $sentinel = 'SECRET_SENTINEL_NESTED_VALUE'
        $data = [CodexQuotaMonitor.Tests.StatefulDictionary]::new(
            [object[]]@('Context'),
            [object[]]@([pscustomobject]@{ accessToken = $sentinel }),
            [object[]]@('Context'),
            [object[]]@('allowed')
        )
        $caught = $null

        try {
            Write-MonitorLog -LogDirectory $directory -Level 'Error' -Event 'invalid.value' -Data $data
            throw 'Expected Write-MonitorLog to reject the first value snapshot.'
        }
        catch {
            $caught = $_
        }

        $data.EnumeratorCount | Should -Be 1
        $caught.Exception.Message | Should -BeExactly 'Log data values must be flat scalar values.'
        ($caught | Out-String) | Should -Not -Match ([regex]::Escape($sentinel))
        Test-Path -LiteralPath (Join-Path $directory 'monitor.log') | Should -BeFalse
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
