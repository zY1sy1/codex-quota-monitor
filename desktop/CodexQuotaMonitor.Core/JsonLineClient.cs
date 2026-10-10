using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json.Nodes;

namespace CodexQuotaMonitor.Core;

// The reader bounds each record before parsing; stderr is drained and never logged.
public static class BoundedLines
{
    public static async IAsyncEnumerable<string> ReadAsync(TextReader reader, int limit = 1048576, [EnumeratorCancellation] CancellationToken token = default)
    {
        var buffer = new char[4096]; var line = new StringBuilder();
        while (true)
        {
            var count = await reader.ReadAsync(buffer.AsMemory(), token).ConfigureAwait(false);
            if (count == 0) { if (line.Length > 0) yield return line.ToString().TrimEnd('\r'); yield break; }
            for (var i = 0; i < count; i++)
            {
                if (buffer[i] == '\n') { yield return line.ToString().TrimEnd('\r'); line.Clear(); }
                else { if (line.Length >= limit) throw new InvalidDataException("A process record exceeded the size limit."); line.Append(buffer[i]); }
            }
        }
    }
}

public sealed class JsonLineClient : IAsyncDisposable
{
    private readonly Process process;
    private readonly CancellationTokenSource stopping = new();
    private readonly SemaphoreSlim writer = new(1, 1);
    private readonly ConcurrentDictionary<string, TaskCompletionSource<JsonObject>> pending = new();
    private readonly Task output;
    private readonly Task errors;
    private int nextId;
    private int disposed;
    public event Action<JsonObject>? Notification;
    public int ProcessId => process.Id;
    public int PendingCount => pending.Count;
    public bool Alive => disposed == 0 && !process.HasExited && !output.IsCompleted;

    public JsonLineClient(string executable, IEnumerable<string>? arguments = null)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false) };
        foreach (var argument in arguments ?? Array.Empty<string>()) info.ArgumentList.Add(argument);
        process = new Process { StartInfo = info };
        try { if (!process.Start()) throw new IOException("The process could not be started."); }
        catch { process.Dispose(); throw; }
        output = PumpAsync(); errors = DrainErrorsAsync();
    }
    private async Task PumpAsync()
    {
        try
        {
            await foreach (var line in BoundedLines.ReadAsync(process.StandardOutput, token: stopping.Token).ConfigureAwait(false))
            {
                if (line.Length == 0) continue;
                var message = JsonData.Parse(line);
                var id = message["id"];
                var key = id is JsonValue v && v.TryGetValue<string>(out var s) ? s : id?.ToJsonString();
                if (key is not null && pending.TryRemove(key, out var completion)) completion.TrySetResult(message);
                else if (message["method"] is not null && id is null) Notification?.Invoke(message);
                // Unsolicited response IDs are discarded; they cannot grow a cache.
            }
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or System.Text.Json.JsonException or OperationCanceledException or ObjectDisposedException) { }
        finally
        {
            foreach (var pair in pending) if (pending.TryRemove(pair.Key, out var completion)) completion.TrySetException(new IOException("The process connection closed."));
        }
    }
    private async Task DrainErrorsAsync()
    {
        try { var buffer = new char[4096]; while (await process.StandardError.ReadAsync(buffer.AsMemory(), stopping.Token).ConfigureAwait(false) > 0) { } }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException) { }
    }
    public async Task<JsonObject> RequestAsync(JsonObject command, TimeSpan timeout, CancellationToken token = default)
    {
        ObjectDisposedException.ThrowIf(disposed != 0, this);
        var id = command["id"];
        var key = id is JsonValue v && v.TryGetValue<string>(out var s) ? s : id?.ToJsonString() ?? throw new ArgumentException("A request ID is required.");
        var completion = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!pending.TryAdd(key, completion)) throw new InvalidOperationException("Duplicate request ID.");
        try
        {
            await SendAsync(command, token).ConfigureAwait(false);
            return await completion.Task.WaitAsync(timeout, token).ConfigureAwait(false);
        }
        finally { pending.TryRemove(key, out _); }
    }
    public async Task<JsonObject> RpcAsync(string method, JsonObject? parameters, CancellationToken token = default)
    {
        var command = new JsonObject { ["id"] = Interlocked.Increment(ref nextId), ["method"] = method };
        if (parameters is not null) command["params"] = parameters;
        var response = await RequestAsync(command, TimeSpan.FromSeconds(10), token).ConfigureAwait(false);
        if (response["error"] is not null) throw new InvalidDataException("The App Server rejected the request.");
        return response["result"] as JsonObject ?? throw new InvalidDataException("The App Server returned an invalid result.");
    }
    public async Task SendAsync(JsonObject message, CancellationToken token = default)
    {
        await writer.WaitAsync(token).ConfigureAwait(false);
        try { await process.StandardInput.WriteLineAsync(message.ToJsonString().AsMemory(), token).ConfigureAwait(false); await process.StandardInput.FlushAsync(token).ConfigureAwait(false); }
        finally { writer.Release(); }
    }
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        stopping.Cancel();
        try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { }
        try { await Task.WhenAll(output, errors).WaitAsync(TimeSpan.FromSeconds(3)).ConfigureAwait(false); } catch (TimeoutException) { }
        process.Dispose(); stopping.Dispose();
    }
}
