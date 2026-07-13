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
        $paths.StartupShortcut | Should -BeExactly (Join-Path $startup 'Codex Quota Monitor.lnk')
    }
}

Describe 'New-DefaultSettings' {
    It 'returns the versioned visible topmost startup defaults' {
        $settings = New-DefaultSettings

        $settings.SchemaVersion | Should -Be 1
        $settings.Window.Left | Should -BeNullOrEmpty
        $settings.Window.Top | Should -BeNullOrEmpty
        $settings.Window.Topmost | Should -BeTrue
        $settings.Window.Visible | Should -BeTrue
        $settings.Startup | Should -BeTrue
    }

    It 'returns a fresh independent settings graph on every call' {
        $first = New-DefaultSettings
        $first.Window['Topmost'] = $false
        $first['Startup'] = $false

        $second = New-DefaultSettings

        $second.Window.Topmost | Should -BeTrue
        $second.Startup | Should -BeTrue
    }
}

Describe 'monitor settings persistence' {
    It 'returns fresh defaults when the settings file is missing' {
        $path = Join-Path $TestDrive 'missing\settings.json'

        $first = Read-MonitorSettings -Path $path
        $first.Window['Visible'] = $false
        $second = Read-MonitorSettings -Path $path

        $second.Window.Visible | Should -BeTrue
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'atomically round-trips settings types and leaves no sibling temp file' {
        $path = Join-Path $TestDrive 'round-trip\data\settings.json'
        $settings = New-DefaultSettings
        $settings.Window['Left'] = [double]-123.5
        $settings.Window['Top'] = [long]72
        $settings.Window['Topmost'] = $false
        $settings.Window['Visible'] = $false
        $settings['Startup'] = $false

        Write-MonitorSettings -Path $path -Settings $settings

        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $loaded = Read-MonitorSettings -Path $path
        $loaded.Window.Left | Should -Be -123.5
        $loaded.Window.Left | Should -BeOfType ([double])
        $loaded.Window.Top | Should -Be 72
        $loaded.Window.Top | Should -BeOfType ([long])
        $loaded.Window.Topmost | Should -BeFalse
        $loaded.Window.Topmost | Should -BeOfType ([bool])
        $loaded.Window.Visible | Should -BeFalse
        $loaded.Window.Visible | Should -BeOfType ([bool])
        $loaded.Startup | Should -BeFalse
        $loaded.Startup | Should -BeOfType ([bool])
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -File -Filter '*.tmp').Count | Should -Be 0
    }

    It 'replaces an existing settings file with the complete new document' {
        $path = Join-Path $TestDrive 'replace\data\settings.json'
        $first = New-DefaultSettings
        $first.Window['Left'] = [long]10
        Write-MonitorSettings -Path $path -Settings $first

        $second = New-DefaultSettings
        $second.Window['Left'] = [long]900
        $second.Window['Top'] = [long]-40
        $second.Window['Topmost'] = $false
        Write-MonitorSettings -Path $path -Settings $second

        $loaded = Read-MonitorSettings -Path $path
        $loaded.Window.Left | Should -Be 900
        $loaded.Window.Top | Should -Be -40
        $loaded.Window.Topmost | Should -BeFalse
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Window.Left | Should -Be 900
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
        $settings.Window.Topmost | Should -BeTrue
        $settings.Window.Visible | Should -BeTrue
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
        $settings.Window.Topmost | Should -BeTrue
        $settings.Window.Visible | Should -BeTrue
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
}
