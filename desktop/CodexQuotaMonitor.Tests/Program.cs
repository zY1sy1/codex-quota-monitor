using System.Diagnostics;
using System.IO;
using System.Text.Json.Nodes;
using CodexQuotaMonitor.Core;
using CodexQuotaMonitor.Desktop;

namespace CodexQuotaMonitor.Tests;

public static class Program
{
    private static int count;
    private static string root = "";
    private static string testRoot = "";
    private static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static void Test(string name, Action action) { action(); count++; Console.WriteLine("PASS " + name); }
    private static void Throws<T>(Action action) where T : Exception { try { action(); } catch (T) { return; } throw new InvalidOperationException("Expected " + typeof(T).Name); }
    private static RelayProvider Provider() => new() { BaseUrl = "https://example.com", Name = "Test", RequestDefinition = JsonData.Parse("""{"Method":"GET","Path":"/balance","Query":{},"Headers":{"Authorization":"Bearer {{apiKey}}"},"Body":null}"""), ExtractorScript = "function(r){return {isValid:true,remaining:r.balance,unit:'USD'};}" };
    private static JsonObject Response(double amount = 10) => new() { ["ok"] = true, ["results"] = new JsonArray(new JsonObject { ["isValid"] = true, ["remaining"] = amount, ["unit"] = "USD", ["total"] = null }) };
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.FirstOrDefault() == "--fixture-rpc") return Fixture(args.Skip(1).FirstOrDefault() ?? "chatgpt");
        root = args.FirstOrDefault() ?? throw new ArgumentException("Repository root required."); testRoot = Path.Combine(root, "outputs", "desktop", "tests", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(testRoot);
        try
        {
            CoreTests(); WindowsCompatibilityChecks.Run(root, Test); TransportTests().GetAwaiter().GetResult(); RelayHostTest(); RuntimeTests();
            JsonFiles.Write(Path.Combine(testRoot, "result.json"), new JsonObject { ["Passed"] = true, ["Count"] = count });
            Console.WriteLine($"{count} checks passed. Results: {testRoot}"); return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
    }
    private static void CoreTests()
    {
        foreach (var fixture in Directory.GetFiles(Path.Combine(root, "tests", "Fixtures", "RateLimits"), "*.json"))
            Test("quota fixture " + Path.GetFileName(fixture), () => { var rows = Quota.Normalize(JsonData.Parse(File.ReadAllText(fixture))); Assert(rows.Count > 0 && rows.Select(r => r.Key).Distinct().Count() == rows.Count, "Quota windows were lost or duplicated."); });
        Test("quota clamp and missing values", () =>
        {
            var windows = Quota.Normalize(JsonData.Parse("""{"rateLimits":{"primary":{"usedPercent":130,"windowDurationMins":300},"secondary":{"usedPercent":-5,"windowDurationMins":10080}}}"""));
            Assert(windows[0].Remaining == 0 && windows[1].Remaining == 100, "Invalid quota clamp.");
            windows = Quota.Normalize(JsonData.Parse("""{"rateLimits":{"primary":{"usedPercent":null}}}""")); Assert(windows[0].Remaining is null, "Unknown quota became zero.");
        });
        Test("quota windows and countdown", () => { Assert(Quota.Label(300, "") == "5 小时额度" && Quota.Label(10080, "") == "周额度", "Window labels changed."); Assert(Quota.Countdown(0, DateTimeOffset.UtcNow) == "重置时间未知", "Unknown reset was fabricated."); Assert(Quota.Countdown(1, DateTimeOffset.UtcNow) == "正在刷新", "Expired reset is incorrect."); });
        Test("settings schema and round trip", () => { var settings = new MonitorSettings(); settings.Mode = "Orb"; settings.Theme = "Light"; settings.Topmost = false; settings.Position("Orb")["Left"] = -100d; var restored = new MonitorSettings(JsonData.Parse(settings.Document.ToJsonString())); Assert(restored.Mode == "Orb" && restored.Theme == "Light" && !restored.Topmost && restored.Position("Orb")["Left"].Number() == -100, "Settings were not preserved."); Throws<InvalidDataException>(() => new MonitorSettings(JsonData.Parse("""{"SchemaVersion":99}"""))); });
        Test("legacy settings migration", () => { var settings = new MonitorSettings(JsonData.Parse("""{"SchemaVersion":1,"Window":{"Left":80,"Top":100,"Topmost":false,"Visible":false},"Startup":false}""")); Assert(settings.Position("Full")["Left"].Number() == 80 && !settings.Topmost && !settings.Visible && !settings.Startup, "Legacy preferences changed."); });
        Test("schema 2 keeps all mode positions and focus", () => { var old = MonitorSettings.Defaults(); old["SchemaVersion"] = 2; old.Remove("Relay"); old["Window"]!["Orb"]!["Left"] = -320d; old["Compact"]!["FocusMetric"] = "relay:existing:0"; var settings = new MonitorSettings(old); Assert(settings.Position("Orb")["Left"].Number() == -320 && settings.Focus == "relay:existing:0" && settings.TodaySpend, "Schema 2 preferences were discarded."); });
        Test("encrypted provider compatibility", () => { var provider = Provider(); provider.Secrets["ApiKey"] = NativeSecrets.Protect("synthetic-credential-for-test"); var document = RelayProvider.Document(new[] { provider }); Assert(!document.ToJsonString().Contains("synthetic-credential-for-test", StringComparison.Ordinal), "Plain credential leaked."); var restored = RelayProvider.ReadDocument(JsonData.Parse(document.ToJsonString()))[0]; Assert(NativeSecrets.Unprotect(restored.Secrets["ApiKey"].Text()) == "synthetic-credential-for-test", "Existing DPAPI format is incompatible."); });
        Test("provider destination validation", () => { Throws<InvalidDataException>(() => RelayProvider.Origin("http://example.com")); Throws<InvalidDataException>(() => RelayProvider.Origin("https://user:pass@example.com")); Assert(RelayProvider.Origin("http://127.0.0.1:3000/base") == "http://127.0.0.1:3000", "Loopback rejected."); var provider = Provider(); provider.RequestDefinition!["Path"] = "//outside.example"; Throws<InvalidDataException>(provider.Validate); });
        Test("provider interval and identity validation", () => { var provider = Provider(); provider.IntervalMinutes = 0; provider.Validate(); provider.IntervalMinutes = 1441; Throws<InvalidDataException>(provider.Validate); provider.IntervalMinutes = 5; provider.Id = Guid.Empty.ToString(); Throws<InvalidDataException>(provider.Validate); });
        Test("schema 1 provider migrates to Custom", () => { var provider = Provider().ToJson(); provider.Remove("ProviderKind"); provider.Remove("RequestDefinition"); provider.Remove("ExtractorScript"); provider["Script"] = "({request:{url:baseUrl},extractor:function(r){return r;}})"; provider["TemplateType"] = "general"; var restored = RelayProvider.ReadDocument(new JsonObject { ["SchemaVersion"] = 1, ["Providers"] = new JsonArray(provider) }); Assert(restored[0].ProviderKind == "Custom" && restored[0].RequestDefinition is null, "Legacy script was discarded."); });
        Test("safe script conversion", () => { const string code = "({request:{url:baseUrl+'/balance',method:'GET',headers:{Authorization:'Bearer '+apiKey}},extractor:function(r){return {isValid:true,remaining:r.balance};}})"; Assert(UsageScriptConversion.TryGeneric(code, "https://example.com", out var request, out var extractor) && request!["Path"].Text() == "/balance" && request["Headers"]!["Authorization"].Text() == "Bearer {{apiKey}}" && extractor.StartsWith("function", StringComparison.Ordinal), "Safe rule failed conversion."); Assert(!UsageScriptConversion.TryGeneric(code.Replace("baseUrl+'/balance'", "pickEndpoint()"), "https://example.com", out _, out _), "Dynamic rule was guessed."); });
        Test("template interpolation conversion", () => { Assert(UsageScriptConversion.TryGeneric("({request:{url:`${baseUrl}/v1/usage`,headers:{Authorization:`Bearer ${apiKey}`}},extractor:function(r){return r;}})", "https://example.com", out var request, out _) && request!["Path"].Text() == "/v1/usage", "Template placeholders changed."); });
        Test("CC Switch source fingerprint is stable", () => { var descriptor = JsonData.Parse("""{"language":"javascript","code":"function(r){return r;}","timeoutSeconds":10,"templateType":"general","autoQueryIntervalMinutes":5,"endpointCandidates":["https://b.example","https://a.example","https://a.example"]}"""); var fingerprint = CcSwitchImport.Fingerprint(descriptor); descriptor["endpointCandidates"] = new JsonArray("https://a.example", "https://b.example"); Assert(fingerprint.Length == 64 && fingerprint == fingerprint.ToLowerInvariant() && fingerprint == CcSwitchImport.Fingerprint(descriptor), "Import fingerprint changed with endpoint ordering."); });
        Test("successful zero is preserved", () => { var provider = Provider(); var state = new RelayState(); state.Complete(Response(0), provider, DateTimeOffset.UtcNow); var row = state.Rows(provider).Single(); Assert(row.Value == "$0.00 USD" && row.Progress is null && state.Status == "Live", "Zero was lost or converted to a percentage."); });
        Test("failed relay retains its last success", () => { var provider = Provider(); var state = new RelayState(); var now = DateTimeOffset.UtcNow; state.Complete(Response(18), provider, now); state.Fail("Timeout", provider, now); Assert(state.Status == "Stale" && state.Rows(provider).Single().Value == "$18.00 USD" && !state.Blocked, "Failure cleared usable data."); state.Fail("Authentication", provider, now); Assert(state.Blocked && state.Status == "AuthRequired", "Auth failure kept retrying."); });
        Test("manual-only provider does not schedule", () => { var provider = Provider(); provider.IntervalMinutes = 0; var state = new RelayState(); state.Complete(Response(), provider, DateTimeOffset.UtcNow); Assert(state.NextDue == DateTimeOffset.MaxValue, "Manual provider scheduled automatically."); provider.Enabled = false; Assert(!state.Rows(provider).Any(), "Disabled provider rendered a card."); });
        Test("relay backoff respects Retry-After", () => { var provider = Provider(); var state = new RelayState(); var now = DateTimeOffset.UtcNow; state.Fail("RateLimit", provider, now, 429, 900); Assert(state.NextDue >= now.AddSeconds(900) && !state.Blocked, "Retry-After ignored."); });
        Test("invalid response cannot fabricate balance", () => { Throws<InvalidDataException>(() => RelayState.ValidateResponse(JsonData.Parse("""{"ok":true,"results":[{"isValid":true,"remaining":"bad"}]}"""))); Throws<InvalidDataException>(() => RelayState.ValidateResponse(JsonData.Parse("""{"ok":true,"results":[]}"""))); });
        Test("wallet-only daily consumption", () => { var state = new RelayState(); var provider = Provider(); var now = DateTimeOffset.UtcNow; var spend = new DailySpend(); state.Complete(Response(20), provider, now); spend.Track(provider.Id, state.Results, now); state.Complete(Response(17.25), provider, now); spend.Track(provider.Id, state.Results, now); Assert(spend.Get(provider.Id, state.Results, now) == 2.75, "Daily wallet delta is wrong."); var capped = Response(5); capped["results"]![0]!["total"] = 20d; state.Complete(capped, provider, now); Assert(spend.Get(provider.Id, state.Results, now) is null, "Capped plans counted as wallet spending."); Assert(spend.Get(provider.Id, state.Results, now.AddDays(1)) is null, "Previous day peak persisted."); });
        Test("atomic configuration write", () => { var path = Path.Combine(testRoot, "config.json"); JsonFiles.Write(path, new JsonObject { ["Value"] = 1 }); JsonFiles.Write(path, new JsonObject { ["Value"] = 2 }); Assert(JsonFiles.Read(path)!["Value"].Int() == 2 && !Directory.GetFiles(testRoot, "*.tmp").Any(), "Atomic write failed."); });
    }
    private static async Task TransportTests()
    {
        var lines = new List<string>(); await foreach (var line in BoundedLines.ReadAsync(new StringReader("a\r\nb\nlast"), 12)) lines.Add(line);
        Test("bounded reader preserves records", () => Assert(lines.SequenceEqual(new[] { "a", "b", "last" }), "JSONL record boundaries changed."));
        bool oversized = false; try { await foreach (var _ in BoundedLines.ReadAsync(new StringReader(new string('x', 13)), 12)) { } } catch (InvalidDataException) { oversized = true; }
        Test("oversized process record is rejected", () => Assert(oversized, "Unbounded process output was accepted."));
        await using var client = new JsonLineClient(Environment.ProcessPath!, new[] { "--fixture-rpc" });
        var initialized = await client.RpcAsync("initialize", new JsonObject()); var account = await client.RpcAsync("account/read", new JsonObject()); var limits = await client.RpcAsync("account/rateLimits/read", null);
        Test("RPC request IDs and normalization", () => Assert(initialized is not null && account["account"].Field("type").Text() == "chatgpt" && Quota.Normalize(limits).Count == 2 && client.PendingCount == 0, "RPC correlation failed."));
        for (var i = 0; i < 20; i++) { try { await client.RequestAsync(new JsonObject { ["id"] = "ignored-" + i, ["method"] = "ignore" }, TimeSpan.FromMilliseconds(12)); } catch (TimeoutException) { } }
        Test("timed-out requests leave no pending cache", () => Assert(client.PendingCount == 0 && client.Alive, "Pending responses accumulated."));
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel(); try { await client.RpcAsync("ignore", null, cancelled.Token); } catch (OperationCanceledException) { }
        Test("cancelled requests leave no pending cache", () => Assert(client.PendingCount == 0, "Cancellation leaked a request."));
    }
    private static void RuntimeTests()
    {
        var exe = Path.Combine(root, "desktop", "CodexQuotaMonitor.Desktop", "bin", "Release", "net8.0-windows", "win-x64", "CodexQuotaMonitor.exe");
        foreach (var type in new[] { "chatgpt", "apiKey", "none", "bedrock" })
        {
            var data = Path.Combine(testRoot, type); var prefix = "Local\\CodexQuotaMonitor.CSharp.Test." + Guid.NewGuid().ToString("N");
            using var process = Start(exe, "--data-root", data, "--instance-prefix", prefix, "--headless", "--run-for-seconds", "30", "--codex", Environment.ProcessPath!, "--codex-argument", "--fixture-rpc", "--codex-argument", type);
            var expected = type == "chatgpt" ? "Live" : type == "bedrock" ? "Unavailable" : "AuthRequired";
            JsonObject? health = null; var ready = Stopwatch.StartNew();
            while (ready.Elapsed.TotalSeconds < 20 && !process.HasExited)
            { health = JsonFiles.Read(Path.Combine(data, "data", "health.json")); if (health?["Status"].Text() == expected) break; Thread.Sleep(50); }
            using (var signal = Start(exe, "--data-root", data, "--instance-prefix", prefix, "--exit")) Assert(signal.WaitForExit(3000), "Native stop command did not exit.");
            Assert(process.WaitForExit(5000) && process.ExitCode == 0, "Native runtime did not exit cleanly: " + data + " (" + (process.HasExited ? process.ExitCode : -999) + ").");
            Test("native account state " + type, () => Assert(health?["Status"].Text() == expected && health?["QuotaWindowCount"].Int() == (type == "chatgpt" ? 2 : 0), "Native account eligibility changed: " + health?["Status"].Text()));
        }
        var instancePrefix = "Local\\CodexQuotaMonitor.CSharp.Test." + Guid.NewGuid().ToString("N"); var instanceRoot = Path.Combine(testRoot, "instance");
        using var owner = Start(exe, "--demo", "--headless", "--data-root", instanceRoot, "--instance-prefix", instancePrefix, "--run-for-seconds", "15");
        var deadline = Stopwatch.StartNew(); while (!File.Exists(Path.Combine(instanceRoot, "data", "health.json")) && deadline.Elapsed.TotalSeconds < 5) Thread.Sleep(50);
        using (var repeated = Start(exe, "--demo", "--headless", "--data-root", instanceRoot, "--instance-prefix", instancePrefix)) Assert(repeated.WaitForExit(3000) && repeated.ExitCode == 0 && !owner.HasExited, "Repeated launch started another owner.");
        using (var exit = Start(exe, "--data-root", instanceRoot, "--instance-prefix", instancePrefix, "--exit")) Assert(exit.WaitForExit(3000), "Exit signal failed.");
        Test("native single instance and exit", () => Assert(owner.WaitForExit(4000) && owner.ExitCode == 0, "The owner ignored the exit event."));
    }
    private static void RelayHostTest()
    {
        using var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0); listener.Start();
        var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
        var server = Task.Run(async () =>
        {
            using var client = await listener.AcceptTcpClientAsync(); await using var stream = client.GetStream();
            using var reader = new StreamReader(stream, leaveOpen: true); string? line;
            while ((line = await reader.ReadLineAsync()) is not null && line.Length > 0) { }
            const string body = "{\"balance\":12.5}";
            var bytes = System.Text.Encoding.UTF8.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n" + body);
            await stream.WriteAsync(bytes); await stream.FlushAsync();
        });
        var options = new LaunchOptions { DataRoot = Path.Combine(testRoot, "relay"), Prefix = "Local\\CodexQuotaMonitor.CSharp.RelayTest." + Guid.NewGuid().ToString("N"), RelayHost = Path.Combine(root, "companion", "Bin", "relay-quota-host.exe") };
        using var instance = new MonitorInstance(options.Prefix); using var runtime = new MonitorRuntime(options, instance);
        var provider = Provider(); provider.BaseUrl = $"http://127.0.0.1:{port}"; provider.TrustedDestination = RelayProvider.Origin(provider.BaseUrl);
        var response = runtime.QueryAsync(provider).GetAwaiter().GetResult(); server.Wait(TimeSpan.FromSeconds(10));
        Test("native client uses real Rust host and extractor", () => Assert(response["ok"].Bool() && response["results"]![0].Field("remaining").Number() == 12.5, "Native relay protocol is incompatible."));
    }
    private static Process Start(string exe, params string[] arguments)
    { var info = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden }; foreach (var argument in arguments) info.ArgumentList.Add(argument); return Process.Start(info)!; }
    private static int Fixture(string accountType)
    {
        string? line; while ((line = Console.ReadLine()) is not null)
        {
            var message = JsonData.Parse(line); if (message["id"] is null || message["method"].Text() == "ignore") continue;
            JsonObject result = message["method"].Text() switch
            {
                "account/read" => new() { ["requiresOpenaiAuth"] = true, ["account"] = accountType == "none" ? null : new JsonObject { ["type"] = accountType, ["planType"] = "plus" } },
                "account/rateLimits/read" => JsonData.Parse("""{"rateLimits":{"primary":{"usedPercent":38,"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":19,"windowDurationMins":10080,"resetsAt":2000100000}}}"""), _ => new()
            };
            Console.WriteLine(new JsonObject { ["id"] = message["id"]?.DeepClone(), ["result"] = result }.ToJsonString());
        }
        return 0;
    }
}
