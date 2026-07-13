$typeLoadMutex = [System.Threading.Mutex]::new(
    $false,
    'Local\CodexQuotaMonitor.AppServerProcess.TypeLoad.v1'
)
$typeLoadMutexAcquired = $false

try {
    try {
        $typeLoadMutexAcquired = $typeLoadMutex.WaitOne(30000)
    }
    catch [System.Threading.AbandonedMutexException] {
        $typeLoadMutexAcquired = $true
    }

    if (-not $typeLoadMutexAcquired) {
        throw [System.TimeoutException]::new('Timed out while initializing the App Server transport types.')
    }

    if ($null -eq ('CodexQuotaMonitor.ProcessTransport.CaptureState' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Threading;

namespace CodexQuotaMonitor.ProcessTransport
{
    public sealed class AppServerRecord
    {
        public AppServerRecord(string stream, string line, DateTimeOffset receivedAt)
        {
            Stream = stream;
            Line = line;
            ReceivedAt = receivedAt;
        }

        public string Stream { get; private set; }
        public string Line { get; private set; }
        public DateTimeOffset ReceivedAt { get; private set; }
    }

    public sealed class CaptureState
    {
        private const string Redacted = "[REDACTED]";
        private const string Truncated = " [truncated]";

        private static readonly Regex SensitiveKeyPattern = new Regex(
            @"\b(?:authorization|access(?:_|-)?token|refresh(?:_|-)?token|api(?:_|-)?key|cookie|(?:user(?:_|-)?)?e(?:_|-)?mail|client(?:_|-)?secret|password|passwd|credentials?|private(?:_|-)?key|session|secret)\b",
            RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

        private static readonly Regex BearerPattern = new Regex(
            @"\bbearer\s+[A-Za-z0-9._~+/=-]+",
            RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

        private static readonly Regex EmailPattern = new Regex(
            @"[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}.\-]+\.[\p{L}]{2,}",
            RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

        private static readonly Regex TokenPattern = new Regex(
            @"\b(?:sk|sess)-[A-Za-z0-9_-]+\b",
            RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

        private readonly object syncRoot = new object();
        private readonly ManualResetEventSlim stopCompleted = new ManualResetEventSlim(false);
        private volatile bool accepting = true;
        private int stopStarted;

        public CaptureState(int stdoutLimit, int stderrLimit, int diagnosticLineLimit)
        {
            StdoutLimit = stdoutLimit;
            StderrLimit = stderrLimit;
            DiagnosticLineLimit = diagnosticLineLimit;
            Queue = new ConcurrentQueue<object>();
        }

        public ConcurrentQueue<object> Queue { get; private set; }
        public int StdoutLimit { get; private set; }
        public int StderrLimit { get; private set; }
        public int DiagnosticLineLimit { get; private set; }

        public DataReceivedEventHandler CreateHandler(string stream)
        {
            return delegate(object sender, DataReceivedEventArgs eventArgs)
            {
                if (!accepting || eventArgs.Data == null)
                {
                    return;
                }

                string line = stream == "stderr"
                    ? SanitizeDiagnostic(eventArgs.Data, DiagnosticLineLimit)
                    : eventArgs.Data;

                EnqueueBounded(new AppServerRecord(stream, line, DateTimeOffset.UtcNow));
            };
        }

        public object[] Drain(int maximum)
        {
            var records = new List<object>(maximum);
            lock (syncRoot)
            {
                object record;
                while (records.Count < maximum && Queue.TryDequeue(out record))
                {
                    records.Add(record);
                }
            }

            return records.ToArray();
        }

        public void StopAccepting()
        {
            lock (syncRoot)
            {
                accepting = false;
            }
        }

        public bool TryBeginStop()
        {
            return Interlocked.CompareExchange(ref stopStarted, 1, 0) == 0;
        }

        public void CompleteStop()
        {
            stopCompleted.Set();
        }

        public bool WaitForStop(int milliseconds)
        {
            return stopCompleted.Wait(milliseconds);
        }

        private void EnqueueBounded(AppServerRecord record)
        {
            lock (syncRoot)
            {
                if (!accepting)
                {
                    return;
                }

                Queue.Enqueue(record);
                int limit = record.Stream == "stdout" ? StdoutLimit : StderrLimit;
                while (CountStream(record.Stream) > limit)
                {
                    if (!RemoveOldest(record.Stream))
                    {
                        break;
                    }
                }
            }
        }

        private int CountStream(string stream)
        {
            int count = 0;
            foreach (object item in Queue)
            {
                var record = item as AppServerRecord;
                if (record != null && String.Equals(record.Stream, stream, StringComparison.Ordinal))
                {
                    count++;
                }
            }

            return count;
        }

        private bool RemoveOldest(string stream)
        {
            var retained = new List<object>();
            bool removed = false;
            object item;
            while (Queue.TryDequeue(out item))
            {
                var record = item as AppServerRecord;
                if (!removed && record != null && String.Equals(record.Stream, stream, StringComparison.Ordinal))
                {
                    removed = true;
                    continue;
                }

                retained.Add(item);
            }

            foreach (object retainedItem in retained)
            {
                Queue.Enqueue(retainedItem);
            }

            return removed;
        }

        private static string SanitizeDiagnostic(string line, int maximumLength)
        {
            int preliminaryLimit = Math.Max(maximumLength, Math.Min(65536, maximumLength * 4));
            string sanitized = line.Length > preliminaryLimit ? line.Substring(0, preliminaryLimit) : line;
            if (SensitiveKeyPattern.IsMatch(sanitized) ||
                BearerPattern.IsMatch(sanitized) ||
                EmailPattern.IsMatch(sanitized) ||
                TokenPattern.IsMatch(sanitized))
            {
                return Redacted;
            }

            return CapLine(sanitized, maximumLength);
        }

        private static string CapLine(string line, int maximumLength)
        {
            if (line.Length <= maximumLength)
            {
                return line;
            }

            int contentLength;
            string suffix;
            if (maximumLength <= Truncated.Length)
            {
                contentLength = maximumLength;
                suffix = String.Empty;
            }
            else
            {
                contentLength = maximumLength - Truncated.Length;
                suffix = Truncated;
            }

            if (contentLength > 0 &&
                contentLength < line.Length &&
                Char.IsHighSurrogate(line[contentLength - 1]) &&
                Char.IsLowSurrogate(line[contentLength]))
            {
                contentLength--;
            }

            return line.Substring(0, contentLength) + suffix;
        }
    }
}
'@
    }

function New-AppServerStartErrorRecord {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('MissingExecutable', 'AccessDenied', 'StartFailed')]
        [string]$Category
    )

    $message = switch ($Category) {
        'MissingExecutable' { 'The Codex App Server executable was not found.' }
        'AccessDenied' { 'Access to the Codex App Server executable was denied.' }
        default { 'The Codex App Server process could not be started.' }
    }
    $errorCategory = switch ($Category) {
        'MissingExecutable' { [Management.Automation.ErrorCategory]::ObjectNotFound }
        'AccessDenied' { [Management.Automation.ErrorCategory]::PermissionDenied }
        default { [Management.Automation.ErrorCategory]::OpenError }
    }

    $exception = [InvalidOperationException]::new($message)
    $exception.Data['AppServerErrorCategory'] = $Category
    return [Management.Automation.ErrorRecord]::new(
        $exception,
        "AppServerProcess.$Category",
        $errorCategory,
        $null
    )
}

function New-AppServerTransportClosedErrorRecord {
    $exception = [InvalidOperationException]::new('The App Server process transport is closed.')
    $exception.Data['AppServerErrorCategory'] = 'TransportClosed'
    return [Management.Automation.ErrorRecord]::new(
        $exception,
        'AppServerProcess.TransportClosed',
        [Management.Automation.ErrorCategory]::ResourceUnavailable,
        $null
    )
}

function Get-AppServerRootException {
    param(
        [Parameter(Mandatory)]
        [Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current.InnerException) {
        $current = $current.InnerException
    }

    return $current
}

function Find-CodexExecutable {
    [CmdletBinding()]
    param()

    foreach ($commandName in @('codex.exe', 'codex')) {
        $commands = @()
        try {
            $commands = @(Get-Command -Name $commandName -ErrorAction SilentlyContinue)
        }
        catch {
            $commands = @()
        }

        foreach ($command in $commands) {
            $commandType = Get-ObjectField -InputObject $command -Name 'CommandType'
            if ($commandType -notin @(
                    [Management.Automation.CommandTypes]::Application,
                    [Management.Automation.CommandTypes]::ExternalScript
                )) {
                continue
            }

            $candidatePaths = @(
                Get-ObjectField -InputObject $command -Name 'Path'
                Get-ObjectField -InputObject $command -Name 'Source'
            )
            $seenPaths = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase
            )
            foreach ($path in $candidatePaths) {
                $path = [string]$path
                if ([string]::IsNullOrWhiteSpace($path) -or -not $seenPaths.Add($path)) {
                    continue
                }

                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    return [pscustomobject][ordered]@{
                        Status = 'Found'
                        Found = $true
                        ExecutablePath = $path
                        Source = "Command:$commandName"
                    }
                }
            }
        }
    }

    $packages = @()
    try {
        $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)
    }
    catch {
        $packages = @()
    }

    foreach ($package in $packages) {
        $installLocation = [string](Get-ObjectField -InputObject $package -Name 'InstallLocation')
        if ([string]::IsNullOrWhiteSpace($installLocation)) {
            continue
        }

        $candidate = Join-Path $installLocation 'app\resources\codex.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [pscustomobject][ordered]@{
                Status = 'Found'
                Found = $true
                ExecutablePath = $candidate
                Source = 'AppxPackage'
            }
        }
    }

    return [pscustomobject][ordered]@{
        Status = 'Missing'
        Found = $false
        ExecutablePath = $null
        Source = $null
    }
}

function Start-AppServerProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ExecutablePath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList,

        [string]$WorkingDirectory,

        [ValidateRange(1, 1000000)]
        [int]$StdoutRecordLimit = 1000,

        [ValidateRange(1, 1000000)]
        [int]$StderrRecordLimit = 200,

        [ValidateRange(32, 65536)]
        [int]$DiagnosticLineLimit = 2048
    )

    if ([IO.Path]::IsPathFullyQualified($ExecutablePath) -and
        -not (Test-Path -LiteralPath $ExecutablePath)) {
        throw (New-AppServerStartErrorRecord -Category MissingExecutable)
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $utf8WithoutBom = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardInputEncoding = $utf8WithoutBom
    $startInfo.StandardOutputEncoding = $utf8WithoutBom
    $startInfo.StandardErrorEncoding = $utf8WithoutBom

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    foreach ($argument in @($ArgumentList)) {
        $startInfo.ArgumentList.Add([string]$argument)
    }

    $captureState = [CodexQuotaMonitor.ProcessTransport.CaptureState]::new(
        $StdoutRecordLimit,
        $StderrRecordLimit,
        $DiagnosticLineLimit
    )
    $outputHandler = $captureState.CreateHandler('stdout')
    $errorHandler = $captureState.CreateHandler('stderr')
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $process.add_OutputDataReceived($outputHandler)
    $process.add_ErrorDataReceived($errorHandler)
    $started = $false

    try {
        $started = $process.Start()
        if (-not $started) {
            throw [InvalidOperationException]::new('Process.Start returned false.')
        }

        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        $stdinWriter = $process.StandardInput
        $stdinWriter.AutoFlush = $false
    }
    catch {
        $rootException = Get-AppServerRootException -Exception $_.Exception
        $category = if ($rootException -is [UnauthorizedAccessException] -or
            ($rootException -is [ComponentModel.Win32Exception] -and $rootException.NativeErrorCode -eq 5)) {
            'AccessDenied'
        }
        elseif ($rootException -is [ComponentModel.Win32Exception] -and $rootException.NativeErrorCode -in @(2, 3)) {
            'MissingExecutable'
        }
        else {
            'StartFailed'
        }

        $captureState.StopAccepting()
        try { $process.remove_OutputDataReceived($outputHandler) } catch {}
        try { $process.remove_ErrorDataReceived($errorHandler) } catch {}
        if ($started) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                    $null = $process.WaitForExit(2000)
                }
            }
            catch {}
        }
        $process.Dispose()

        throw (New-AppServerStartErrorRecord -Category $category)
    }

    return [pscustomobject][ordered]@{
        Process = $process
        Queue = $captureState.Queue
        CaptureState = $captureState
        OutputHandler = $outputHandler
        ErrorHandler = $errorHandler
        CallbackResources = @($outputHandler, $errorHandler)
        StdinWriter = $stdinWriter
        IoLock = [object]::new()
        StdoutRecordLimit = $StdoutRecordLimit
        StderrRecordLimit = $StderrRecordLimit
        DiagnosticLineLimit = $DiagnosticLineLimit
        Stopped = $false
        Disposed = $false
        StdinClosed = $false
        WasKilled = $false
        ExitCode = $null
    }
}

function Receive-AppServerRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Transport,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$Maximum = 100
    )

    foreach ($record in $Transport.CaptureState.Drain($Maximum)) {
        Write-Output $record
    }
}

function Send-AppServerMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Transport,

        [Parameter(Mandatory)]
        [object]$Message
    )

    $line = [string](ConvertTo-JsonLine -Message $Message)
    $line = $line.TrimEnd([char]13, [char]10) + [string][char]10
    $lockTaken = $false
    try {
        [Threading.Monitor]::Enter($Transport.IoLock, [ref]$lockTaken)

        if ($Transport.Stopped -or $Transport.Disposed -or $Transport.StdinClosed) {
            throw (New-AppServerTransportClosedErrorRecord)
        }

        $hasExited = $true
        try { $hasExited = $Transport.Process.HasExited } catch { $hasExited = $true }
        if ($hasExited) {
            try { $Transport.StdinWriter.Close() } catch {}
            $Transport.StdinClosed = $true
            throw (New-AppServerTransportClosedErrorRecord)
        }

        try {
            $Transport.StdinWriter.Write($line)
            $Transport.StdinWriter.Flush()
        }
        catch [IO.IOException] {
            try { $Transport.StdinWriter.Close() } catch {}
            $Transport.StdinClosed = $true
            throw (New-AppServerTransportClosedErrorRecord)
        }
        catch [ObjectDisposedException] {
            $Transport.StdinClosed = $true
            throw (New-AppServerTransportClosedErrorRecord)
        }
        catch [InvalidOperationException] {
            try { $Transport.StdinWriter.Close() } catch {}
            $Transport.StdinClosed = $true
            throw (New-AppServerTransportClosedErrorRecord)
        }
    }
    finally {
        if ($lockTaken) {
            [Threading.Monitor]::Exit($Transport.IoLock)
        }
    }
}

function Stop-AppServerProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Transport,

        [ValidateRange(1, 60000)]
        [int]$TimeoutMilliseconds = 2000
    )

    if ($null -eq $Transport) {
        return
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    if (-not $Transport.CaptureState.TryBeginStop()) {
        $remaining = [Math]::Max(0, $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds)
        if ($remaining -gt 0) {
            $null = $Transport.CaptureState.WaitForStop($remaining)
        }
        return
    }

    $process = $Transport.Process
    $stdinWriter = $Transport.StdinWriter

    try {
        $ioLockTaken = $false
        try {
            [Threading.Monitor]::Enter($Transport.IoLock, [ref]$ioLockTaken)
            $Transport.Stopped = $true
            if (-not $Transport.StdinClosed -and $null -ne $stdinWriter) {
                try { $stdinWriter.Close() } catch {}
                $Transport.StdinClosed = $true
            }
        }
        finally {
            if ($ioLockTaken) {
                [Threading.Monitor]::Exit($Transport.IoLock)
            }
        }

        $hasExited = $false
        try { $hasExited = $process.HasExited } catch { $hasExited = $true }
        if (-not $hasExited) {
            $remaining = [Math]::Max(0, $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds)
            if ($remaining -gt 0) {
                try { $hasExited = $process.WaitForExit($remaining) } catch { $hasExited = $false }
            }
        }

        if (-not $hasExited) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                    $Transport.WasKilled = $true
                }
            }
            catch {}

            $remaining = [Math]::Max(0, $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds)
            if ($remaining -gt 0) {
                try { $null = $process.WaitForExit($remaining) } catch {}
            }
        }

        try {
            if ($process.HasExited) {
                $Transport.ExitCode = $process.ExitCode
            }
        }
        catch {}
    }
    finally {
        try {
            $Transport.CaptureState.StopAccepting()
            try { $process.CancelOutputRead() } catch {}
            try { $process.CancelErrorRead() } catch {}
            try { $process.remove_OutputDataReceived($Transport.OutputHandler) } catch {}
            try { $process.remove_ErrorDataReceived($Transport.ErrorHandler) } catch {}
            try { $stdinWriter.Dispose() } catch {}
            try { $process.Dispose() } catch {}
            $Transport.Disposed = $true
        }
        finally {
            $Transport.CaptureState.CompleteStop()
        }
    }
}
}
finally {
    if ($typeLoadMutexAcquired) {
        try { $typeLoadMutex.ReleaseMutex() } catch {}
    }

    $typeLoadMutex.Dispose()
}
