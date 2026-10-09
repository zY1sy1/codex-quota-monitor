using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Threading;

namespace CodexQuotaMonitor.ProcessTransport.V2
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
            @"\b(?:authorization|access(?:_|-)?token|refresh(?:_|-)?token|api(?:_|-)?key|cookie|(?:user(?:_|-)?)?e(?:_|-)?mail|client(?:_|-)?secret|password|passwd|credentials?|private(?:_|-)?key|id(?:_|-)?token|token(?:_|-)?id|session(?:_|-)?id|auth(?:_|-)?id|session|secret)\b",
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
        private readonly CountdownEvent streamEof = new CountdownEvent(2);
        private volatile bool accepting = true;
        private int stopStarted;
        private int stdoutEof;
        private int stderrEof;

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
                if (eventArgs.Data == null)
                {
                    SignalStreamEof(stream);
                    return;
                }

                if (!accepting)
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

        public bool WaitForStreamEof(int milliseconds)
        {
            return streamEof.Wait(milliseconds);
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

        private void SignalStreamEof(string stream)
        {
            int wasSignaled;
            if (String.Equals(stream, "stdout", StringComparison.Ordinal))
            {
                wasSignaled = Interlocked.Exchange(ref stdoutEof, 1);
            }
            else if (String.Equals(stream, "stderr", StringComparison.Ordinal))
            {
                wasSignaled = Interlocked.Exchange(ref stderrEof, 1);
            }
            else
            {
                return;
            }

            if (wasSignaled == 0)
            {
                streamEof.Signal();
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
