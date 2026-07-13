BeforeAll {
    $script:SingleInstancePath = Join-Path $PSScriptRoot '..\..\companion\Private\SingleInstance.ps1'
    if (Test-Path -LiteralPath $script:SingleInstancePath -PathType Leaf) {
        . $script:SingleInstancePath
    }

    $script:PwshPath = 'C:\Users\335\AppData\Local\Microsoft\WindowsApps\pwsh.exe'

    function New-TestMonitorPrefix {
        return 'Local\CodexQuotaMonitor.Tests.{0}' -f [guid]::NewGuid().ToString('N')
    }

    function Wait-TestCondition {
        param(
            [Parameter(Mandatory)]
            [scriptblock]$Condition,

            [string]$Description = 'condition',

            [int]$TimeoutMilliseconds = 5000
        )

        $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        $wait = [Threading.ManualResetEventSlim]::new($false)
        try {
            do {
                if (& $Condition) {
                    return
                }

                $null = $wait.Wait(20)
            } while ([DateTimeOffset]::UtcNow -lt $deadline)
        }
        finally {
            $wait.Dispose()
        }

        throw "Timed out waiting for $Description."
    }

    function Write-TestInstanceChild {
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        $source = @'
param(
    [Parameter(Mandatory)]
    [ValidateSet('Lifecycle', 'Abandon')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [string]$SingleInstancePath,

    [Parameter(Mandatory)]
    [string]$Prefix,

    [Parameter(Mandatory)]
    [string]$ReadyPath,

    [Parameter(Mandatory)]
    [string]$StatePath,

    [string]$GateName
)

$ErrorActionPreference = 'Stop'
. $SingleInstancePath
$instance = Enter-MonitorInstance -Prefix $Prefix -Signal None
if (-not $instance.IsPrimary) {
    exit 11
}

[IO.File]::WriteAllText($ReadyPath, 'ready', [Text.UTF8Encoding]::new($false))

if ($Mode -eq 'Abandon') {
    $gate = [Threading.EventWaitHandle]::OpenExisting($GateName)
    try {
        if (-not $gate.WaitOne(10000)) {
            exit 12
        }
    }
    finally {
        $gate.Dispose()
    }

    [Environment]::Exit(0)
}

if (-not $instance.ActivateEvent.WaitOne(10000)) {
    exit 13
}

[IO.File]::WriteAllText($StatePath, 'activated', [Text.UTF8Encoding]::new($false))
if (-not $instance.ExitEvent.WaitOne(10000)) {
    exit 14
}

Close-MonitorInstance -Instance $instance
[IO.File]::WriteAllText($StatePath, 'exited', [Text.UTF8Encoding]::new($false))
exit 0
'@

        [IO.File]::WriteAllText($Path, $source, [Text.UTF8Encoding]::new($false))
    }

    function Start-TestInstanceChild {
        param(
            [Parameter(Mandatory)]
            [string[]]$ArgumentList
        )

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:PwshPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Sta') + $ArgumentList) {
            $startInfo.ArgumentList.Add($argument)
        }

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $null = $process.Start()
        return $process
    }

    function Stop-TestInstanceChild {
        param(
            [AllowNull()]
            [Diagnostics.Process]$Process
        )

        if ($null -eq $Process) {
            return
        }

        try {
            if (-not $Process.HasExited) {
                $Process.Kill($true)
                $null = $Process.WaitForExit(5000)
            }
        }
        finally {
            $Process.Dispose()
        }
    }
}

Describe 'monitor single-instance lifecycle' {
    It 'uses createdNew ownership and AutoReset Activate and Exit signals without same-thread reentrancy' {
        $prefix = New-TestMonitorPrefix
        $primary = $null
        try {
            $primary = Enter-MonitorInstance -Prefix $prefix -Signal None
            $primary.IsPrimary | Should -BeTrue
            $primary.Prefix | Should -BeExactly $prefix
            $primary.Mutex | Should -BeOfType ([Threading.Mutex])
            $primary.ActivateEvent | Should -BeOfType ([Threading.EventWaitHandle])
            $primary.ExitEvent | Should -BeOfType ([Threading.EventWaitHandle])

            $activate = Enter-MonitorInstance -Prefix $prefix -Signal Activate
            $activate.IsPrimary | Should -BeFalse
            $activate.Mutex | Should -BeNullOrEmpty
            $activate.ActivateEvent | Should -BeNullOrEmpty
            $activate.ExitEvent | Should -BeNullOrEmpty
            $activate.Closed | Should -BeTrue
            $primary.ActivateEvent.WaitOne(2000) | Should -BeTrue
            $primary.ActivateEvent.WaitOne(0) | Should -BeFalse

            Close-MonitorInstance -Instance $activate
            Close-MonitorInstance -Instance $activate

            $exit = Enter-MonitorInstance -Prefix $prefix -Signal Exit
            $exit.IsPrimary | Should -BeFalse
            $primary.ExitEvent.WaitOne(2000) | Should -BeTrue
            $primary.ExitEvent.WaitOne(0) | Should -BeFalse
            Close-MonitorInstance -Instance $exit
        }
        finally {
            if ($null -ne $primary) {
                Close-MonitorInstance -Instance $primary
                Close-MonitorInstance -Instance $primary
            }
        }

        $replacement = Enter-MonitorInstance -Prefix $prefix -Signal None
        try {
            $replacement.IsPrimary | Should -BeTrue
        }
        finally {
            Close-MonitorInstance -Instance $replacement
        }
    }

    It 'signals a real primary process and lets it exit cleanly' {
        $prefix = New-TestMonitorPrefix
        $directory = Join-Path $TestDrive '跨进程 & lifecycle'
        $null = New-Item -ItemType Directory -Path $directory -Force
        $childScript = Join-Path $directory 'instance child.ps1'
        $readyPath = Join-Path $directory 'ready.txt'
        $statePath = Join-Path $directory 'state.txt'
        Write-TestInstanceChild -Path $childScript

        $process = $null
        try {
            $process = Start-TestInstanceChild -ArgumentList @(
                '-File', $childScript,
                '-Mode', 'Lifecycle',
                '-SingleInstancePath', $script:SingleInstancePath,
                '-Prefix', $prefix,
                '-ReadyPath', $readyPath,
                '-StatePath', $statePath
            )

            Wait-TestCondition -Description 'primary child readiness' -Condition {
                (Test-Path -LiteralPath $readyPath -PathType Leaf) -or $process.HasExited
            }
            $process.HasExited | Should -BeFalse

            $activate = Enter-MonitorInstance -Prefix $prefix -Signal Activate
            try {
                $activate.IsPrimary | Should -BeFalse
            }
            finally {
                Close-MonitorInstance -Instance $activate
            }

            Wait-TestCondition -Description 'cross-process activation' -Condition {
                (Test-Path -LiteralPath $statePath -PathType Leaf) -and
                ([IO.File]::ReadAllText($statePath) -eq 'activated')
            }

            $exit = Enter-MonitorInstance -Prefix $prefix -Signal Exit
            try {
                $exit.IsPrimary | Should -BeFalse
            }
            finally {
                Close-MonitorInstance -Instance $exit
            }

            $process.WaitForExit(10000) | Should -BeTrue
            $stderr = $process.StandardError.ReadToEnd()
            $process.ExitCode | Should -Be 0 -Because $stderr
            [IO.File]::ReadAllText($statePath) | Should -BeExactly 'exited'
        }
        finally {
            Stop-TestInstanceChild -Process $process
        }
    }

    It 'takes ownership of an abandoned named mutex while another handle keeps the name alive' {
        $prefix = New-TestMonitorPrefix
        $directory = Join-Path $TestDrive 'abandoned owner'
        $null = New-Item -ItemType Directory -Path $directory -Force
        $childScript = Join-Path $directory 'abandon.ps1'
        $readyPath = Join-Path $directory 'ready.txt'
        $statePath = Join-Path $directory 'unused.txt'
        $gateName = "$prefix.TestCrash"
        Write-TestInstanceChild -Path $childScript

        $gateCreated = $false
        $gate = [Threading.EventWaitHandle]::new(
            $false,
            [Threading.EventResetMode]::ManualReset,
            $gateName,
            [ref]$gateCreated
        )
        $process = $null
        $keeper = $null
        $takeover = $null
        try {
            $process = Start-TestInstanceChild -ArgumentList @(
                '-File', $childScript,
                '-Mode', 'Abandon',
                '-SingleInstancePath', $script:SingleInstancePath,
                '-Prefix', $prefix,
                '-ReadyPath', $readyPath,
                '-StatePath', $statePath,
                '-GateName', $gateName
            )

            Wait-TestCondition -Description 'abandoning child readiness' -Condition {
                (Test-Path -LiteralPath $readyPath -PathType Leaf) -or $process.HasExited
            }
            $process.HasExited | Should -BeFalse
            $keeper = [Threading.Mutex]::OpenExisting($prefix)

            $gate.Set() | Should -BeTrue
            $process.WaitForExit(10000) | Should -BeTrue
            $stderr = $process.StandardError.ReadToEnd()
            $process.ExitCode | Should -Be 0 -Because $stderr

            $takeover = Enter-MonitorInstance -Prefix $prefix -Signal None
            $takeover.IsPrimary | Should -BeTrue
            $takeover.ActivateEvent | Should -BeOfType ([Threading.EventWaitHandle])
            $takeover.ExitEvent | Should -BeOfType ([Threading.EventWaitHandle])
        }
        finally {
            if ($null -ne $takeover) {
                Close-MonitorInstance -Instance $takeover
            }
            if ($null -ne $keeper) {
                $keeper.Dispose()
            }
            Stop-TestInstanceChild -Process $process
            $gate.Dispose()
        }
    }

    It 'cleans up mutex and partially created events when primary initialization fails' {
        $prefix = New-TestMonitorPrefix
        $conflictCreated = $false
        $conflict = [Threading.Mutex]::new($false, "$prefix.Exit", [ref]$conflictCreated)
        try {
            { Enter-MonitorInstance -Prefix $prefix -Signal None } | Should -Throw
        }
        finally {
            $conflict.Dispose()
        }

        $primary = Enter-MonitorInstance -Prefix $prefix -Signal None
        try {
            $primary.IsPrimary | Should -BeTrue
            $primary.ActivateEvent | Should -Not -BeNullOrEmpty
            $primary.ExitEvent | Should -Not -BeNullOrEmpty
        }
        finally {
            Close-MonitorInstance -Instance $primary
        }
    }

    It 'supports the .NET 8-compatible constructor fallback' {
        $prefix = New-TestMonitorPrefix
        $primary = $null
        try {
            $primary = Enter-MonitorInstance -Prefix $prefix -Signal None -CompatibilityMode
            $primary.IsPrimary | Should -BeTrue

            $secondary = Enter-MonitorInstance -Prefix $prefix -Signal Activate -CompatibilityMode
            $secondary.IsPrimary | Should -BeFalse
            $primary.ActivateEvent.WaitOne(2000) | Should -BeTrue
            Close-MonitorInstance -Instance $secondary
        }
        finally {
            if ($null -ne $primary) {
                Close-MonitorInstance -Instance $primary
            }
        }
    }

    It 'bounds an event-open race when the primary never publishes the event' {
        $missingEventName = "$(New-TestMonitorPrefix).Missing"
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            {
                Open-MonitorInstanceEvent -Name $missingEventName -TimeoutMilliseconds 100
            } | Should -Throw -ExceptionType ([TimeoutException])
        }
        finally {
            $stopwatch.Stop()
        }

        $stopwatch.ElapsedMilliseconds | Should -BeLessThan 2000
    }
}
