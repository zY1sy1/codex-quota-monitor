BeforeAll {
    $settingsScript = "$PSScriptRoot\..\..\companion\Private\Settings.ps1"
    if (Test-Path -LiteralPath $settingsScript -PathType Leaf) {
        . $settingsScript
    }
}

Describe 'Get-MonitorPaths' {
    It 'builds every monitor path from injected roots' {
        $localAppData = Join-Path $TestDrive 'Local App Data'
        $startup = Join-Path $TestDrive 'Startup Folder'

        $paths = Get-MonitorPaths -LocalAppData $localAppData -Startup $startup
        $root = Join-Path $localAppData 'CodexQuotaMonitor'

        $paths.Root | Should -BeExactly $root
        $paths.App | Should -BeExactly (Join-Path $root 'app')
        $paths.Data | Should -BeExactly (Join-Path $root 'data')
        $paths.Logs | Should -BeExactly (Join-Path $root 'logs')
        $paths.Settings | Should -BeExactly (Join-Path $root 'data\settings.json')
        $paths.Health | Should -BeExactly (Join-Path $root 'data\health.json')
        $paths.RelayImportLinks | Should -BeExactly (Join-Path $root 'data\relay-import-links.json')
        $paths.StartupShortcut | Should -BeExactly (Join-Path $startup 'Codex Quota Monitor.lnk')
    }

    It 'separates packaged program files from mutable current-user data' {
        $localAppData = Join-Path $TestDrive 'Packaged Local App Data'
        $startup = Join-Path $TestDrive 'Packaged Startup Folder'
        $programRoot = Join-Path $localAppData 'Programs\CodexQuotaMonitor'

        $paths = Get-MonitorPaths `
            -LocalAppData $localAppData `
            -Startup $startup `
            -ProgramRoot $programRoot

        $dataRoot = Join-Path $localAppData 'CodexQuotaMonitor'
        $paths.Root | Should -BeExactly $dataRoot
        $paths.ProgramRoot | Should -BeExactly $programRoot
        $paths.App | Should -BeExactly (Join-Path $programRoot 'app')
        $paths.LegacyApp | Should -BeExactly (Join-Path $dataRoot 'app')
        $paths.Payload | Should -BeExactly (Join-Path $programRoot 'payload')
        $paths.Runtime | Should -BeExactly (Join-Path $programRoot 'runtime\pwsh')
        $paths.PrivatePwsh | Should -BeExactly (Join-Path $programRoot 'runtime\pwsh\pwsh.exe')
        $paths.RelayHost | Should -BeExactly (Join-Path $programRoot 'app\Bin\relay-quota-host.exe')
        $paths.RelayPresets | Should -BeExactly (Join-Path $programRoot 'app\Presets\relay-usage.json')
        $paths.Data | Should -BeExactly (Join-Path $dataRoot 'data')
        $paths.Logs | Should -BeExactly (Join-Path $dataRoot 'logs')
        $paths.StartupShortcut | Should -BeExactly (Join-Path $startup 'Codex Quota Monitor.lnk')
    }
}

Describe 'New-DefaultSettings' {
    It 'returns fresh schema-2 appearance and per-mode positions' {
        $settings = New-DefaultSettings

        $settings.SchemaVersion | Should -Be 2
        $settings.Appearance.Theme | Should -BeExactly 'Dark'
        $settings.Appearance.DisplayMode | Should -BeExactly 'Full'
        $settings.Appearance.FullLayout | Should -BeExactly 'Overview'
        $settings.Appearance.RememberLastMode | Should -BeTrue
        $settings.Window.Full.Topmost | Should -BeTrue
        $settings.Window.Full.Visible | Should -BeTrue
        $settings.Window.Full.Width | Should -Be 420
        $settings.Window.Full.Height | Should -Be 560
        $settings.Window.CompactBar.Left | Should -BeNullOrEmpty
        $settings.Window.Orb.Top | Should -BeNullOrEmpty
        $settings.Compact.FocusMetric | Should -BeExactly 'Auto'
    }

    It 'returns the versioned visible topmost startup defaults' {
        $settings = New-DefaultSettings

        $settings.SchemaVersion | Should -Be 2
        $settings.Window.Full.Left | Should -BeNullOrEmpty
        $settings.Window.Full.Top | Should -BeNullOrEmpty
        $settings.Window.Full.Topmost | Should -BeTrue
        $settings.Window.Full.Visible | Should -BeTrue
        $settings.Startup | Should -BeTrue
    }

    It 'returns a fresh independent settings graph on every call' {
        $first = New-DefaultSettings
        $first.Window.Full['Topmost'] = $false
        $first['Startup'] = $false

        $second = New-DefaultSettings

        $second.Window.Full.Topmost | Should -BeTrue
        $second.Startup | Should -BeTrue
    }
}

Describe 'monitor settings persistence' {
    It 'migrates schema 1 without losing the existing window preference' {
        $path = Join-Path $TestDrive 'migration\settings.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText(
            $path,
            '{"SchemaVersion":1,"Window":{"Left":12.5,"Top":-8,"Topmost":false,"Visible":false},"Startup":false}',
            [Text.UTF8Encoding]::new($false)
        )

        $settings = Read-MonitorSettings -Path $path

        $settings.SchemaVersion | Should -Be 2
        $settings.Window.Full.Left | Should -Be 12.5
        $settings.Window.Full.Top | Should -Be -8
        $settings.Window.Full.Topmost | Should -BeFalse
        $settings.Window.Full.Visible | Should -BeFalse
        $settings.Startup | Should -BeFalse
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).SchemaVersion | Should -Be 2
    }

    It 'returns fresh defaults when the settings file is missing' {
        $path = Join-Path $TestDrive 'missing\settings.json'

        $first = Read-MonitorSettings -Path $path
        $first.Window.Full['Visible'] = $false
        $second = Read-MonitorSettings -Path $path

        $second.Window.Full.Visible | Should -BeTrue
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'atomically round-trips settings types and leaves no sibling temp file' {
        $path = Join-Path $TestDrive 'round-trip\data\settings.json'
        $settings = New-DefaultSettings
        $settings.Window.Full['Left'] = [double]-123.5
        $settings.Window.Full['Top'] = [long]72
        $settings.Window.Full['Topmost'] = $false
        $settings.Window.Full['Visible'] = $false
        $settings['Startup'] = $false

        Write-MonitorSettings -Path $path -Settings $settings

        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $loaded = Read-MonitorSettings -Path $path
        $loaded.Window.Full.Left | Should -Be -123.5
        $loaded.Window.Full.Left | Should -BeOfType ([double])
        $loaded.Window.Full.Top | Should -Be 72
        $loaded.Window.Full.Top | Should -BeOfType ([double])
        $loaded.Window.Full.Topmost | Should -BeFalse
        $loaded.Window.Full.Topmost | Should -BeOfType ([bool])
        $loaded.Window.Full.Visible | Should -BeFalse
        $loaded.Window.Full.Visible | Should -BeOfType ([bool])
        $loaded.Startup | Should -BeFalse
        $loaded.Startup | Should -BeOfType ([bool])
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -File -Filter '*.tmp').Count | Should -Be 0
    }

    It 'replaces an existing settings file with the complete new document' {
        $path = Join-Path $TestDrive 'replace\data\settings.json'
        $first = New-DefaultSettings
        $first.Window.Full['Left'] = [long]10
        Write-MonitorSettings -Path $path -Settings $first

        $second = New-DefaultSettings
        $second.Window.Full['Left'] = [long]900
        $second.Window.Full['Top'] = [long]-40
        $second.Window.Full['Topmost'] = $false
        Write-MonitorSettings -Path $path -Settings $second

        $loaded = Read-MonitorSettings -Path $path
        $loaded.Window.Full.Left | Should -Be 900
        $loaded.Window.Full.Top | Should -Be -40
        $loaded.Window.Full.Topmost | Should -BeFalse
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Window.Full.Left | Should -Be 900
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -File -Filter '*.tmp').Count | Should -Be 0
    }

    It 'cleans its unique sibling temp file when the atomic move fails' {
        $parent = Join-Path $TestDrive 'failed-save\data'
        $path = Join-Path $parent 'settings.json'
        New-Item -ItemType Directory -Path $path -Force | Out-Null

        Get-Command Write-MonitorSettings -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        { Write-MonitorSettings -Path $path -Settings (New-DefaultSettings) } | Should -Throw

        Test-Path -LiteralPath $path -PathType Container | Should -BeTrue
        @(Get-ChildItem -LiteralPath $parent -File -Filter '*.tmp').Count | Should -Be 0
    }

    It 'renames malformed JSON with the injected safe UTC timestamp and returns defaults' {
        $path = Join-Path $TestDrive 'corrupt\data\settings.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        $evidence = '{ definitely-not-json'
        [IO.File]::WriteAllText($path, $evidence, [Text.UTF8Encoding]::new($false))
        $now = [DateTimeOffset]'2026-07-14T09:02:03.456+08:00'

        $settings = Read-MonitorSettings -Path $path -Now $now

        $renamed = "$path.corrupt-20260714T010203456Z"
        Test-Path -LiteralPath $path | Should -BeFalse
        Test-Path -LiteralPath $renamed -PathType Leaf | Should -BeTrue
        [IO.File]::ReadAllText($renamed) | Should -BeExactly $evidence
        $settings.Window.Full.Topmost | Should -BeTrue
        $settings.Window.Full.Visible | Should -BeTrue
        $settings.Startup | Should -BeTrue
    }

    It 'treats valid JSON with an invalid settings shape as corrupt' -ForEach @(
        @{ Name = 'null'; Json = 'null' }
        @{ Name = 'scalar'; Json = '42' }
        @{ Name = 'array'; Json = '[]' }
        @{ Name = 'missing-window'; Json = '{"SchemaVersion":1,"Startup":true}' }
        @{ Name = 'wrong-version'; Json = '{"SchemaVersion":2,"Window":{"Left":null,"Top":null,"Topmost":true,"Visible":true},"Startup":true}' }
        @{ Name = 'wrong-types'; Json = '{"SchemaVersion":1,"Window":{"Left":"20","Top":null,"Topmost":"true","Visible":true},"Startup":true}' }
    ) {
        $path = Join-Path $TestDrive "$Name\settings.json"
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, $Json, [Text.UTF8Encoding]::new($false))

        $settings = Read-MonitorSettings -Path $path -Now ([DateTimeOffset]'2026-07-14T00:00:00Z')

        Test-Path -LiteralPath $path | Should -BeFalse
        Test-Path -LiteralPath "$path.corrupt-20260714T000000000Z" -PathType Leaf | Should -BeTrue
        $settings.Window.Full.Topmost | Should -BeTrue
        $settings.Window.Full.Visible | Should -BeTrue
    }

    It 'never overwrites earlier corrupt evidence when timestamps collide' {
        $path = Join-Path $TestDrive 'collision\settings.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        $existingEvidence = "$path.corrupt-20260714T000000000Z"
        [IO.File]::WriteAllText($existingEvidence, 'older evidence', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($path, 'newer broken evidence', [Text.UTF8Encoding]::new($false))

        $null = Read-MonitorSettings -Path $path -Now ([DateTimeOffset]'2026-07-14T00:00:00Z')

        [IO.File]::ReadAllText($existingEvidence) | Should -BeExactly 'older evidence'
        [IO.File]::ReadAllText("$existingEvidence.1") | Should -BeExactly 'newer broken evidence'
    }

    It 'preserves empty and single-item collection identity in the raw field accessor' -ForEach @(
        @{ Name = 'empty'; Value = [object[]]@(); ExpectedCount = 0 }
        @{ Name = 'single'; Value = [object[]]@(1); ExpectedCount = 1 }
    ) {
        $document = [ordered]@{ Field = $Value }

        $actual = Get-MonitorSettingsField -InputObject $document -Name 'Field'

        [object]::ReferenceEquals($actual, $Value) | Should -BeTrue
        $actual.GetType() | Should -Be ([object[]])
        $actual.Count | Should -Be $ExpectedCount
    }

    It 'quarantines arrays in every scalar JSON setting without collapsing them' -ForEach @(
        @{ Name = 'schema-single'; Json = '{"SchemaVersion":[1],"Window":{"Left":null,"Top":null,"Topmost":true,"Visible":true},"Startup":true}' }
        @{ Name = 'schema-empty'; Json = '{"SchemaVersion":[],"Window":{"Left":null,"Top":null,"Topmost":true,"Visible":true},"Startup":true}' }
        @{ Name = 'left-single'; Json = '{"SchemaVersion":1,"Window":{"Left":[20],"Top":null,"Topmost":true,"Visible":true},"Startup":true}' }
        @{ Name = 'top-empty'; Json = '{"SchemaVersion":1,"Window":{"Left":null,"Top":[],"Topmost":true,"Visible":true},"Startup":true}' }
        @{ Name = 'topmost-single'; Json = '{"SchemaVersion":1,"Window":{"Left":null,"Top":null,"Topmost":[true],"Visible":true},"Startup":true}' }
        @{ Name = 'visible-empty'; Json = '{"SchemaVersion":1,"Window":{"Left":null,"Top":null,"Topmost":true,"Visible":[]},"Startup":true}' }
        @{ Name = 'startup-single'; Json = '{"SchemaVersion":1,"Window":{"Left":null,"Top":null,"Topmost":true,"Visible":true},"Startup":[true]}' }
    ) {
        $path = Join-Path $TestDrive "array-$Name\settings.json"
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, $Json, [Text.UTF8Encoding]::new($false))

        $settings = Read-MonitorSettings -Path $path -Now ([DateTimeOffset]'2026-07-14T00:00:00Z')

        Test-Path -LiteralPath $path | Should -BeFalse
        Test-Path -LiteralPath "$path.corrupt-20260714T000000000Z" -PathType Leaf | Should -BeTrue
        $settings.Window.Full.Topmost | Should -BeTrue
    }

    It 'rejects Boolean, string, and nonintegral schema coercions' -ForEach @(
        @{ Name = 'schema-boolean'; Json = '{"SchemaVersion":true,"Window":{"Left":null,"Top":null,"Topmost":true,"Visible":true},"Startup":true}' }
        @{ Name = 'schema-string'; Json = '{"SchemaVersion":"1","Window":{"Left":null,"Top":null,"Topmost":true,"Visible":true},"Startup":true}' }
        @{ Name = 'schema-double'; Json = '{"SchemaVersion":1.0,"Window":{"Left":null,"Top":null,"Topmost":true,"Visible":true},"Startup":true}' }
        @{ Name = 'left-boolean'; Json = '{"SchemaVersion":1,"Window":{"Left":true,"Top":null,"Topmost":true,"Visible":true},"Startup":true}' }
        @{ Name = 'top-string'; Json = '{"SchemaVersion":1,"Window":{"Left":null,"Top":"20","Topmost":true,"Visible":true},"Startup":true}' }
        @{ Name = 'topmost-number'; Json = '{"SchemaVersion":1,"Window":{"Left":null,"Top":null,"Topmost":1,"Visible":true},"Startup":true}' }
        @{ Name = 'visible-string'; Json = '{"SchemaVersion":1,"Window":{"Left":null,"Top":null,"Topmost":true,"Visible":"true"},"Startup":true}' }
        @{ Name = 'startup-number'; Json = '{"SchemaVersion":1,"Window":{"Left":null,"Top":null,"Topmost":true,"Visible":true},"Startup":1}' }
    ) {
        $path = Join-Path $TestDrive "coercion-$Name\settings.json"
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, $Json, [Text.UTF8Encoding]::new($false))

        $null = Read-MonitorSettings -Path $path -Now ([DateTimeOffset]'2026-07-14T00:00:00Z')

        Test-Path -LiteralPath $path | Should -BeFalse
        Test-Path -LiteralPath "$path.corrupt-20260714T000000000Z" -PathType Leaf | Should -BeTrue
    }

    It 'rejects programmatic collections in every scalar setting before writing' -ForEach @(
        @{ Name = 'schema'; Field = 'SchemaVersion'; Value = [object[]]@(1) }
        @{ Name = 'left'; Field = 'Left'; Value = [Collections.ArrayList]@(20) }
        @{ Name = 'top'; Field = 'Top'; Value = [Collections.Generic.List[int]]@(30) }
        @{ Name = 'topmost'; Field = 'Topmost'; Value = [object[]]@($true) }
        @{ Name = 'visible'; Field = 'Visible'; Value = [object[]]@() }
        @{ Name = 'startup'; Field = 'Startup'; Value = [object[]]@($true) }
    ) {
        $path = Join-Path $TestDrive "write-collection-$Name\settings.json"
        $settings = New-DefaultSettings
        if ($Field -eq 'SchemaVersion' -or $Field -eq 'Startup') {
            $settings[$Field] = $Value
        }
        else {
            $settings.Window.Full[$Field] = $Value
        }

        { Write-MonitorSettings -Path $path -Settings $settings } |
            Should -Throw -ExpectedMessage 'Settings do not match the supported schema.'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'returns and rewrites only canonical allowlisted fields from valid JSON' {
        $path = Join-Path $TestDrive 'canonical-read\settings.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        $tokenSentinel = 'token-sentinel-must-disappear'
        $emailSentinel = 'email-sentinel@example.invalid'
        $json = '{"SchemaVersion":1,"accessToken":"' + $tokenSentinel + '","Window":{"Left":20,"Top":30,"Topmost":false,"Visible":true,"Email":"' + $emailSentinel + '"},"Startup":false,"Future":{"Value":1}}'
        [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))

        $settings = Read-MonitorSettings -Path $path
        $returned = $settings | ConvertTo-Json -Depth 5 -Compress
        $persisted = [IO.File]::ReadAllText($path)
        $fileObject = $persisted | ConvertFrom-Json

        ($fileObject.PSObject.Properties.Name -join ',') | Should -BeExactly 'SchemaVersion,Appearance,Window,Compact,Startup'
        ($fileObject.Window.PSObject.Properties.Name -join ',') | Should -BeExactly 'Full,CompactBar,Orb'
        ($fileObject.Window.Full.PSObject.Properties.Name -join ',') |
            Should -BeExactly 'Left,Top,Width,Height,Topmost,Visible'
        $returned | Should -Not -Match ([regex]::Escape($tokenSentinel))
        $returned | Should -Not -Match ([regex]::Escape($emailSentinel))
        $persisted | Should -Not -Match ([regex]::Escape($tokenSentinel))
        $persisted | Should -Not -Match ([regex]::Escape($emailSentinel))
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -File -Filter '*.corrupt-*').Count | Should -Be 0
    }

    It 'persists only canonical allowlisted fields from a caller document' {
        $path = Join-Path $TestDrive 'canonical-write\settings.json'
        $settings = New-DefaultSettings
        $settings['accessToken'] = 'caller-token-sentinel'
        $settings['Future'] = [ordered]@{ Value = 1 }
        $settings.Window['Email'] = 'caller-email-sentinel@example.invalid'

        Write-MonitorSettings -Path $path -Settings $settings

        $persisted = [IO.File]::ReadAllText($path)
        $fileObject = $persisted | ConvertFrom-Json
        ($fileObject.PSObject.Properties.Name -join ',') | Should -BeExactly 'SchemaVersion,Appearance,Window,Compact,Startup'
        ($fileObject.Window.PSObject.Properties.Name -join ',') | Should -BeExactly 'Full,CompactBar,Orb'
        ($fileObject.Window.Full.PSObject.Properties.Name -join ',') |
            Should -BeExactly 'Left,Top,Width,Height,Topmost,Visible'
        $persisted | Should -Not -Match 'caller-token-sentinel|caller-email-sentinel'
    }

    It 'derives one stable path-scoped Local mutex name from normalized paths' {
        $path = Join-Path $TestDrive 'mutex-name\settings.json'
        $relativePath = [IO.Path]::GetRelativePath((Get-Location).Path, $path)

        $absoluteName = Get-MonitorSettingsMutexName -Path $path
        $relativeName = Get-MonitorSettingsMutexName -Path $relativePath

        $absoluteName | Should -BeExactly $relativeName
        $absoluteName | Should -Match '^Local\\CodexQuotaMonitor\.Settings\.[0-9A-F]{64}$'
        $absoluteName | Should -Not -Match ([regex]::Escape($path))
    }

    It 'holds a writer behind the path mutex until the owner releases it' {
        $path = Join-Path $TestDrive 'mutex-block\settings.json'
        $mutex = [Threading.Mutex]::new($false, (Get-MonitorSettingsMutexName -Path $path))
        $started = [Threading.ManualResetEventSlim]::new($false)
        $job = $null
        $ownsMutex = $false
        try {
            $ownsMutex = $mutex.WaitOne(1000)
            $ownsMutex | Should -BeTrue
            $job = Start-ThreadJob -ArgumentList $settingsScript, $path, $started -ScriptBlock {
                param($ScriptPath, $SettingsPath, $StartedEvent)
                . $ScriptPath
                $settings = New-DefaultSettings
                $settings.Window.Full['Left'] = [long]123
                $StartedEvent.Set()
                Write-MonitorSettings -Path $SettingsPath -Settings $settings
            }
            $started.Wait(5000) | Should -BeTrue
            Start-Sleep -Milliseconds 150

            $job.State | Should -Be 'Running'
            Test-Path -LiteralPath $path | Should -BeFalse
        }
        finally {
            if ($ownsMutex) {
                $mutex.ReleaseMutex()
            }
            $mutex.Dispose()
            $started.Dispose()
        }

        $null = Wait-Job -Job $job -Timeout 10
        $job.State | Should -Be 'Completed'
        Receive-Job -Job $job -ErrorAction Stop | Out-Null
        Remove-Job -Job $job -Force
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Window.Full.Left | Should -Be 123
    }

    It 'times out with a constant sanitized error while another thread owns the mutex' {
        $path = Join-Path $TestDrive 'mutex-timeout\settings.json'
        $mutex = [Threading.Mutex]::new($false, (Get-MonitorSettingsMutexName -Path $path))
        $ownsMutex = $mutex.WaitOne(1000)
        $job = $null
        try {
            $job = Start-ThreadJob -ArgumentList $settingsScript, $path -ScriptBlock {
                param($ScriptPath, $SettingsPath)
                . $ScriptPath
                try {
                    $acquired = Enter-MonitorSettingsMutex -Path $SettingsPath -TimeoutMilliseconds 75
                    try { 'unexpectedly acquired' } finally { Exit-MonitorSettingsMutex -Mutex $acquired }
                }
                catch {
                    $_.Exception.Message
                }
            }
            $null = Wait-Job -Job $job -Timeout 5
            $message = Receive-Job -Job $job -ErrorAction Stop

            $message | Should -BeExactly 'Timed out waiting for monitor settings persistence.'
            $message | Should -Not -Match ([regex]::Escape($path))
        }
        finally {
            if ($ownsMutex) {
                $mutex.ReleaseMutex()
            }
            $mutex.Dispose()
            if ($null -ne $job) {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'treats an abandoned path mutex as acquired and remains usable' {
        $path = Join-Path $TestDrive 'abandoned\settings.json'
        $mutexName = Get-MonitorSettingsMutexName -Path $path
        $observer = [Threading.Mutex]::new($false, $mutexName)
        $holderScript = Join-Path $TestDrive 'abandon-mutex.ps1'
        [IO.File]::WriteAllText($holderScript, @'
param([string]$Name)
$mutex = [Threading.Mutex]::new($false, $Name)
$null = $mutex.WaitOne()
[Environment]::Exit(0)
'@, [Text.UTF8Encoding]::new($false))
        try {
            & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -File $holderScript $mutexName
            $LASTEXITCODE | Should -Be 0

            $acquired = Enter-MonitorSettingsMutex -Path $path -TimeoutMilliseconds 1000
            try {
                $acquired | Should -BeOfType ([Threading.Mutex])
            }
            finally {
                Exit-MonitorSettingsMutex -Mutex $acquired
            }
        }
        finally {
            $observer.Dispose()
        }
    }

    It 'serializes concurrent first writes and replacements into complete canonical documents' {
        $path = Join-Path $TestDrive 'concurrent\settings.json'
        foreach ($wave in 0..1) {
            $count = 4
            $ready = [Threading.CountdownEvent]::new($count)
            $gate = [Threading.ManualResetEventSlim]::new($false)
            $jobs = @()
            try {
                foreach ($index in 0..($count - 1)) {
                    $jobs += Start-ThreadJob -ArgumentList $settingsScript, $path, $wave, $index, $ready, $gate -ScriptBlock {
                        param($ScriptPath, $SettingsPath, $Wave, $Index, $ReadyEvent, $GateEvent)
                        . $ScriptPath
                        $settings = New-DefaultSettings
                        $settings.Window.Full['Left'] = [long](($Wave * 100) + $Index)
                        $settings.Window.Full['Top'] = [long](-$Index)
                        $settings['Future'] = 'must-not-persist'
                        $ReadyEvent.Signal()
                        if (-not $GateEvent.Wait(5000)) {
                            throw 'Writer gate timed out.'
                        }
                        Write-MonitorSettings -Path $SettingsPath -Settings $settings
                    }
                }

                $ready.Wait(10000) | Should -BeTrue
                $gate.Set()
                $completed = @(Wait-Job -Job $jobs -Timeout 15)
                $completed.Count | Should -Be $count
                @($jobs | Where-Object State -NE 'Completed').Count | Should -Be 0
                foreach ($job in $jobs) {
                    Receive-Job -Job $job -ErrorAction Stop | Out-Null
                }
            }
            finally {
                $gate.Set()
                $jobs | Stop-Job -ErrorAction SilentlyContinue
                $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
                $ready.Dispose()
                $gate.Dispose()
            }
        }

        $persisted = [IO.File]::ReadAllText($path)
        $fileObject = $persisted | ConvertFrom-Json
        $fileObject.Window.Full.Left | Should -BeIn (100..103)
        ($fileObject.PSObject.Properties.Name -join ',') | Should -BeExactly 'SchemaVersion,Appearance,Window,Compact,Startup'
        ($fileObject.Window.PSObject.Properties.Name -join ',') | Should -BeExactly 'Full,CompactBar,Orb'
        $persisted | Should -Not -Match 'must-not-persist'
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -File -Filter '*.tmp').Count | Should -Be 0
    }

    It 'does not let a racing reader quarantine a newly committed valid writer document' {
        $path = Join-Path $TestDrive 'reader-writer-race\settings.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        $corruptEvidence = '{ original corrupt evidence'
        [IO.File]::WriteAllText($path, $corruptEvidence, [Text.UTF8Encoding]::new($false))
        $writerReady = [Threading.ManualResetEventSlim]::new($false)
        $writerGate = [Threading.ManualResetEventSlim]::new($false)
        $writerDone = [Threading.ManualResetEventSlim]::new($false)
        $script:ReaderRaceWriterGate = $writerGate
        $script:ReaderRaceWriterDone = $writerDone
        $script:WriterFinishedDuringParse = $null
        $job = Start-ThreadJob -ArgumentList $settingsScript, $path, $writerReady, $writerGate, $writerDone -ScriptBlock {
            param($ScriptPath, $SettingsPath, $ReadyEvent, $GateEvent, $DoneEvent)
            . $ScriptPath
            $ReadyEvent.Set()
            $null = $GateEvent.Wait(5000)
            try {
                $settings = New-DefaultSettings
                $settings.Window.Full['Left'] = [long]777
                Write-MonitorSettings -Path $SettingsPath -Settings $settings
            }
            finally {
                $DoneEvent.Set()
            }
        }
        try {
            $writerReady.Wait(5000) | Should -BeTrue
            Mock ConvertFrom-Json {
                $script:ReaderRaceWriterGate.Set()
                $script:WriterFinishedDuringParse = $script:ReaderRaceWriterDone.Wait(500)
                throw [FormatException]::new('Synthetic invalid JSON.')
            }

            $settings = Read-MonitorSettings -Path $path -Now ([DateTimeOffset]'2026-07-14T00:00:00Z')
            $null = Wait-Job -Job $job -Timeout 10
            Receive-Job -Job $job -ErrorAction Stop | Out-Null

            $script:WriterFinishedDuringParse | Should -BeFalse
            $settings.Window.Full.Topmost | Should -BeTrue
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
            [IO.File]::ReadAllText($path) | Should -Match '"Left":777'
            [IO.File]::ReadAllText("$path.corrupt-20260714T000000000Z") | Should -BeExactly $corruptEvidence
        }
        finally {
            $writerGate.Set()
            $job | Stop-Job -ErrorAction SilentlyContinue
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
            $writerReady.Dispose()
            $writerGate.Dispose()
            $writerDone.Dispose()
            Remove-Variable ReaderRaceWriterGate, ReaderRaceWriterDone, WriterFinishedDuringParse -Scope Script -ErrorAction SilentlyContinue
        }
    }

    It 'never creates a replacement backup containing fields removed by canonicalization' {
        $path = Join-Path $TestDrive 'credential-backup\settings.json'
        $directory = Split-Path -Parent $path
        $null = New-Item -ItemType Directory -Path $directory -Force
        $sentinel = 'OLD_CREDENTIAL_SENTINEL_MUST_NOT_SURVIVE'
        $oldDocument = '{"SchemaVersion":1,"accessToken":"' + $sentinel + '","Window":{"Left":1,"Top":2,"Topmost":true,"Visible":true},"Startup":true}'
        [IO.File]::WriteAllText($path, $oldDocument, [Text.UTF8Encoding]::new($false))
        $replacement = New-DefaultSettings
        $replacement.Window.Full['Left'] = [long]2
        Mock Remove-MonitorSettingsArtifactFile { throw [IO.IOException]::new('Synthetic cleanup failure.') }

        { Write-MonitorSettings -Path $path -Settings $replacement } | Should -Not -Throw

        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Window.Full.Left | Should -Be 2
        Should -Invoke Remove-MonitorSettingsArtifactFile -Times 0 -Exactly
        $files = @(Get-ChildItem -LiteralPath $directory -File)
        $files.Name | Should -Be @('settings.json')
        $persisted = @($files | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $persisted | Should -Not -Match ([regex]::Escape($sentinel))
    }

    It 'keeps existing bytes and removes staged artifacts when overwrite is blocked by a real file lock' {
        $path = Join-Path $TestDrive 'locked-overwrite\settings.json'
        $first = New-DefaultSettings
        $first.Window.Full['Left'] = [long]11
        Write-MonitorSettings -Path $path -Settings $first
        $before = [IO.File]::ReadAllBytes($path)
        $second = New-DefaultSettings
        $second.Window.Full['Left'] = [long]22
        $lock = [IO.FileStream]::new(
            $path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::None
        )
        try {
            { Write-MonitorSettings -Path $path -Settings $second } | Should -Throw
        }
        finally {
            $lock.Dispose()
        }

        [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) |
            Should -BeExactly ([Convert]::ToBase64String($before))
        $files = @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -File)
        $files.Name | Should -Be @('settings.json')
        @($files.Name | Where-Object { $_ -match '\.(tmp|backup)' }).Count | Should -Be 0
    }

    It 'preserves the existing target ACL across replacement on Windows when supported' {
        $path = Join-Path $TestDrive 'acl\settings.json'
        $first = New-DefaultSettings
        Write-MonitorSettings -Path $path -Settings $first
        try {
            $acl = Get-Acl -LiteralPath $path
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                $identity,
                [Security.AccessControl.FileSystemRights]::ReadAttributes,
                [Security.AccessControl.AccessControlType]::Allow
            )
            $null = $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $path -AclObject $acl
            $before = (Get-Acl -LiteralPath $path).Sddl
        }
        catch {
            Set-ItResult -Skipped -Because "ACL setup is unavailable: $($_.Exception.GetType().Name)"
            return
        }

        $second = New-DefaultSettings
        $second.Window.Full['Left'] = [long]55
        Write-MonitorSettings -Path $path -Settings $second

        (Get-Acl -LiteralPath $path).Sddl | Should -BeExactly $before
    }
}
