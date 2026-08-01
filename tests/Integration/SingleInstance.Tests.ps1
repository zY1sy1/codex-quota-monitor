BeforeAll {
    $script:SingleInstancePath = Join-Path $PSScriptRoot '..\..\companion\Private\SingleInstance.ps1'
    if (Test-Path -LiteralPath $script:SingleInstancePath -PathType Leaf) {
        . $script:SingleInstancePath
    }

    $script:PwshPath = (Get-Process -Id $PID).Path

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

    function Invoke-TestInNewRunspaceThread {
        param(
            [Parameter(Mandatory)]
            [scriptblock]$ScriptBlock,

            [object[]]$ArgumentList = @()
        )

        $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = [Threading.ApartmentState]::STA
        $runspace.ThreadOptions = [Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
        $powershell = $null
        try {
            $runspace.Open()
            $powershell = [PowerShell]::Create()
            $powershell.Runspace = $runspace
            $null = $powershell.AddScript($ScriptBlock.ToString())
            foreach ($argument in $ArgumentList) {
                $null = $powershell.AddArgument($argument)
            }

            $output = @($powershell.Invoke())
            if ($powershell.HadErrors -and $output.Count -eq 0) {
                $messages = @($powershell.Streams.Error | ForEach-Object { $_.Exception.Message }) -join '; '
                throw "New-thread runspace failed: $messages"
            }
            return $output
        }
        finally {
            if ($null -ne $powershell) {
                $powershell.Dispose()
            }
            $runspace.Dispose()
        }
    }

    function New-TestForgottenInstanceReferences {
        param(
            [Parameter(Mandatory)]
            [string]$Prefix
        )

        $instance = Enter-MonitorInstance -Prefix $Prefix -Signal None
        $references = [pscustomobject]@{
            Instance = [WeakReference]::new($instance)
            Mutex = [WeakReference]::new($instance.Mutex)
            ActivateEvent = [WeakReference]::new($instance.ActivateEvent)
            ExitEvent = [WeakReference]::new($instance.ExitEvent)
            OwnerToken = $instance.OwnerToken
        }
        Remove-Variable -Name instance
        return $references
    }

    function Invoke-TestFullGarbageCollection {
        foreach ($pass in 1..3) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            [GC]::Collect()
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
            $primary.OwnerThreadId | Should -Be ([Environment]::CurrentManagedThreadId)
            $primary.OwnerToken | Should -BeOfType ([guid])
            $primary.OwnerToken | Should -Not -Be ([guid]::Empty)

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

    It 'replaces a stale disposed-handle owner record and does not let the old token erase the replacement' {
        $prefix = New-TestMonitorPrefix
        $old = Enter-MonitorInstance -Prefix $prefix -Signal None
        $replacement = $null
        try {
            $old.Mutex.Dispose()

            $replacement = Enter-MonitorInstance -Prefix $prefix -Signal None
            $replacement.IsPrimary | Should -BeTrue
            $replacement.OwnerToken | Should -Not -Be $old.OwnerToken

            Remove-MonitorOwnerRecord -Prefix $prefix -OwnerToken $old.OwnerToken | Should -BeFalse
            $script:MonitorOwnedInstancePrefixes[$prefix].OwnerToken | Should -Be $replacement.OwnerToken

            { Close-MonitorInstance -Instance $old } | Should -Throw
            $old.Closed | Should -BeFalse

            $secondary = Enter-MonitorInstance -Prefix $prefix -Signal Activate
            try {
                $secondary.IsPrimary | Should -BeFalse
                $replacement.ActivateEvent.WaitOne(2000) | Should -BeTrue
            }
            finally {
                Close-MonitorInstance -Instance $secondary
            }
        }
        finally {
            if ($null -ne $replacement -and -not $replacement.Closed) {
                Close-MonitorInstance -Instance $replacement
            }
            if ($null -ne $old.ActivateEvent) {
                $old.ActivateEvent.Dispose()
            }
            if ($null -ne $old.ExitEvent) {
                $old.ExitEvent.Dispose()
            }
        }
    }

    It 'recovers an owner whose dedicated runspace thread died in the same AppDomain' {
        $prefix = New-TestMonitorPrefix
        $metadata = @(Invoke-TestInNewRunspaceThread -ScriptBlock {
            param($SingleInstancePath, $Prefix)
            . $SingleInstancePath
            $instance = Enter-MonitorInstance -Prefix $Prefix -Signal None
            [pscustomobject]@{
                IsPrimary = $instance.IsPrimary
                OwnerThreadId = $instance.OwnerThreadId
                OwnerToken = $instance.OwnerToken
            }
        } -ArgumentList @($script:SingleInstancePath, $prefix))[0]

        $metadata.IsPrimary | Should -BeTrue
        $record = $script:MonitorOwnedInstancePrefixes[$prefix]
        $record | Should -BeOfType ([pscustomobject])
        $record.OwnerThread.IsAlive | Should -BeFalse

        $takeover = Enter-MonitorInstance -Prefix $prefix -Signal None
        try {
            $takeover.IsPrimary | Should -BeTrue
            $takeover.OwnerToken | Should -Not -Be $metadata.OwnerToken
        }
        finally {
            Close-MonitorInstance -Instance $takeover
        }
    }

    It 'rejects wrong-thread close before changing handles, registry, or Closed state' {
        $prefix = New-TestMonitorPrefix
        $primary = Enter-MonitorInstance -Prefix $prefix -Signal None
        try {
            $closeResult = @(Invoke-TestInNewRunspaceThread -ScriptBlock {
                param($SingleInstancePath, $Instance)
                . $SingleInstancePath
                try {
                    Close-MonitorInstance -Instance $Instance
                    [pscustomobject]@{ Status = 'Closed'; ErrorType = $null }
                }
                catch {
                    [pscustomobject]@{ Status = 'Threw'; ErrorType = $_.Exception.GetType().FullName }
                }
            } -ArgumentList @($script:SingleInstancePath, $primary))[0]

            $closeResult.Status | Should -BeExactly 'Threw'
            $closeResult.ErrorType | Should -BeExactly ([InvalidOperationException].FullName)
            $primary.Closed | Should -BeFalse
            $primary.Mutex.SafeWaitHandle.IsClosed | Should -BeFalse
            $primary.ActivateEvent.SafeWaitHandle.IsClosed | Should -BeFalse
            $primary.ExitEvent.SafeWaitHandle.IsClosed | Should -BeFalse
            $script:MonitorOwnedInstancePrefixes[$prefix].OwnerToken | Should -Be $primary.OwnerToken

            $primary.ActivateEvent.Set() | Should -BeTrue
            $primary.ActivateEvent.WaitOne(2000) | Should -BeTrue

            $secondary = Enter-MonitorInstance -Prefix $prefix -Signal Activate
            try {
                $secondary.IsPrimary | Should -BeFalse
                $primary.ActivateEvent.WaitOne(2000) | Should -BeTrue
            }
            finally {
                Close-MonitorInstance -Instance $secondary
            }
        }
        finally {
            if (-not $primary.Closed) {
                Close-MonitorInstance -Instance $primary
            }
        }

        $primary.Closed | Should -BeTrue
    }

    It 'forgets an unreferenced instance on a live owner thread and allows a fresh primary' {
        $prefix = New-TestMonitorPrefix
        $forgotten = New-TestForgottenInstanceReferences -Prefix $prefix
        $fresh = $null
        try {
            Invoke-TestFullGarbageCollection

            $forgotten.Instance.IsAlive | Should -BeFalse
            $forgotten.Mutex.IsAlive | Should -BeFalse
            $forgotten.ActivateEvent.IsAlive | Should -BeFalse
            $forgotten.ExitEvent.IsAlive | Should -BeFalse
            $script:MonitorOwnedInstancePrefixes[$prefix].MutexReference | Should -BeOfType ([WeakReference])

            foreach ($eventName in @("$prefix.Activate", "$prefix.Exit")) {
                $openError = $null
                try {
                    $event = [Threading.EventWaitHandle]::OpenExisting($eventName)
                    $event.Dispose()
                }
                catch {
                    $openError = $_.Exception
                }
                $openError | Should -Not -BeNullOrEmpty
                while ($null -ne $openError.InnerException) {
                    $openError = $openError.InnerException
                }
                $openError.GetType() | Should -Be ([Threading.WaitHandleCannotBeOpenedException])
            }

            $fresh = Enter-MonitorInstance -Prefix $prefix -Signal None
            $fresh.IsPrimary | Should -BeTrue
            $fresh.OwnerToken | Should -Not -Be $forgotten.OwnerToken
        }
        finally {
            if ($null -ne $fresh -and -not $fresh.Closed) {
                Close-MonitorInstance -Instance $fresh
            }

            $forgottenMutex = $forgotten.Mutex.Target
            if ($null -ne $forgottenMutex) {
                try {
                    $forgottenMutex.ReleaseMutex()
                }
                catch {
                }
                $forgottenMutex.Dispose()
            }
            $null = Remove-MonitorOwnerRecord -Prefix $prefix -OwnerToken $forgotten.OwnerToken
        }
    }
}
