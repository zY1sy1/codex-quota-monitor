BeforeAll {
    $script:CompanionRoot = Join-Path $PSScriptRoot '..\..\companion'
    $script:ManifestPath = Join-Path $script:CompanionRoot 'CodexQuotaMonitor.psd1'
    $script:FakeMonitorInstancePath = Join-Path $PSScriptRoot '..\Fixtures\FakeMonitorInstance.ps1'
    $script:MonitorModule = Import-Module -Name $script:ManifestPath -Force -PassThru
    $script:PublicCommands = @(
        'Install-CodexQuotaMonitor'
        'Repair-CodexQuotaMonitor'
        'Uninstall-CodexQuotaMonitor'
        'Start-CodexQuotaMonitor'
        'Stop-CodexQuotaMonitor'
        'Get-CodexQuotaMonitorStatus'
        'Test-CodexQuotaMonitorHealth'
    )

    function New-InstallationTestContext {
        param([Parameter(Mandatory)][string]$Name)

        $localAppData = Join-Path $TestDrive "$Name LocalAppData"
        $startup = Join-Path $TestDrive "$Name Startup"
        New-Item -ItemType Directory -Path $localAppData, $startup -Force | Out-Null
        [pscustomobject]@{
            LocalAppData = $localAppData
            Startup = $startup
            Root = Join-Path $localAppData 'CodexQuotaMonitor'
            App = Join-Path $localAppData 'CodexQuotaMonitor\app'
            Data = Join-Path $localAppData 'CodexQuotaMonitor\data'
            Logs = Join-Path $localAppData 'CodexQuotaMonitor\logs'
            Settings = Join-Path $localAppData 'CodexQuotaMonitor\data\settings.json'
            Health = Join-Path $localAppData 'CodexQuotaMonitor\data\health.json'
            Shortcut = Join-Path $startup 'Codex Quota Monitor.lnk'
            Prefix = 'Local\CodexQuotaMonitor.InstallationTest.' + [guid]::NewGuid().ToString('N')
        }
    }

    function Get-RelativeFileSet {
        param(
            [Parameter(Mandatory)][string]$Root
        )

        @(
            Get-ChildItem -LiteralPath $Root -Recurse -File |
                ForEach-Object {
                    $_.FullName.Substring($Root.Length).TrimStart('\', '/')
                } |
                Sort-Object
        )
    }

    function Start-FakeMonitorInstance {
        param(
            [Parameter(Mandatory)][object]$Paths,
            [Parameter(Mandatory)][string]$Prefix,
            [Parameter(Mandatory)][string]$ReadyPath
        )

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Process -Id $PID).Path
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        foreach ($argument in @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
                $script:FakeMonitorInstancePath,
                '-Prefix', $Prefix,
                '-SingleInstancePath', (Join-Path $Paths.App 'Private\SingleInstance.ps1'),
                '-ReadyPath', $ReadyPath
            )) {
            $startInfo.ArgumentList.Add([string]$argument)
        }
        $process = [Diagnostics.Process]::Start($startInfo)
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
        $waiter = [Threading.ManualResetEventSlim]::new($false)
        try {
            while (-not (Test-Path -LiteralPath $ReadyPath -PathType Leaf)) {
                if ($process.HasExited -or [DateTimeOffset]::UtcNow -ge $deadline) {
                    try { if (-not $process.HasExited) { $process.Kill($true) } } catch { }
                    $process.Dispose()
                    throw 'Fake monitor instance did not become ready.'
                }
                $null = $waiter.Wait(20)
            }
        }
        finally {
            $waiter.Dispose()
        }
        return $process
    }
}

AfterAll {
    Remove-Module -ModuleInfo $script:MonitorModule -Force -ErrorAction SilentlyContinue
}

Describe 'Codex quota monitor installation lifecycle' {
    It 'imports exactly the seven declared management commands' {
        $actual = @(
            Get-Command -Module $MonitorModule.Name -CommandType Function |
                Select-Object -ExpandProperty Name |
                Sort-Object
        )
        $actual | Should -Be ($PublicCommands | Sort-Object)
    }

    It 'installs idempotently with the same app file set and one current-user shortcut' {
        $context = New-InstallationTestContext -Name 'Idempotent'

        $first = Install-CodexQuotaMonitor `
            -SourcePath $CompanionRoot `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix `
            -SkipStart
        $firstFiles = Get-RelativeFileSet -Root $context.App

        $second = Install-CodexQuotaMonitor `
            -SourcePath $CompanionRoot `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix `
            -SkipStart
        $secondFiles = Get-RelativeFileSet -Root $context.App

        $first.Operation | Should -BeExactly 'Install'
        $second.Operation | Should -BeExactly 'Install'
        $firstFiles.Count | Should -BeGreaterThan 10
        $secondFiles | Should -Be $firstFiles
        foreach ($relativePath in @(
                'Bin\relay-quota-host.exe'
                'Bin\relay-quota-host.sha256'
                'Presets\relay-usage.json'
                'ThirdPartyNotices.txt'
            )) {
            Test-Path -LiteralPath (Join-Path $context.App $relativePath) -PathType Leaf |
                Should -BeTrue
        }
        Test-Path -LiteralPath $context.Settings -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $context.Shortcut -PathType Leaf | Should -BeTrue
        @(Get-ChildItem -LiteralPath $context.Startup -Filter '*.lnk' -File).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $context.Root 'app.new') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $context.Root 'app.old') | Should -BeFalse
    }

    It 'rejects missing or mismatched packaged relay host artifacts before publishing' {
        $context = New-InstallationTestContext -Name 'Source Integrity'
        $source = Join-Path $TestDrive 'Incomplete Source'
        Copy-Item -LiteralPath $CompanionRoot -Destination $source -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $source 'Bin\relay-quota-host.sha256') -Force

        {
            Install-CodexQuotaMonitor `
                -SourcePath $source `
                -LocalAppData $context.LocalAppData `
                -Startup $context.Startup `
                -InstancePrefix $context.Prefix `
                -SkipStart
        } | Should -Throw '*source directory is incomplete*'

        Copy-Item -LiteralPath $CompanionRoot -Destination $source -Recurse -Force
        [IO.File]::WriteAllText(
            (Join-Path $source 'Bin\relay-quota-host.sha256'),
            ('0' * 64) + "`n",
            [Text.UTF8Encoding]::new($false)
        )

        {
            Install-CodexQuotaMonitor `
                -SourcePath $source `
                -LocalAppData $context.LocalAppData `
                -Startup $context.Startup `
                -InstancePrefix $context.Prefix `
                -SkipStart
        } | Should -Throw '*integrity check failed*'
    }

    It 'repairs app files while preserving canonical settings and log bytes' {
        $context = New-InstallationTestContext -Name 'Repair'
        $null = Install-CodexQuotaMonitor `
            -SourcePath $CompanionRoot `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix `
            -SkipStart

        & $MonitorModule {
            param($SettingsPath)
            $settings = New-DefaultSettings
            $settings.Window.Left = 123.5
            $settings.Window.Top = -45.25
            $settings.Window.Topmost = $false
            $settings.Window.Visible = $false
            $settings.Startup = $false
            Write-MonitorSettings -Path $SettingsPath -Settings $settings
        } $context.Settings
        $logPath = Join-Path $context.Logs 'monitor.log'
        [IO.File]::WriteAllText($logPath, "preserve-log`n", [Text.UTF8Encoding]::new($false))
        $providerPath = Join-Path $context.Data 'relay-providers.json'
        $cachePath = Join-Path $context.Data 'relay-cache.json'
        [IO.File]::WriteAllText($providerPath, '{"SchemaVersion":1,"Providers":[]}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($cachePath, '{"SchemaVersion":1,"Providers":[]}', [Text.UTF8Encoding]::new($false))
        $settingsBefore = [IO.File]::ReadAllBytes($context.Settings)
        $logBefore = [IO.File]::ReadAllBytes($logPath)
        $providerBefore = [IO.File]::ReadAllBytes($providerPath)
        $cacheBefore = [IO.File]::ReadAllBytes($cachePath)
        [IO.File]::WriteAllBytes(
            (Join-Path $context.App 'Bin\relay-quota-host.exe'),
            [byte[]](0x4d, 0x5a, 0x00)
        )
        [IO.File]::WriteAllText(
            (Join-Path $context.App 'Start-CodexQuotaMonitor.ps1'),
            'broken',
            [Text.UTF8Encoding]::new($false)
        )

        $result = Repair-CodexQuotaMonitor `
            -SourcePath $CompanionRoot `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix `
            -SkipStart

        $result.Operation | Should -BeExactly 'Repair'
        [IO.File]::ReadAllBytes($context.Settings) | Should -Be $settingsBefore
        [IO.File]::ReadAllBytes($logPath) | Should -Be $logBefore
        [IO.File]::ReadAllBytes($providerPath) | Should -Be $providerBefore
        [IO.File]::ReadAllBytes($cachePath) | Should -Be $cacheBefore
        (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $context.App 'Bin\relay-quota-host.exe')).Hash |
            Should -BeExactly ([IO.File]::ReadAllText((Join-Path $context.App 'Bin\relay-quota-host.sha256')).Trim())
        [IO.File]::ReadAllText((Join-Path $context.App 'Start-CodexQuotaMonitor.ps1')) |
            Should -Not -BeExactly 'broken'
        Test-Path -LiteralPath $context.Shortcut | Should -BeFalse
    }

    It 'rejects a corrupted installed relay host before starting' {
        $context = New-InstallationTestContext -Name 'Start Integrity'
        $null = Install-CodexQuotaMonitor `
            -SourcePath $CompanionRoot `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix `
            -SkipStart
        [IO.File]::WriteAllBytes(
            (Join-Path $context.App 'Bin\relay-quota-host.exe'),
            [byte[]](0x4d, 0x5a, 0x00)
        )

        {
            Start-CodexQuotaMonitor `
                -LocalAppData $context.LocalAppData `
                -Startup $context.Startup `
                -InstancePrefix $context.Prefix `
                -PwshPath (Get-Process -Id $PID).Path
        } | Should -Throw '*integrity check failed*'

        $running = & $MonitorModule {
            param($Prefix)
            Test-MonitorInstanceRunning -InstancePrefix $Prefix
        } $context.Prefix
        $running | Should -BeFalse
    }

    It 'rolls the previous app and shortcut back when the replacement cannot start' {
        $context = New-InstallationTestContext -Name 'Rollback'
        $null = Install-CodexQuotaMonitor `
            -SourcePath $CompanionRoot `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix `
            -SkipStart
        $marker = Join-Path $context.App 'previous-version.marker'
        [IO.File]::WriteAllText($marker, 'previous')
        $settingsBefore = [IO.File]::ReadAllBytes($context.Settings)
        $failingStarter = {
            param($StartInfo, $Paths, $InstancePrefix)
            [pscustomobject]@{ HasExited = $true }
        }

        {
            Repair-CodexQuotaMonitor `
                -SourcePath $CompanionRoot `
                -LocalAppData $context.LocalAppData `
                -Startup $context.Startup `
                -InstancePrefix $context.Prefix `
                -TimeoutSeconds 1 `
                -ProcessStarter $failingStarter
        } | Should -Throw '*failed and was rolled back*'

        Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
        [IO.File]::ReadAllText($marker) | Should -BeExactly 'previous'
        [IO.File]::ReadAllBytes($context.Settings) | Should -Be $settingsBefore
        Test-Path -LiteralPath $context.Shortcut -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $context.Root 'app.new') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $context.Root 'app.old') | Should -BeFalse
    }

    It 'stops a launched replacement when health waiting times out before rollback' {
        $context = New-InstallationTestContext -Name 'Health Timeout Cleanup'
        $null = Install-CodexQuotaMonitor `
            -SourcePath $CompanionRoot `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix `
            -SkipStart
        $marker = Join-Path $context.App 'previous-version.marker'
        [IO.File]::WriteAllText($marker, 'previous')
        $script:ReplacementPid = $null
        $replacementStarter = {
            param($StartInfo, $Paths, $InstancePrefix)
            $readyPath = Join-Path $Paths.Data 'replacement.ready'
            $process = Start-FakeMonitorInstance `
                -Paths $Paths `
                -Prefix $InstancePrefix `
                -ReadyPath $readyPath
            $script:ReplacementPid = $process.Id
            return $process
        }

        {
            Repair-CodexQuotaMonitor `
                -SourcePath $CompanionRoot `
                -LocalAppData $context.LocalAppData `
                -Startup $context.Startup `
                -InstancePrefix $context.Prefix `
                -TimeoutSeconds 1 `
                -ProcessStarter $replacementStarter
        } | Should -Throw '*failed and was rolled back*'

        $script:ReplacementPid | Should -Not -BeNullOrEmpty
        Get-Process -Id $script:ReplacementPid -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
        Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
    }

    It 'recovers app.old instead of trusting an interrupted replacement' {
        $context = New-InstallationTestContext -Name 'Interrupted Publish'
        $null = Install-CodexQuotaMonitor `
            -SourcePath $CompanionRoot `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix `
            -SkipStart
        $knownGood = Join-Path $context.App 'known-good.marker'
        [IO.File]::WriteAllText($knownGood, 'known-good')
        Move-Item -LiteralPath $context.App -Destination (Join-Path $context.Root 'app.old')
        New-Item -ItemType Directory -Path $context.App -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $context.App 'unverified.marker'), 'unverified')

        & $MonitorModule {
            param($LocalAppData, $Startup)
            $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup
            Repair-MonitorInterruptedPublishState -Paths $paths
        } $context.LocalAppData $context.Startup

        Test-Path -LiteralPath $knownGood -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $context.App 'unverified.marker') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $context.Root 'app.old') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $context.Root 'app.failed') | Should -BeFalse
    }

    It 'does not remove the current app when the rollback backup is missing' {
        $context = New-InstallationTestContext -Name 'Missing Backup'
        New-Item -ItemType Directory -Path $context.Root, $context.App -Force | Out-Null
        $currentMarker = Join-Path $context.App 'current.marker'
        [IO.File]::WriteAllText($currentMarker, 'current')

        {
            & $MonitorModule {
                param($LocalAppData, $Startup)
                $paths = Get-MonitorPaths -LocalAppData $LocalAppData -Startup $Startup
                Restore-MonitorPublishedApplication `
                    -Paths $paths `
                    -PublishState ([pscustomobject]@{
                        Published = $true
                        HadPrevious = $true
                        StagePath = Join-Path $paths.Root 'app.new'
                        BackupPath = Join-Path $paths.Root 'app.old'
                    })
            } $context.LocalAppData $context.Startup
        } | Should -Throw '*backup is unavailable*'

        Test-Path -LiteralPath $currentMarker -PathType Leaf | Should -BeTrue
        [IO.File]::ReadAllText($currentMarker) | Should -BeExactly 'current'
    }

    It 'restarts the previous running version after a failed repair rolls back' {
        $context = New-InstallationTestContext -Name 'Rollback Restart'
        $null = Install-CodexQuotaMonitor `
            -SourcePath $CompanionRoot `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix `
            -SkipStart
        $marker = Join-Path $context.App 'known-good.marker'
        [IO.File]::WriteAllText($marker, 'known-good')
        $oldReady = Join-Path $context.Data 'old.ready'
        $oldProcess = Start-FakeMonitorInstance `
            -Paths $context `
            -Prefix $context.Prefix `
            -ReadyPath $oldReady
        $script:RollbackPid = $null
        $failingStarter = {
            param($StartInfo, $Paths, $InstancePrefix)
            [pscustomobject]@{ HasExited = $true }
        }
        $rollbackStarter = {
            param($StartInfo, $Paths, $InstancePrefix)
            $readyPath = Join-Path $Paths.Data 'rollback.ready'
            $process = Start-FakeMonitorInstance `
                -Paths $Paths `
                -Prefix $InstancePrefix `
                -ReadyPath $readyPath
            $script:RollbackPid = $process.Id
            $health = [ordered]@{
                SchemaVersion = 1
                Status = 'Live'
                PlanType = 'plus'
                QuotaWindowCount = 2
                LastSuccessAt = [DateTimeOffset]::UtcNow.ToString('o')
                LastErrorCategory = $null
                LastErrorMessage = $null
                ProcessId = $process.Id
                UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
            }
            [IO.File]::WriteAllText(
                $Paths.Health,
                ($health | ConvertTo-Json),
                [Text.UTF8Encoding]::new($false)
            )
            return $process
        }

        try {
            {
                Repair-CodexQuotaMonitor `
                    -SourcePath $CompanionRoot `
                    -LocalAppData $context.LocalAppData `
                    -Startup $context.Startup `
                    -InstancePrefix $context.Prefix `
                    -TimeoutSeconds 3 `
                    -ProcessStarter $failingStarter `
                    -RollbackProcessStarter $rollbackStarter
            } | Should -Throw '*failed and was rolled back*'

            $oldProcess.WaitForExit(3000) | Should -BeTrue
            $oldProcess.ExitCode | Should -Be 0
            $script:RollbackPid | Should -Not -BeNullOrEmpty
            Get-Process -Id $script:RollbackPid -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
        }
        finally {
            $null = Stop-CodexQuotaMonitor `
                -LocalAppData $context.LocalAppData `
                -Startup $context.Startup `
                -InstancePrefix $context.Prefix
            if ($null -ne $script:RollbackPid) {
                $deadline = [DateTimeOffset]::UtcNow.AddSeconds(3)
                while ((Get-Process -Id $script:RollbackPid -ErrorAction SilentlyContinue) -and
                    [DateTimeOffset]::UtcNow -lt $deadline) {
                    [Threading.Thread]::Sleep(20)
                }
            }
            $oldProcess.Dispose()
        }
    }

    It 'stops by signalling only the named Exit event' {
        $context = New-InstallationTestContext -Name 'Stop'
        $primary = & $MonitorModule {
            param($Prefix)
            Enter-MonitorInstance -Prefix $Prefix -Signal None
        } $context.Prefix

        try {
            $result = Stop-CodexQuotaMonitor `
                -LocalAppData $context.LocalAppData `
                -Startup $context.Startup `
                -InstancePrefix $context.Prefix

            $result.Operation | Should -BeExactly 'Stop'
            $result.SignalSent | Should -BeTrue
            $primary.ExitEvent.WaitOne(0) | Should -BeTrue
            $primary.ActivateEvent.WaitOne(0) | Should -BeFalse
        }
        finally {
            & $MonitorModule {
                param($Instance)
                Close-MonitorInstance -Instance $Instance
            } $primary
        }
    }

    It 'uninstalls the runtime and shortcut idempotently by default' {
        $context = New-InstallationTestContext -Name 'Uninstall'
        $null = Install-CodexQuotaMonitor `
            -SourcePath $CompanionRoot `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix `
            -SkipStart

        $first = Uninstall-CodexQuotaMonitor `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix
        $second = Uninstall-CodexQuotaMonitor `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix

        $first.Operation | Should -BeExactly 'Uninstall'
        $first.Changed | Should -BeTrue
        $second.Changed | Should -BeFalse
        Test-Path -LiteralPath $context.Root | Should -BeFalse
        Test-Path -LiteralPath $context.Shortcut | Should -BeFalse
    }

    It 'preserves only data and logs when explicitly requested' {
        $context = New-InstallationTestContext -Name 'Preserve'
        $null = Install-CodexQuotaMonitor `
            -SourcePath $CompanionRoot `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix `
            -SkipStart
        $dataMarker = Join-Path $context.Data 'keep.data'
        $logMarker = Join-Path $context.Logs 'keep.log'
        [IO.File]::WriteAllText($dataMarker, 'data')
        [IO.File]::WriteAllText($logMarker, 'log')

        $result = Uninstall-CodexQuotaMonitor `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix `
            -PreserveData

        $result.PreservedData | Should -BeTrue
        @(Get-ChildItem -LiteralPath $context.Root -Force | Select-Object -ExpandProperty Name | Sort-Object) |
            Should -Be @('data', 'logs')
        Test-Path -LiteralPath $dataMarker -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $logMarker -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $context.App | Should -BeFalse
        Test-Path -LiteralPath $context.Shortcut | Should -BeFalse
    }

    It 'returns fixed sanitized status and health projections' {
        $context = New-InstallationTestContext -Name 'Status'
        $null = Install-CodexQuotaMonitor `
            -SourcePath $CompanionRoot `
            -LocalAppData $context.LocalAppData `
            -Startup $context.Startup `
            -InstancePrefix $context.Prefix `
            -SkipStart
        $primary = & $MonitorModule {
            param($Prefix)
            Enter-MonitorInstance -Prefix $Prefix -Signal None
        } $context.Prefix

        try {
            $schemaOneHealth = [ordered]@{
                SchemaVersion = 1
                Status = 'Live'
                PlanType = 'plus'
                QuotaWindowCount = 2
                LastSuccessAt = [DateTimeOffset]::UtcNow.ToString('o')
                LastErrorCategory = $null
                LastErrorMessage = $null
                ProcessId = $PID
                UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
            }
            [IO.File]::WriteAllText(
                $context.Health,
                ($schemaOneHealth | ConvertTo-Json),
                [Text.UTF8Encoding]::new($false)
            )

            $parsedHealth = & $MonitorModule {
                param($HealthPath)
                Read-MonitorHealthSnapshot -Path $HealthPath -Verbose
            } $context.Health
            $parsedHealth.Valid | Should -BeTrue
            $parsedHealth.SchemaVersion | Should -Be 1
            $parsedHealth.RelayProviderCount | Should -Be 0
            $parsedHealth.RelayHostState | Should -BeExactly 'Disabled'

            $schemaTwoHealth = [ordered]@{
                SchemaVersion = 2
                Status = 'Live'
                PlanType = 'plus'
                QuotaWindowCount = 2
                LastSuccessAt = [DateTimeOffset]::UtcNow.ToString('o')
                LastErrorCategory = $null
                LastErrorMessage = $null
                ProcessId = $PID
                UpdatedAt = [DateTimeOffset]::UtcNow.ToString('o')
                RelayProviderCount = 3
                RelayLiveCount = 1
                RelayStaleCount = 1
                RelayInvalidCount = 1
                RelayHostState = 'Live'
                DisplayMode = 'CompactBar'
                Theme = 'Light'
                UnknownField = 'discard-me'
            }
            [IO.File]::WriteAllText(
                $context.Health,
                ($schemaTwoHealth | ConvertTo-Json),
                [Text.UTF8Encoding]::new($false)
            )
            $parsedSchemaTwo = & $MonitorModule {
                param($HealthPath)
                Read-MonitorHealthSnapshot -Path $HealthPath
            } $context.Health
            $parsedSchemaTwo.Valid | Should -BeTrue
            $parsedSchemaTwo.SchemaVersion | Should -Be 2
            $parsedSchemaTwo.RelayProviderCount | Should -Be 3
            $parsedSchemaTwo.RelayLiveCount | Should -Be 1
            $parsedSchemaTwo.RelayStaleCount | Should -Be 1
            $parsedSchemaTwo.RelayInvalidCount | Should -Be 1
            $parsedSchemaTwo.RelayHostState | Should -BeExactly 'Live'
            $parsedSchemaTwo.DisplayMode | Should -BeExactly 'CompactBar'
            $parsedSchemaTwo.Theme | Should -BeExactly 'Light'
            @($parsedSchemaTwo.PSObject.Properties.Name) | Should -Be @(
                'Present', 'Valid', 'InvalidReason', 'SchemaVersion', 'Status',
                'PlanType', 'QuotaWindowCount', 'LastSuccessAt', 'LastErrorCategory',
                'LastErrorMessage', 'ProcessId', 'UpdatedAt', 'UpdatedAtValue',
                'RelayProviderCount', 'RelayLiveCount', 'RelayStaleCount',
                'RelayInvalidCount', 'RelayHostState', 'DisplayMode', 'Theme'
            )
            ($parsedSchemaTwo | ConvertTo-Json -Depth 5) |
                Should -Not -Match 'discard-me|UnknownField'

            $status = Get-CodexQuotaMonitorStatus `
                -LocalAppData $context.LocalAppData `
                -Startup $context.Startup `
                -InstancePrefix $context.Prefix
            $healthResult = Test-CodexQuotaMonitorHealth `
                -LocalAppData $context.LocalAppData `
                -Startup $context.Startup `
                -InstancePrefix $context.Prefix `
                -Live

            @($status.PSObject.Properties.Name) | Should -Be @(
                'Installed', 'Running', 'StartupEnabled', 'Status', 'SchemaVersion', 'PlanType',
                'QuotaWindowCount', 'LastSuccessAt', 'LastErrorCategory',
                'LastErrorMessage', 'ProcessId', 'UpdatedAt', 'RelayProviderCount',
                'RelayLiveCount', 'RelayStaleCount', 'RelayInvalidCount', 'RelayHostState',
                'DisplayMode', 'Theme', 'Root', 'AppPath',
                'SettingsPath', 'HealthPath', 'LogDirectory', 'ShortcutPath'
            )
            $status.Running | Should -BeTrue
            $status.Status | Should -BeExactly 'Live'
            $status.QuotaWindowCount | Should -Be 2
            $status.SchemaVersion | Should -Be 2
            $status.RelayProviderCount | Should -Be 3
            $status.RelayHostState | Should -BeExactly 'Live'
            $status.DisplayMode | Should -BeExactly 'CompactBar'
            $status.Theme | Should -BeExactly 'Light'
            @($healthResult.PSObject.Properties.Name) | Should -Be @(
                'Healthy', 'LiveRequired', 'Installed', 'Running', 'HealthPresent',
                'HealthFresh', 'Status', 'Reason', 'SchemaVersion', 'PlanType',
                'QuotaWindowCount', 'LastErrorCategory', 'LastErrorMessage',
                'ProcessId', 'UpdatedAt', 'RelayProviderCount', 'RelayLiveCount',
                'RelayStaleCount', 'RelayInvalidCount', 'RelayHostState',
                'DisplayMode', 'Theme'
            )
            $healthResult.Healthy | Should -BeTrue
            $healthResult.Reason | Should -BeExactly 'Healthy'

            [IO.File]::WriteAllText($context.Health, '{"access_token":"DO_NOT_EXPOSE"}')
            $invalid = Get-CodexQuotaMonitorStatus `
                -LocalAppData $context.LocalAppData `
                -Startup $context.Startup `
                -InstancePrefix $context.Prefix
            ($invalid | ConvertTo-Json -Depth 5) | Should -Not -Match 'DO_NOT_EXPOSE|access_token'
            $invalid.LastErrorCategory | Should -BeExactly 'HealthInvalid'
        }
        finally {
            & $MonitorModule {
                param($Instance)
                Close-MonitorInstance -Instance $Instance
            } $primary
        }
    }
}
