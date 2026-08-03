[CmdletBinding()]
param(
    [switch]$RunServer,
    [ValidateRange(1, 65535)][int]$Port = 0,
    [ValidateSet('Happy', 'Zero', 'RateLimited', 'Auth', 'InvalidJson', 'Slow')]
    [string]$Scenario = 'Happy',
    [ValidateRange(0, 30000)][int]$DelayMilliseconds = 5000,
    [string]$ReadyFile,
    [string]$StopFile,
    [string]$StatsFile
)

$ErrorActionPreference = 'Stop'

function Get-FakeRelayFreePort {
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $probe.Start()
        return ([Net.IPEndPoint]$probe.LocalEndpoint).Port
    }
    finally {
        $probe.Stop()
    }
}

function Start-FakeRelayApi {
    [CmdletBinding()]
    param(
        [ValidateSet('Happy', 'Zero', 'RateLimited', 'Auth', 'InvalidJson', 'Slow')]
        [string]$Scenario = 'Happy',
        [ValidateRange(0, 30000)][int]$DelayMilliseconds = 5000
    )

    $root = Join-Path ([IO.Path]::GetTempPath()) ('CodexQuotaMonitor-FakeRelay-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $port = Get-FakeRelayFreePort
    $readyFile = Join-Path $root 'ready.txt'
    $stopFile = Join-Path $root 'stop.signal'
    $statsFile = Join-Path $root 'stats.json'
    $stdoutFile = Join-Path $root 'server.stdout'
    $stderrFile = Join-Path $root 'server.stderr'
    $pwsh = (Get-Process -Id $PID).Path
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $PSCommandPath,
        '-RunServer', '-Port', $port, '-Scenario', $Scenario,
        '-DelayMilliseconds', $DelayMilliseconds, '-ReadyFile', $readyFile,
        '-StopFile', $stopFile, '-StatsFile', $statsFile
    )
    $process = Start-Process -FilePath $pwsh -ArgumentList $arguments -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -PassThru
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $readyFile -PathType Leaf) -and
        -not $process.HasExited -and [DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 25
    }
    if ($process.HasExited -or -not (Test-Path -LiteralPath $readyFile -PathType Leaf)) {
        try { if (-not $process.HasExited) { $process.Kill($true) } } catch { }
        $diagnostic = if (Test-Path -LiteralPath $stderrFile -PathType Leaf) {
            [IO.File]::ReadAllText($stderrFile)
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        throw "Fake relay API could not start: $diagnostic Args=$($arguments -join '|')"
    }

    $api = [pscustomobject][ordered]@{
        BaseUrl = "http://127.0.0.1:$port"
        Port = $port
        Process = $process
        Root = $root
        StopFile = $stopFile
        StatsFile = $statsFile
    }
    $api | Add-Member -MemberType ScriptProperty -Name Stats -Value {
        if (-not (Test-Path -LiteralPath $this.StatsFile -PathType Leaf)) {
            return [pscustomobject]@{ TotalRequests = 0; MaxConcurrent = 0 }
        }
        try {
            return Get-Content -LiteralPath $this.StatsFile -Raw | ConvertFrom-Json
        }
        catch {
            return [pscustomobject]@{ TotalRequests = 0; MaxConcurrent = 0 }
        }
    }
    return $api
}

function Stop-FakeRelayApi {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Api)

    if ($null -eq $Api.Process) {
        return
    }
    try {
        [IO.File]::WriteAllText($Api.StopFile, 'stop')
        if (-not $Api.Process.WaitForExit(5000)) {
            try { $Api.Process.Kill($true) } catch { }
            $Api.Process.WaitForExit(1000) | Out-Null
        }
    }
    catch { }
    finally {
        Remove-Item -LiteralPath $Api.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($RunServer) {
    if ([string]::IsNullOrWhiteSpace($ReadyFile) -or
        [string]::IsNullOrWhiteSpace($StopFile) -or
        [string]::IsNullOrWhiteSpace($StatsFile) -or
        $Port -le 0) {
        throw 'Fake relay API server arguments are invalid.'
    }

    $source = @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class CodexQuotaFakeRelayServer
{
    private readonly int port;
    private readonly string scenario;
    private readonly int delayMilliseconds;
    private readonly string readyFile;
    private readonly string statsFile;
    private readonly HttpListener listener = new HttpListener();
    private readonly ConcurrentDictionary<string, int> paths = new ConcurrentDictionary<string, int>(StringComparer.Ordinal);
    private readonly object statsGate = new object();
    private volatile bool running;
    private int active;
    private int maxConcurrent;
    private int totalRequests;

    public CodexQuotaFakeRelayServer(int port, string scenario, int delayMilliseconds, string readyFile, string statsFile)
    {
        this.port = port;
        this.scenario = scenario;
        this.delayMilliseconds = delayMilliseconds;
        this.readyFile = readyFile;
        this.statsFile = statsFile;
    }

    public void Start()
    {
        listener.Prefixes.Add("http://127.0.0.1:" + port + "/");
        listener.Start();
        running = true;
        File.WriteAllText(readyFile, port.ToString(System.Globalization.CultureInfo.InvariantCulture), new UTF8Encoding(false));
        Task.Run((Action)ListenLoop);
        WriteStats();
    }

    public void Stop()
    {
        running = false;
        try { listener.Stop(); } catch { }
        try { listener.Close(); } catch { }
        WriteStats();
    }

    private void ListenLoop()
    {
        while (running)
        {
            HttpListenerContext context;
            try { context = listener.GetContext(); }
            catch { break; }
            _ = Task.Run(() => Handle(context));
        }
    }

    private void Handle(HttpListenerContext context)
    {
        string path = context.Request.Url == null ? "/" : context.Request.Url.AbsolutePath;
        int current = Interlocked.Increment(ref active);
        while (true)
        {
            int previous = Volatile.Read(ref maxConcurrent);
            if (current <= previous || Interlocked.CompareExchange(ref maxConcurrent, current, previous) == previous) break;
        }
        int status = 200;
        string body = "{\"success\":true,\"data\":{\"balance\":1,\"currency\":\"USD\"}}";
        try
        {
            if (scenario == "Slow" || path == "/slow") Thread.Sleep(delayMilliseconds);
            if (scenario == "RateLimited" && path == "/rate-limit")
            {
                status = 429;
                body = "{\"success\":false,\"message\":\"rate limited\"}";
                context.Response.Headers["Retry-After"] = "4";
            }
            else if (scenario == "Auth" && path == "/auth")
            {
                status = 401;
                body = "{\"success\":false,\"message\":\"authentication required\"}";
            }
            else if (scenario == "InvalidJson" && path == "/invalid-json")
            {
                body = "not-json";
                context.Response.ContentType = "text/plain";
            }
            else if (scenario == "Zero" && path == "/v1/usage")
            {
                body = "{\"success\":true,\"data\":{\"balance\":0,\"currency\":\"USD\",\"planName\":\"Zero\"}}";
            }
            else if (path == "/v1/usage")
            {
                body = "{\"success\":true,\"data\":{\"plans\":[{\"name\":\"Five Hour\",\"remaining\":8,\"total\":10,\"used\":2,\"unit\":\"USD\"},{\"name\":\"Weekly\",\"remaining\":80,\"total\":100,\"used\":20,\"unit\":\"USD\"}]}}";
            }
            else if (path == "/user/balance")
            {
                body = "{\"success\":true,\"data\":{\"balance\":42,\"currency\":\"USD\",\"planName\":\"General\"}}";
            }
            else if (path == "/api/user/self")
            {
                body = "{\"success\":true,\"data\":{\"quota\":7,\"currency\":\"USD\",\"username\":\"NewApi\"}}";
            }
            else if (path == "/rate-limit")
            {
                body = "{\"success\":true,\"data\":{\"balance\":3,\"currency\":\"USD\",\"planName\":\"RateLimit\"}}";
            }
            else if (path == "/slow")
            {
                body = "{\"success\":true,\"data\":{\"balance\":11,\"currency\":\"USD\",\"planName\":\"Slow\"}}";
            }
            else if (path == "/auth")
            {
                status = 401;
                body = "{\"success\":false,\"message\":\"authentication required\"}";
            }

            byte[] bytes = Encoding.UTF8.GetBytes(body);
            context.Response.StatusCode = status;
            context.Response.ContentLength64 = bytes.Length;
            context.Response.OutputStream.Write(bytes, 0, bytes.Length);
        }
        catch { }
        finally
        {
            try { context.Response.Close(); } catch { }
            paths.AddOrUpdate(path, 1, (key, value) => value + 1);
            Interlocked.Increment(ref totalRequests);
            Interlocked.Decrement(ref active);
            WriteStats();
        }
    }

    private void WriteStats()
    {
        lock (statsGate)
        {
            string json = "{\"totalRequests\":" + Volatile.Read(ref totalRequests).ToString(System.Globalization.CultureInfo.InvariantCulture)
                + ",\"maxConcurrent\":" + Volatile.Read(ref maxConcurrent).ToString(System.Globalization.CultureInfo.InvariantCulture) + "}";
            try { File.WriteAllText(statsFile, json, new UTF8Encoding(false)); } catch { }
        }
    }
}
'@
    try {
        $serverType = Add-Type -TypeDefinition $source -Language CSharp -PassThru
        $server = $serverType::new($Port, $Scenario, $DelayMilliseconds, $ReadyFile, $StatsFile)
        $server.Start()
        try {
            while (-not (Test-Path -LiteralPath $StopFile -PathType Leaf)) {
                Start-Sleep -Milliseconds 50
            }
        }
        finally {
            $server.Stop()
        }
    }
    catch {
        [Console]::Error.WriteLine(($_ | Out-String -Width 4096))
        exit 1
    }
    exit 0
}
