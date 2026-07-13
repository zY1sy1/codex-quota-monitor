BeforeAll {
    $script:ObjectAccessPath = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..\companion\Private\ObjectAccess.ps1").Path
    $script:JsonRpcPath = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..\companion\Private\JsonRpc.ps1").Path
    . $script:ObjectAccessPath
    . $script:JsonRpcPath
    $script:AppServerProcessPath = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..\companion\Private\AppServerProcess.ps1").Path
    . $script:AppServerProcessPath

    $script:PwshPath = 'C:\Users\335\AppData\Local\Microsoft\WindowsApps\pwsh.exe'
    $script:FakeAppServerPath = (Resolve-Path -LiteralPath "$PSScriptRoot\..\Fixtures\FakeAppServer.ps1").Path

    function Wait-TestCondition {
        param(
            [Parameter(Mandatory)]
            [scriptblock]$Condition,

            [string]$Description = 'condition',

            [int]$TimeoutMilliseconds = 5000
        )

        $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        do {
            if (& $Condition) {
                return
            }

            [Threading.Thread]::Sleep(20)
        } while ([DateTimeOffset]::UtcNow -lt $deadline)

        throw "Timed out waiting for $Description."
    }

    function Wait-TestRecord {
        param(
            [Parameter(Mandatory)]
            [object]$Transport,

            [Parameter(Mandatory)]
            [scriptblock]$Predicate,

            [string]$Description = 'App Server record'
        )

        $match = [pscustomobject]@{ Value = $null }
        Wait-TestCondition -Description $Description -Condition {
            foreach ($record in @(Receive-AppServerRecord -Transport $Transport)) {
                if (& $Predicate $record) {
                    $match.Value = $record
                    return $true
                }
            }

            return $false
        }

        return $match.Value
    }

    function Test-RecordHasId {
        param(
            [Parameter(Mandatory)]
            [object]$Record,

            [Parameter(Mandatory)]
            [int]$Id
        )

        if ($Record.Stream -ne 'stdout') {
            return $false
        }

        try {
            return (($Record.Line | ConvertFrom-Json).id -eq $Id)
        }
        catch {
            return $false
        }
    }

    function Add-OwnedTestTransport {
        param(
            [Parameter(Mandatory)]
            [object]$Transport
        )

        $script:OwnedTestTransports.Add($Transport)
        return $Transport
    }

    function Start-TestFakeAppServer {
        param(
            [ValidateSet('Happy', 'Malformed', 'ExitAfterInitialize', 'InheritedPipes')]
            [string]$Scenario = 'Happy',

            [string]$ServerPath = $script:FakeAppServerPath,

            [string]$WorkingDirectory,

            [int]$StdoutRecordLimit = 1000,

            [int]$StderrRecordLimit = 200,

            [int]$DiagnosticLineLimit = 2048
        )

        $parameters = @{
            ExecutablePath = $script:PwshPath
            ArgumentList = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ServerPath, '-Scenario', $Scenario)
            StdoutRecordLimit = $StdoutRecordLimit
            StderrRecordLimit = $StderrRecordLimit
            DiagnosticLineLimit = $DiagnosticLineLimit
        }
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $parameters.WorkingDirectory = $WorkingDirectory
        }

        return Add-OwnedTestTransport -Transport (Start-AppServerProcess @parameters)
    }
}

Describe 'App Server JSONL process transport' {
    BeforeEach {
        $script:OwnedTestTransports = [Collections.Generic.List[object]]::new()
    }

    AfterEach {
        if ($null -ne (Get-Command -Name Stop-AppServerProcess -ErrorAction SilentlyContinue)) {
            foreach ($transport in @($script:OwnedTestTransports)) {
                Stop-AppServerProcess -Transport $transport
            }
        }
    }

    It 'starts the fake server with separate arguments and receives a correlated initialize response' {
        Test-Path -LiteralPath $script:PwshPath -PathType Leaf | Should -BeTrue
        $transport = Start-TestFakeAppServer

        @($transport.Process.StartInfo.ArgumentList) | Should -Be @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:FakeAppServerPath, '-Scenario', 'Happy'
        )
        $transport.Queue.GetType() | Should -Be ([Collections.Concurrent.ConcurrentQueue[object]])

        Send-AppServerMessage -Transport $transport -Message (New-RpcRequest -Id 41 -Method 'initialize' -Params ([ordered]@{}))
        $record = Wait-TestRecord -Transport $transport -Description 'initialize response' -Predicate {
            param($candidate)
            Test-RecordHasId -Record $candidate -Id 41
        }

        $record.Stream | Should -BeExactly 'stdout'
        $record.Line | Should -Not -Match '[\r\n]'
        $record.ReceivedAt | Should -BeOfType ([DateTimeOffset])
        $record.ReceivedAt.Offset | Should -Be ([TimeSpan]::Zero)
        @($record.PSObject.Properties.Name) | Should -Contain 'Stream'
        @($record.PSObject.Properties.Name) | Should -Contain 'Line'
        @($record.PSObject.Properties.Name) | Should -Contain 'ReceivedAt'
        $response = $record.Line | ConvertFrom-Json
        $response.result.userAgent | Should -BeExactly 'fake'
        $response.result.platformFamily | Should -BeExactly 'windows'
    }

    It 'preserves a spaced Unicode script path as one ArgumentList item' {
        $unicodeDirectory = Join-Path $TestDrive 'server folder 中文'
        $null = New-Item -ItemType Directory -Path $unicodeDirectory
        $unicodeServer = Join-Path $unicodeDirectory 'Fake Server 服务器.ps1'
        Copy-Item -LiteralPath $script:FakeAppServerPath -Destination $unicodeServer
        $transport = Start-TestFakeAppServer -ServerPath $unicodeServer -WorkingDirectory $unicodeDirectory

        $transport.Process.StartInfo.ArgumentList[4] | Should -BeExactly $unicodeServer
        $transport.Process.StartInfo.WorkingDirectory | Should -BeExactly $unicodeDirectory
        Send-AppServerMessage -Transport $transport -Message (New-RpcRequest -Id 42 -Method 'account/read' -Params $null)
        $accountRecord = Wait-TestRecord -Transport $transport -Description 'account response' -Predicate {
            param($candidate)
            Test-RecordHasId -Record $candidate -Id 42
        }

        $accountResponse = $accountRecord.Line | ConvertFrom-Json
        $accountResponse.result.account.type | Should -BeExactly 'chatgpt'
        $accountResponse.result.account.planType | Should -BeExactly 'plus'

        Send-AppServerMessage -Transport $transport -Message (New-RpcRequest -Id 43 -Method 'account/rateLimits/read' -Params $null)
        $quotaRecord = Wait-TestRecord -Transport $transport -Description 'quota response' -Predicate {
            param($candidate)
            Test-RecordHasId -Record $candidate -Id 43
        }
        $quotaResponse = $quotaRecord.Line | ConvertFrom-Json
        $quotaResponse.result.rateLimits.primary.usedPercent | Should -Be 25
        $quotaResponse.result.rateLimits.primary.windowDurationMins | Should -Be 300
        $quotaResponse.result.rateLimits.primary.resetsAt | Should -Be 1893456000
        $quotaResponse.result.rateLimits.secondary.usedPercent | Should -Be 40
        $quotaResponse.result.rateLimits.secondary.windowDurationMins | Should -Be 10080
        $quotaResponse.result.rateLimits.secondary.resetsAt | Should -Be 1893888000
    }

    It 'queues malformed stdout unchanged for parsing by the consumer' {
        $transport = Start-TestFakeAppServer -Scenario Malformed

        Send-AppServerMessage -Transport $transport -Message (New-RpcRequest -Id 44 -Method 'initialize' -Params $null)
        $record = Wait-TestRecord -Transport $transport -Description 'malformed stdout' -Predicate {
            param($candidate)
            $candidate.Stream -eq 'stdout'
        }

        $record.Line | Should -BeExactly '{broken'
    }

    It 'retains exit code 17 and cleanup stays safe and idempotent after server exit' {
        $transport = Start-TestFakeAppServer -Scenario ExitAfterInitialize
        Send-AppServerMessage -Transport $transport -Message (New-RpcRequest -Id 45 -Method 'initialize' -Params $null)
        $null = Wait-TestRecord -Transport $transport -Description 'last response before exit' -Predicate {
            param($candidate)
            Test-RecordHasId -Record $candidate -Id 45
        }
        Wait-TestCondition -Description 'fake server exit' -Condition { $transport.Process.HasExited }

        $transport.Process.ExitCode | Should -Be 17
        { Stop-AppServerProcess -Transport $transport } | Should -Not -Throw
        { Stop-AppServerProcess -Transport $transport } | Should -Not -Throw
        $transport.Stopped | Should -BeTrue
        $transport.Disposed | Should -BeTrue
        $transport.ExitCode | Should -Be 17
    }

    It 'serializes concurrent sends into intact one-line JSON frames' {
        $transport = Start-TestFakeAppServer
        $sendErrors = [Collections.Concurrent.ConcurrentQueue[string]]::new()
        $sendGate = [Threading.Barrier]::new(16)

        try {
            $null = 0..31 | ForEach-Object -Parallel {
                $jsonRpcPath = $using:JsonRpcPath
                $appServerProcessPath = $using:AppServerProcessPath
                $sharedTransport = $using:transport
                $sharedErrors = $using:sendErrors
                $sharedGate = $using:sendGate
                . $jsonRpcPath
                . $appServerProcessPath
                $null = $sharedGate.SignalAndWait([TimeSpan]::FromSeconds(10))
                try {
                    Send-AppServerMessage -Transport $sharedTransport -Message (
                        New-RpcRequest -Id (1000 + $_) -Method 'test/echo' -Params ([ordered]@{ sequence = $_ })
                    )
                }
                catch {
                    $sharedErrors.Enqueue($_.Exception.Message)
                }
            } -ThrottleLimit 16
        }
        finally {
            $sendGate.Dispose()
        }

        @($sendErrors.ToArray()).Count | Should -Be 0
        $seen = [Collections.Generic.HashSet[int]]::new()
        Wait-TestCondition -Description 'all concurrent echo responses' -TimeoutMilliseconds 10000 -Condition {
            foreach ($record in @(Receive-AppServerRecord -Transport $transport)) {
                if ($record.Stream -ne 'stdout') {
                    continue
                }

                try {
                    $response = $record.Line | ConvertFrom-Json
                    if ($response.id -ge 1000 -and $response.id -lt 1032 -and
                        $response.result.sequence -eq ($response.id - 1000)) {
                        $null = $seen.Add([int]$response.id)
                    }
                }
                catch {
                    throw "Corrupt JSONL frame: $($record.Line)"
                }
            }

            return $seen.Count -eq 32
        }
        $seen.Count | Should -Be 32
    }

    It 'returns only success or a sanitized TransportClosed error when send races Stop' {
        $transport = Start-TestFakeAppServer
        $gate = [Threading.Barrier]::new(2)
        $results = [Collections.Concurrent.ConcurrentQueue[object]]::new()

        try {
            $null = @('Send', 'Stop') | ForEach-Object -Parallel {
                $operation = $_
                $jsonRpcPath = $using:JsonRpcPath
                $appServerProcessPath = $using:AppServerProcessPath
                $sharedTransport = $using:transport
                $sharedGate = $using:gate
                $sharedResults = $using:results
                . $jsonRpcPath
                . $appServerProcessPath
                $null = $sharedGate.SignalAndWait([TimeSpan]::FromSeconds(10))
                if ($operation -eq 'Send') {
                    try {
                        Send-AppServerMessage -Transport $sharedTransport -Message (
                            New-RpcRequest -Id 1500 -Method 'test/echo' -Params ([ordered]@{ sequence = 500 })
                        )
                        $sharedResults.Enqueue([pscustomobject]@{ Operation = 'Send'; Status = 'Sent'; Category = $null; Message = $null })
                    }
                    catch {
                        $sharedResults.Enqueue([pscustomobject]@{
                                Operation = 'Send'
                                Status = 'Closed'
                                Category = $_.Exception.Data['AppServerErrorCategory']
                                Message = $_.Exception.Message
                            })
                    }
                }
                else {
                    Stop-AppServerProcess -Transport $sharedTransport
                    $sharedResults.Enqueue([pscustomobject]@{ Operation = 'Stop'; Disposed = $sharedTransport.Disposed })
                }
            } -ThrottleLimit 2
        }
        finally {
            $gate.Dispose()
        }

        $sendResult = @($results.ToArray() | Where-Object Operation -EQ 'Send')[0]
        $stopResult = @($results.ToArray() | Where-Object Operation -EQ 'Stop')[0]
        $sendResult.Status | Should -BeIn @('Sent', 'Closed')
        if ($sendResult.Status -eq 'Closed') {
            $sendResult.Category | Should -BeExactly 'TransportClosed'
            $sendResult.Message | Should -BeExactly 'The App Server process transport is closed.'
        }
        $stopResult.Disposed | Should -BeTrue
    }

    It 'sanitizes send after natural process exit as TransportClosed' {
        $transport = Start-TestFakeAppServer -Scenario ExitAfterInitialize
        Send-AppServerMessage -Transport $transport -Message (New-RpcRequest -Id 1501 -Method 'initialize' -Params $null)
        $null = Wait-TestRecord -Transport $transport -Description 'initialize before natural exit' -Predicate {
            param($candidate)
            Test-RecordHasId -Record $candidate -Id 1501
        }
        Wait-TestCondition -Description 'natural server exit' -Condition { $transport.Process.HasExited }

        try {
            Send-AppServerMessage -Transport $transport -Message (New-RpcRequest -Id 1502 -Method 'test/echo' -Params $null)
            throw 'Expected send after process exit to fail.'
        }
        catch {
            $sendError = $_
        }

        $sendError.Exception.Data['AppServerErrorCategory'] | Should -BeExactly 'TransportClosed'
        $sendError.FullyQualifiedErrorId | Should -Match '^AppServerProcess\.TransportClosed'
        $sendError.Exception.Message | Should -BeExactly 'The App Server process transport is closed.'
        $transport.StdinClosed | Should -BeTrue
    }

    It 'kills only its owned stubborn child and lets a clean fake server exit on stdin close' {
        $survivor = Start-TestFakeAppServer
        $stubbornScript = '[Console]::In.ReadToEnd(); while ($true) { [Threading.Thread]::Sleep(50) }'
        $stubborn = Add-OwnedTestTransport -Transport (Start-AppServerProcess -ExecutablePath $script:PwshPath -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $stubbornScript
            ))

        Stop-AppServerProcess -Transport $stubborn

        $stubborn.WasKilled | Should -BeTrue
        $stubborn.Disposed | Should -BeTrue
        $survivor.Process.HasExited | Should -BeFalse

        Stop-AppServerProcess -Transport $survivor
        $survivor.WasKilled | Should -BeFalse
        $survivor.ExitCode | Should -Be 0
        $survivor.Disposed | Should -BeTrue
    }

    It 'makes a losing concurrent Stop wait until the owner completes' {
        $calls = [Collections.Concurrent.ConcurrentQueue[string]]::new()
        $process = [pscustomobject]@{
            Calls = $calls
            HasExited = $false
            ExitCode = 0
        }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            [Threading.Thread]::Sleep(150)
            return $true
        }
        $process | Add-Member -MemberType ScriptMethod -Name CancelOutputRead -Value { $this.Calls.Enqueue('CancelOutputRead') }
        $process | Add-Member -MemberType ScriptMethod -Name CancelErrorRead -Value { $this.Calls.Enqueue('CancelErrorRead') }
        $process | Add-Member -MemberType ScriptMethod -Name remove_OutputDataReceived -Value { param($Handler) $this.Calls.Enqueue('RemoveOutput') }
        $process | Add-Member -MemberType ScriptMethod -Name remove_ErrorDataReceived -Value { param($Handler) $this.Calls.Enqueue('RemoveError') }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Calls.Enqueue('ProcessDispose') }

        $writer = [pscustomobject]@{ Calls = $calls }
        $writer | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.Calls.Enqueue('WriterClose') }
        $writer | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Calls.Enqueue('WriterDispose') }

        $transport = [pscustomobject][ordered]@{
            Process = $process
            CaptureState = [CodexQuotaMonitor.ProcessTransport.CaptureState]::new(1, 1, 32)
            OutputHandler = $null
            ErrorHandler = $null
            StdinWriter = $writer
            IoLock = [object]::new()
            StoppedValue = $false
            Disposed = $false
            StdinClosed = $false
            WasKilled = $false
            ExitCode = $null
        }
        $transport | Add-Member -MemberType AliasProperty -Name Stopped -Value StoppedValue
        $errors = [Collections.Concurrent.ConcurrentQueue[string]]::new()
        $returnStates = [Collections.Concurrent.ConcurrentQueue[bool]]::new()
        $startGate = [Threading.Barrier]::new(2)

        try {
            $null = 1..2 | ForEach-Object -Parallel {
                $appServerProcessPath = $using:AppServerProcessPath
                $sharedTransport = $using:transport
                $sharedErrors = $using:errors
                $sharedReturnStates = $using:returnStates
                $sharedStartGate = $using:startGate
                . $appServerProcessPath
                $null = $sharedStartGate.SignalAndWait([TimeSpan]::FromSeconds(10))
                try {
                    Stop-AppServerProcess -Transport $sharedTransport -TimeoutMilliseconds 3000
                    $sharedReturnStates.Enqueue([bool]$sharedTransport.Disposed)
                }
                catch {
                    $sharedErrors.Enqueue($_.Exception.Message)
                }
            } -ThrottleLimit 2
        }
        finally {
            $startGate.Dispose()
        }

        @($errors.ToArray()).Count | Should -Be 0
        @($returnStates.ToArray()) | Should -Be @($true, $true)
        @($calls.ToArray() | Where-Object { $_ -eq 'ProcessDispose' }).Count | Should -Be 1
        @($calls.ToArray() | Where-Object { $_ -eq 'WriterClose' }).Count | Should -Be 1
    }

    It 'returns within one shutdown deadline when a descendant retains inherited pipes' {
        $transport = Start-TestFakeAppServer -Scenario InheritedPipes
        Send-AppServerMessage -Transport $transport -Message (New-RpcRequest -Id 1600 -Method 'initialize' -Params $null)
        $null = Wait-TestRecord -Transport $transport -Description 'response before inherited-pipe exit' -Predicate {
            param($candidate)
            Test-RecordHasId -Record $candidate -Id 1600
        }
        Wait-TestCondition -Description 'parent exit with inherited pipes' -Condition { $transport.Process.HasExited }

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        Stop-AppServerProcess -Transport $transport -TimeoutMilliseconds 250
        $stopwatch.Stop()

        $stopwatch.ElapsedMilliseconds | Should -BeLessThan 750
        $transport.Disposed | Should -BeTrue
    }

    It 'redacts and length-caps stderr before enforcing its injected record bound' {
        $transport = Start-TestFakeAppServer -StderrRecordLimit 5 -DiagnosticLineLimit 128
        Send-AppServerMessage -Transport $transport -Message (New-RpcRequest -Id 46 -Method 'test/diagnostics' -Params $null)

        Wait-TestCondition -Description 'bounded diagnostics and completion response' -Condition {
            $snapshot = @($transport.Queue.ToArray())
            @($snapshot | Where-Object Stream -EQ 'stderr').Count -eq 5 -and
                @($snapshot | Where-Object { Test-RecordHasId -Record $_ -Id 46 }).Count -eq 1
        }

        $records = @(Receive-AppServerRecord -Transport $transport)
        $stderr = @($records | Where-Object Stream -EQ 'stderr')
        $stderr.Count | Should -Be 5
        foreach ($record in $stderr) {
            $record.Line.Length | Should -BeLessOrEqual 128
            $record.ReceivedAt.Offset | Should -Be ([TimeSpan]::Zero)
        }

        ($stderr.Line -join "`n") | Should -Not -Match '(?i)FAKE_|person@example|bearer|access[_-]?token|authorization|cookie|email|secret'
    }

    It 'bounds stdout independently and Receive-AppServerRecord drains at most Maximum without blocking' {
        $transport = Start-TestFakeAppServer -StdoutRecordLimit 3 -StderrRecordLimit 2
        Send-AppServerMessage -Transport $transport -Message (New-RpcRequest -Id 47 -Method 'test/stdoutBurst' -Params ([ordered]@{ count = 8 }))

        Wait-TestCondition -Description 'bounded stdout burst completion' -Condition {
            $snapshot = @($transport.Queue.ToArray())
            @($snapshot | Where-Object Stream -EQ 'stdout').Count -eq 3 -and
                @($snapshot | Where-Object { Test-RecordHasId -Record $_ -Id 47 }).Count -eq 1
        }

        $startedAt = [Diagnostics.Stopwatch]::StartNew()
        $first = @(Receive-AppServerRecord -Transport $transport -Maximum 2)
        $startedAt.Stop()
        $second = @(Receive-AppServerRecord -Transport $transport)

        $first.Count | Should -Be 2
        $second.Count | Should -Be 1
        @($first + $second | Where-Object Stream -EQ 'stdout').Count | Should -Be 3
        @($first + $second | Where-Object Stream -EQ 'stderr').Count | Should -Be 0
        $startedAt.ElapsedMilliseconds | Should -BeLessThan 500
        @(Receive-AppServerRecord -Transport $transport).Count | Should -Be 0
    }
}

Describe 'Codex executable discovery' {
    It 'prefers codex.exe and does not probe later sources after finding it' {
        $script:DiscoveryCalls = [Collections.Generic.List[string]]::new()
        Mock Get-Command {
            param($Name)
            $script:DiscoveryCalls.Add("command:$Name")
            if ($Name -eq 'codex.exe') {
                return [pscustomobject]@{ Path = 'C:\tools\codex.exe'; Source = 'C:\tools\codex.exe' }
            }
        }
        Mock Get-AppxPackage { throw 'Appx discovery should not run.' }

        $result = Find-CodexExecutable

        $result.Status | Should -BeExactly 'Found'
        $result.Found | Should -BeTrue
        $result.ExecutablePath | Should -BeExactly 'C:\tools\codex.exe'
        @($script:DiscoveryCalls) | Should -Be @('command:codex.exe')
        Should -Invoke Get-AppxPackage -Times 0 -Exactly
    }

    It 'checks codex after codex.exe before consulting the package' {
        $script:DiscoveryCalls = [Collections.Generic.List[string]]::new()
        Mock Get-Command {
            param($Name)
            $script:DiscoveryCalls.Add("command:$Name")
            if ($Name -eq 'codex') {
                return [pscustomobject]@{ Path = 'C:\tools\codex.cmd'; Source = 'C:\tools\codex.cmd' }
            }
        }
        Mock Get-AppxPackage { throw 'Appx discovery should not run.' }

        $result = Find-CodexExecutable

        $result.ExecutablePath | Should -BeExactly 'C:\tools\codex.cmd'
        @($script:DiscoveryCalls) | Should -Be @('command:codex.exe', 'command:codex')
        Should -Invoke Get-AppxPackage -Times 0 -Exactly
    }

    It 'uses the packaged Codex path only after both command probes miss' {
        $installLocation = Join-Path $TestDrive 'Codex Package'
        $packagedExecutable = Join-Path $installLocation 'app\resources\codex.exe'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $packagedExecutable) -Force
        $null = New-Item -ItemType File -Path $packagedExecutable
        Mock Get-Command { $null }
        Mock Get-AppxPackage { [pscustomobject]@{ InstallLocation = $installLocation } }

        $result = Find-CodexExecutable

        $result.Status | Should -BeExactly 'Found'
        $result.Source | Should -BeExactly 'AppxPackage'
        $result.ExecutablePath | Should -BeExactly $packagedExecutable
        Should -Invoke Get-Command -Times 2 -Exactly
        Should -Invoke Get-AppxPackage -Times 1 -Exactly -ParameterFilter { $Name -eq 'OpenAI.Codex' }
    }

    It 'returns a structured Missing result when all discovery sources miss' {
        Mock Get-Command { $null }
        Mock Get-AppxPackage { $null }

        $result = Find-CodexExecutable

        $result.Status | Should -BeExactly 'Missing'
        $result.Found | Should -BeFalse
        $result.ExecutablePath | Should -BeNullOrEmpty
        $result.Source | Should -BeNullOrEmpty
    }
}

Describe 'App Server start errors' {
    It 'categorizes a missing executable without echoing the supplied path' {
        $missingPath = Join-Path $TestDrive 'FAKE_MISSING_SECRET\missing.exe'

        try {
            $null = Start-AppServerProcess -ExecutablePath $missingPath -ArgumentList @()
            throw 'Expected process start to fail.'
        }
        catch {
            $startError = $_
        }

        $startError.Exception.Data['AppServerErrorCategory'] | Should -BeExactly 'MissingExecutable'
        $startError.FullyQualifiedErrorId | Should -Match '^AppServerProcess\.MissingExecutable'
        $startError.Exception.Message | Should -Not -Match 'FAKE_MISSING_SECRET'
    }

    It 'categorizes Win32 access denied without exposing the target path' {
        $deniedPath = Join-Path $TestDrive 'FAKE_ACCESS_SECRET'
        $null = New-Item -ItemType Directory -Path $deniedPath

        try {
            $null = Start-AppServerProcess -ExecutablePath $deniedPath -ArgumentList @()
            throw 'Expected process start to fail.'
        }
        catch {
            $startError = $_
        }

        $startError.Exception.Data['AppServerErrorCategory'] | Should -BeExactly 'AccessDenied'
        $startError.FullyQualifiedErrorId | Should -Match '^AppServerProcess\.AccessDenied'
        $startError.Exception.Message | Should -Not -Match 'FAKE_ACCESS_SECRET'
    }

    It 'categorizes other Win32 launch failures without exposing the target path' {
        $invalidExecutable = Join-Path $TestDrive 'FAKE_OTHER_SECRET.txt'
        Set-Content -LiteralPath $invalidExecutable -Value 'not an executable'

        try {
            $null = Start-AppServerProcess -ExecutablePath $invalidExecutable -ArgumentList @()
            throw 'Expected process start to fail.'
        }
        catch {
            $startError = $_
        }

        $startError.Exception.Data['AppServerErrorCategory'] | Should -BeExactly 'StartFailed'
        $startError.FullyQualifiedErrorId | Should -Match '^AppServerProcess\.StartFailed'
        $startError.Exception.Message | Should -Not -Match 'FAKE_OTHER_SECRET'
    }
}
