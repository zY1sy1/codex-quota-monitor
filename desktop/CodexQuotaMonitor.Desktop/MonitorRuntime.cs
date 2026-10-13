using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using CodexQuotaMonitor.Core;
using Microsoft.Win32;

namespace CodexQuotaMonitor.Desktop;

public sealed class MonitorRuntime : IDisposable
{
    public LaunchOptions Options { get; }
    public MonitorSettings Settings { get; private set; }
    public List<RelayProvider> Providers { get; private set; } = new();
    public Dictionary<string, RelayState> RelayStates { get; } = new(StringComparer.OrdinalIgnoreCase);
    public IReadOnlyList<DisplayRow> Rows { get; private set; } = Array.Empty<DisplayRow>();
    public string OfficialStatus { get; private set; } = "Starting";
    public string OfficialError { get; private set; } = "";
    public DateTimeOffset? LastSuccess { get; private set; }
    public string? PlanType { get; private set; }
    public List<QuotaWindow> Windows { get; private set; } = new();
    private readonly MonitorInstance instance;
    private readonly CancellationTokenSource stopping = new();
    private readonly SemaphoreSlim relayConcurrency = new(2, 2);
    private readonly SemaphoreSlim relayStartup = new(1, 1);
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private JsonLineClient? officialClient;
    private JsonLineClient? relayClient;
    private DailySpend spend = new();
    private JsonArray currentProviders = new();
    private DateTimeOffset nextOfficial = DateTimeOffset.MinValue, nextCcSwitch = DateTimeOffset.MinValue, nextHealth = DateTimeOffset.MinValue;
    private bool officialBusy, ccSwitchBusy, disposed;
    private bool settingsReadable = true, providersReadable = true;
    private int reconnectAttempt;
    private readonly DateTimeOffset started = DateTimeOffset.UtcNow;
    private readonly List<Task> tasks = new();
    private NativeTray? tray;
    private QuotaView? view;
    private SettingsView? settingsView;
    private RelayManager? relayManager;
    public string RelayHostPath => Options.RelayHost ?? Path.Combine(AppContext.BaseDirectory, "Bin", "relay-quota-host.exe");
    public string DataFile(string name) => Path.Combine(Options.DataRoot, "data", name);
    public event Action? PresentationChanged;
    public bool ShutdownRequested { get; private set; }
    public void Quit(int code = 0) { ShutdownRequested = true; Application.Current.Shutdown(code); }

    public MonitorRuntime(LaunchOptions options, MonitorInstance instance)
    {
        Options = options; this.instance = instance;
        Directory.CreateDirectory(Path.Combine(options.DataRoot, "data")); Directory.CreateDirectory(Path.Combine(options.DataRoot, "logs"));
        try { Settings = new MonitorSettings(JsonFiles.Read(DataFile("settings.json"))); }
        catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException or InvalidDataException or InvalidOperationException)
        { settingsReadable = false; Log("SettingsInvalid", "The saved settings could not be read; defaults are in use."); Settings = new MonitorSettings(); }
        if (options.Mode is not null) Settings.Mode = options.Mode;
        if (options.Theme is not null) Settings.Theme = options.Theme;
        try { Providers = RelayProvider.ReadDocument(JsonFiles.Read(DataFile("relay-providers.json"))); }
        catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException or InvalidDataException or InvalidOperationException)
        { providersReadable = false; Log("ProvidersInvalid", "The saved provider definitions could not be read."); }
        try { spend = new DailySpend(JsonFiles.Read(DataFile("daily-spend.json"))); } catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException) { }
        foreach (var provider in Providers) RelayStates[provider.Id] = new RelayState();
        try
        {
            foreach (var cache in JsonFiles.Read(DataFile("relay-cache.json"))?["Providers"].Array() ?? new JsonArray())
                if (cache is not null && RelayStates.TryGetValue(cache.Field("ProviderId").Text(), out var state)) state.LoadCache(cache);
        }
        catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException) { }
    }
    public async Task StartAsync()
    {
        if (Options.Demo) { LoadDemo(); Settings.Visible = true; }
        RebuildRows();
        if (!Options.Headless)
        {
            var menu = new ContextMenu();
            void Item(string title, Action action) { var item = new MenuItem { Header = title }; item.Click += (_, _) => action(); menu.Items.Add(item); }
            Item("显示 / 隐藏", ToggleVisible); Item("设置", OpenSettings); menu.Items.Add(new Separator());
            Item("打开官方额度页面", () => StartupShortcut.Open("https://chatgpt.com/codex/settings/usage"));
            Item("查看日志", () => StartupShortcut.Open(Path.Combine(Options.DataRoot, "logs")));
            menu.Items.Add(new Separator()); Item("退出", () => Quit());
            tray = new NativeTray(menu, ToggleVisible, Refresh);
            if (Settings.Visible || Options.SmokeDirectory is not null) ShowView();
        }
        timer.Tick += Tick; timer.Start(); Tick(null, EventArgs.Empty);
        if (Options.SmokeDirectory is not null)
        {
            await SmokeTests.RunAsync(this, Options.SmokeDirectory);
            Quit();
        }
    }
    private void Tick(object? sender, EventArgs e)
    {
        if (disposed) return;
        if (instance.Exit.WaitOne(0)) { instance.Exit.Reset(); Quit(); return; }
        if (instance.Activate.WaitOne(0)) { instance.Activate.Reset(); if (!Options.Headless) { Settings.Visible = true; ShowView(); SaveSettings(); } }
        var now = DateTimeOffset.UtcNow;
        if (Options.RunSeconds > 0 && (now - started).TotalSeconds >= Options.RunSeconds) { Quit(); return; }
        view?.UpdateCountdown(now);
        tasks.RemoveAll(t => t.IsCompleted);
        if (!Options.Demo)
        {
            if (!officialBusy && now >= nextOfficial) Track(RefreshOfficialAsync());
            if (!ccSwitchBusy && now >= nextCcSwitch) Track(RefreshCcSwitchAsync());
            foreach (var provider in Providers.Where(p => p.Enabled && p.IntervalMinutes > 0).ToArray())
                if (RelayStates.TryGetValue(provider.Id, out var state) && !state.Running && !state.Blocked && now >= state.NextDue)
                    Track(QueryScheduledAsync(provider, state));
        }
        if (now >= nextHealth) { WriteHealth(); nextHealth = now.AddSeconds(5); }
    }
    private void Track(Task task) { tasks.Add(task); }
    private async Task RefreshOfficialAsync()
    {
        officialBusy = true; nextOfficial = DateTimeOffset.UtcNow.AddSeconds(60);
        try
        {
            if (officialClient is null || !officialClient.Alive)
            {
                if (officialClient is not null) await officialClient.DisposeAsync();
                var executable = Options.Codex ?? FindCodex();
                if (executable is null) { OfficialStatus = "Unavailable"; OfficialError = "未找到 Codex，请安装 Codex 或指定 --codex。"; return; }
                officialClient = new JsonLineClient(executable, Options.CodexArguments.Count > 0 ? Options.CodexArguments : new[] { "app-server" });
                officialClient.Notification += notification =>
                {
                    if (notification["method"].Text() is "account/rateLimits/updated" or "account/updated" && !ShutdownRequested && !disposed)
                    {
                        var dispatcher = Application.Current.Dispatcher;
                        if (!dispatcher.HasShutdownStarted) dispatcher.BeginInvoke(() => { if (!disposed && !ShutdownRequested) nextOfficial = DateTimeOffset.MinValue; });
                    }
                };
                await officialClient.RpcAsync("initialize", new JsonObject { ["clientInfo"] = new JsonObject
                    { ["name"] = "codex_quota_monitor", ["title"] = "Codex Quota Monitor", ["version"] = "2.0.0" } }, stopping.Token);
                await officialClient.SendAsync(new JsonObject { ["method"] = "initialized" }, stopping.Token);
            }
            var account = await officialClient.RpcAsync("account/read", new JsonObject { ["refreshToken"] = false }, stopping.Token);
            if (!account.ContainsKey("account") || account["requiresOpenaiAuth"] is not JsonValue authentication || !authentication.TryGetValue<bool>(out _))
                throw new InvalidDataException("Invalid account response.");
            var type = account["account"].Field("type").Text();
            PlanType = account["account"].Field("planType")?.Text();
            if (type != "chatgpt")
            {
                Windows.Clear(); OfficialStatus = type is "apiKey" or "" ? "AuthRequired" : "Unavailable";
                OfficialError = type is "apiKey" or "" ? "请在 Codex 中登录 ChatGPT 账户。" : "该账户类型不提供 ChatGPT 额度。"; return;
            }
            var limits = await officialClient.RpcAsync("account/rateLimits/read", null, stopping.Token);
            if (limits.Field("rateLimits") is not JsonObject && limits.Field("rateLimitsByLimitId") is not JsonObject) throw new InvalidDataException("Invalid rate limits response.");
            Windows = Quota.Normalize(limits); LastSuccess = DateTimeOffset.UtcNow; OfficialStatus = "Live"; OfficialError = ""; reconnectAttempt = 0;
            var upcoming = Windows.Where(w => w.ResetsAt > LastSuccess.Value.ToUnixTimeSeconds()).Select(w => w.ResetsAt).DefaultIfEmpty(long.MaxValue).Min();
            if (upcoming < nextOfficial.ToUnixTimeSeconds()) nextOfficial = DateTimeOffset.FromUnixTimeSeconds(upcoming).AddSeconds(1);
        }
        catch (OperationCanceledException) when (stopping.IsCancellationRequested) { }
        catch (Exception ex) when (ex is IOException or InvalidDataException or System.ComponentModel.Win32Exception or TimeoutException or InvalidOperationException)
        {
            OfficialStatus = LastSuccess is null ? "Unavailable" : "Stale"; OfficialError = "官方额度连接中断，正在重连。";
            nextOfficial = DateTimeOffset.UtcNow.AddSeconds(new[] { 2, 5, 10, 30, 60 }[Math.Min(reconnectAttempt++, 4)]);
            if (officialClient is not null) { await officialClient.DisposeAsync(); officialClient = null; }
            Log("AppServerConnection", "The official quota connection is unavailable.");
        }
        finally { officialBusy = false; if (!disposed) RebuildRows(); }
    }
    private static string? FindCodex()
    {
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        { var candidate = Path.Combine(directory.Trim('"'), "codex.exe"); if (File.Exists(candidate)) return candidate; }
        foreach (var process in Process.GetProcessesByName("Codex"))
        {
            using (process)
            {
                try { var folder = Path.GetDirectoryName(process.MainModule?.FileName); if (folder is not null && File.Exists(Path.Combine(folder, "resources", "codex.exe"))) return Path.Combine(folder, "resources", "codex.exe"); }
                catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException) { }
            }
        }
        using var repository = Registry.CurrentUser.OpenSubKey(@"Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages");
        foreach (var name in repository?.GetSubKeyNames().Where(n => n.StartsWith("OpenAI.Codex_", StringComparison.OrdinalIgnoreCase)) ?? Array.Empty<string>())
        {
            using var package = repository!.OpenSubKey(name); var folder = package?.GetValue("PackageRootFolder") as string;
            if (folder is not null && File.Exists(Path.Combine(folder, "app", "resources", "codex.exe"))) return Path.Combine(folder, "app", "resources", "codex.exe");
        }
        return null;
    }
    private async Task<JsonLineClient> EnsureRelayAsync()
    {
        await relayStartup.WaitAsync(stopping.Token);
        try
        {
            if (relayClient is null || !relayClient.Alive)
            {
                if (relayClient is not null) await relayClient.DisposeAsync();
                var hashPath = Path.ChangeExtension(RelayHostPath, ".sha256");
                if (Options.RelayHost is null)
                {
                    var expected = File.ReadAllText(hashPath).Trim();
                    using var stream = File.OpenRead(RelayHostPath);
                    if (expected != Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream))) throw new InvalidDataException("The relay host integrity check failed.");
                }
                relayClient = new JsonLineClient(RelayHostPath);
            }
            return relayClient;
        }
        finally { relayStartup.Release(); }
    }
    public async Task<JsonObject> QueryAsync(RelayProvider provider, CancellationToken token = default)
    {
        provider.Validate(); await relayConcurrency.WaitAsync(token);
        try
        {
            var client = await EnsureRelayAsync();
            var command = provider.Command(Guid.NewGuid().ToString("N"), NativeSecrets.Unprotect);
            try { var response = await client.RequestAsync(command, TimeSpan.FromSeconds(provider.TimeoutSeconds + 3), token); RelayState.ValidateResponse(response); return response; }
            finally { command["secrets"] = null; }
        }
        finally { relayConcurrency.Release(); }
    }
    private async Task QueryScheduledAsync(RelayProvider provider, RelayState state)
    {
        state.Running = true;
        try
        {
            var response = await QueryAsync(provider, stopping.Token);
            if (disposed || !Providers.Any(p => ReferenceEquals(p, provider))) return;
            state.Complete(response, provider, DateTimeOffset.UtcNow);
            if (response["ok"].Bool())
            {
                if (spend.Track(provider.Id, state.Results, DateTimeOffset.UtcNow)) JsonFiles.Write(DataFile("daily-spend.json"), spend.Document);
                WriteCache();
            }
        }
        catch (OperationCanceledException) when (stopping.IsCancellationRequested) { }
        catch (Exception ex) when (ex is IOException or InvalidDataException or System.Security.Cryptography.CryptographicException or TimeoutException or System.ComponentModel.Win32Exception or InvalidOperationException)
        { state.Fail(ex is System.Security.Cryptography.CryptographicException ? "Authentication" : ex is InvalidDataException ? "Protocol" : "SidecarLifecycle", provider, DateTimeOffset.UtcNow); Log("RelayQuery", "A provider query failed."); }
        finally { state.Running = false; if (!disposed) RebuildRows(); }
    }
    public async Task<JsonObject> DiscoverCcSwitchAsync()
    {
        var database = Options.CcSwitchDatabase ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".cc-switch", "cc-switch.db");
        using var process = new Process { StartInfo = new ProcessStartInfo(RelayHostPath) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true } };
        process.StartInfo.ArgumentList.Add("--inspect-cc-switch"); process.StartInfo.ArgumentList.Add(database);
        process.Start();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stopping.Token); timeout.CancelAfter(TimeSpan.FromSeconds(5));
        var read = Task.Run(async () => { JsonObject? result = null; await foreach (var line in BoundedLines.ReadAsync(process.StandardOutput, token: timeout.Token)) { if (result is not null) throw new InvalidDataException("Invalid discovery response."); result = JsonData.Parse(line); } return result ?? throw new InvalidDataException("Empty discovery response."); }, timeout.Token);
        var drain = Task.Run(async () => { var buffer = new char[4096]; while (await process.StandardError.ReadAsync(buffer.AsMemory(), timeout.Token) > 0) { } }, timeout.Token);
        try { await process.WaitForExitAsync(timeout.Token); await drain; return await read; }
        finally { if (!process.HasExited) { try { process.Kill(true); } catch (System.ComponentModel.Win32Exception) { } } }
    }
    private async Task RefreshCcSwitchAsync()
    {
        ccSwitchBusy = true; nextCcSwitch = DateTimeOffset.UtcNow.AddSeconds(60);
        try { var discovery = await DiscoverCcSwitchAsync(); currentProviders = discovery["ok"].Bool() ? (JsonArray)discovery["currentProviders"].Array().DeepClone() : new(); }
        catch (Exception ex) when (ex is IOException or InvalidDataException or System.Text.Json.JsonException or OperationCanceledException or System.ComponentModel.Win32Exception) { currentProviders = new(); }
        finally { ccSwitchBusy = false; if (!disposed) RebuildRows(); }
    }
    public void Refresh()
    {
        nextOfficial = DateTimeOffset.MinValue; nextCcSwitch = DateTimeOffset.MinValue;
        if (!Options.Demo) foreach (var provider in Providers.Where(p => p.Enabled).ToArray())
            if (RelayStates.TryGetValue(provider.Id, out var state) && !state.Running) Track(QueryScheduledAsync(provider, state));
    }
    public void RebuildRows()
    {
        if (disposed || ShutdownRequested || Application.Current?.Dispatcher.HasShutdownStarted == true) return;
        if (Application.Current is not null && !Application.Current.Dispatcher.CheckAccess())
        {
            Application.Current.Dispatcher.BeginInvoke(RebuildRows);
            return;
        }
        var rows = Quota.Official(Windows, OfficialStatus);
        foreach (var provider in Providers) if (RelayStates.TryGetValue(provider.Id, out var state))
        {
            var consumed = Settings.TodaySpend ? spend.Get(provider.Id, state.Results, DateTimeOffset.UtcNow) : null;
            var providerRows = state.Rows(provider, consumed).ToList();
            rows.AddRange(providerRows);
            if (Settings.Focus == $"relay:{provider.Id}:daily" && providerRows.FirstOrDefault(r => r.Detail.Contains("今日消耗 ", StringComparison.Ordinal)) is DisplayRow wallet)
            { Settings.Focus = wallet.Key; SaveSettings(); }
        }
        var names = currentProviders.Where(p => p.Field("appType").Text().Equals("codex", StringComparison.OrdinalIgnoreCase)).ToList();
        var official = names.Any(p => p.Field("providerId").Text().Equals("default", StringComparison.OrdinalIgnoreCase) || p.Field("name").Text().Equals("default", StringComparison.OrdinalIgnoreCase) || p.Field("name").Text().Contains("official", StringComparison.OrdinalIgnoreCase));
        Rows = rows.Select(r => r with { Current = r.Official ? official && r.Label == "5 小时额度" : names.Any(p => p.Field("name").Text().Equals(r.Source, StringComparison.OrdinalIgnoreCase)) }).ToArray();
        view?.Render(Rows); UpdateTray(); PresentationChanged?.Invoke(); WriteHealth();
    }
    private void UpdateTray()
    {
        var live = Rows.Where(r => r.State == "Live" && r.Progress.HasValue).Select(r => r.Progress!.Value).ToList();
        var minimum = live.Count > 0 ? live.Min() : -1; var color = minimum < 0 ? "#AFB8CB" : minimum < 15 ? "#FF6B6B" : minimum <= 40 ? "#F1B84B" : "#58C2C7";
        tray?.Update(color, Rows.Count > 0 ? string.Join(" | ", Rows.Take(4).Select(r => r.Source + " " + r.Label + " " + r.Value)) : Quota.StatusText(OfficialStatus));
    }
    public void SaveSettings()
    { if (!settingsReadable) return; try { JsonFiles.Write(DataFile("settings.json"), Settings.Document); } catch (IOException) { Log("SettingsWrite", "Settings could not be saved."); } }
    public void SetMode(string mode)
    {
        if (mode == Settings.Mode) return;
        if (view is not null) { WindowPosition.Save(view.Window, Settings); view.Dispose(); view = null; }
        Settings.Mode = mode; SaveSettings(); if (Settings.Visible && !Options.Headless) ShowView(); PresentationChanged?.Invoke();
    }
    public void SetTheme(string theme) { Settings.Theme = theme; SaveSettings(); view?.ApplyTheme(); settingsView?.Refresh(); relayManager?.ApplyTheme(); }
    public void SetLayout(string layout) { Settings.Layout = layout; SaveSettings(); view?.Render(Rows); }
    public void SetFocus(string key) { Settings.Focus = key == Settings.Focus ? "Auto" : key; SaveSettings(); view?.Render(Rows); }
    public void ToggleTopmost() { Settings.Topmost = !Settings.Topmost; SaveSettings(); if (view is not null) view.Window.Topmost = Settings.Topmost; }
    public void ToggleVisible() { Settings.Visible = !Settings.Visible; if (Settings.Visible) ShowView(); else view?.Window.Hide(); SaveSettings(); }
    public void Hide() { Settings.Visible = false; view?.Window.Hide(); SaveSettings(); }
    private void ShowView()
    {
        if (view is null) { view = new QuotaView(this); view.Render(Rows); }
        view.Window.Show(); view.Window.UpdateLayout(); WindowPosition.Place(view.Window, Settings); view.Window.Activate();
    }
    public QuotaView? CurrentView => view;
    public void OpenSettings() { if (settingsView is null) { settingsView = new SettingsView(this); settingsView.Window.Closed += (_, _) => settingsView = null; } settingsView.Window.Show(); settingsView.Window.Activate(); }
    public void OpenRelayManager() { if (relayManager is null) { relayManager = new RelayManager(this); relayManager.Window.Closed += (_, _) => relayManager = null; } relayManager.Window.Show(); relayManager.Window.Activate(); }
    public void SaveProviders(List<RelayProvider> providers, string? changedId = null)
    {
        if (!providersReadable) throw new InvalidDataException("现有中转站文件无法读取，请先修复该文件；原文件已保留。");
        foreach (var provider in providers) provider.Validate(); JsonFiles.Write(DataFile("relay-providers.json"), RelayProvider.Document(providers));
        Providers = providers;
        foreach (var id in RelayStates.Keys.Where(id => !providers.Any(p => p.Id == id)).ToArray()) RelayStates.Remove(id);
        foreach (var provider in providers) if (!RelayStates.ContainsKey(provider.Id) || provider.Id == changedId) RelayStates[provider.Id] = new();
        WriteCache(); RebuildRows();
    }
    public void MoveProvider(string id, int offset)
    {
        var providers = Providers.ToList(); var index = providers.FindIndex(p => p.Id == id); var target = index + offset;
        if (index < 0 || target < 0 || target >= providers.Count) return;
        var provider = providers[index]; providers.RemoveAt(index); providers.Insert(target, provider); SaveProviders(providers);
    }
    public void ReorderProvider(string id, string targetId)
    { var from = Providers.FindIndex(p => p.Id == id); var to = Providers.FindIndex(p => p.Id == targetId); if (from >= 0 && to >= 0) MoveProvider(id, to - from); }
    private void WriteCache() => JsonFiles.Write(DataFile("relay-cache.json"), new JsonObject { ["SchemaVersion"] = 1,
        ["Providers"] = new JsonArray(Providers.Select(p => RelayStates.TryGetValue(p.Id, out var state) ? state.Cache(p.Id) : null).Where(c => c is not null).Select(c => (JsonNode)c!).ToArray()) });
    private void WriteHealth()
    {
        try { JsonFiles.Write(DataFile("health.json"), new JsonObject { ["SchemaVersion"] = 1, ["ProcessId"] = Environment.ProcessId,
            ["Runtime"] = "CSharpWpf", ["State"] = OfficialStatus, ["Status"] = OfficialStatus == "Stale" ? "Reconnecting" : OfficialStatus, ["PlanType"] = PlanType, ["QuotaWindowCount"] = Windows.Count,
            ["RenderedOfficialQuotaCount"] = view?.RenderedOfficialCount,
            ["LastSuccessAt"] = LastSuccess?.ToString("o"), ["LastErrorCategory"] = OfficialError.Length > 0 ? "AppServerConnection" : null,
            ["LastErrorMessage"] = OfficialError.Length > 0 ? OfficialError : null, ["StartedAt"] = started.ToString("o"), ["UpdatedAt"] = DateTimeOffset.UtcNow.ToString("o"), ["InstancePrefix"] = Options.Prefix }); }
        catch (IOException) { }
    }
    public void Log(string category, string safeMessage)
    {
        try
        {
            var path = Path.Combine(Options.DataRoot, "logs", "monitor.log"); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path) && new FileInfo(path).Length > 1048576)
            { for (var i = 4; i >= 1; i--) { var from = Path.Combine(Options.DataRoot, "logs", $"monitor.{i}.log"); if (File.Exists(from)) File.Move(from, Path.Combine(Options.DataRoot, "logs", $"monitor.{i + 1}.log"), true); } File.Move(path, Path.Combine(Options.DataRoot, "logs", "monitor.1.log"), true); }
            File.AppendAllText(path, new JsonObject { ["Timestamp"] = DateTimeOffset.UtcNow.ToString("o"), ["Category"] = category, ["Message"] = safeMessage }.ToJsonString() + "\n");
        }
        catch (IOException) { }
    }
    private void LoadDemo()
    {
        var now = DateTimeOffset.UtcNow; OfficialStatus = "Live"; LastSuccess = now;
        Windows = new() { new("codex|primary|300|demo", "codex", "", "primary", 300, now.AddHours(3).ToUnixTimeSeconds(), 62), new("codex|secondary|10080|demo", "codex", "", "secondary", 10080, now.AddDays(5).ToUnixTimeSeconds(), 81) };
        Providers = new() { new RelayProvider { Id = "410e9cae-2b57-4e7a-8f16-06c6a985fb13", Name = "演示中转站", BaseUrl = "https://example.com", ProviderKind = "Custom", ExtractorScript = "({request:{url:baseUrl},extractor:function(r){return r;}})" } };
        var state = new RelayState(); state.Complete(JsonData.Parse("""{"ok":true,"results":[{"isValid":true,"remaining":18.65,"unit":"USD","planName":"钱包余额","total":null,"used":null,"extra":null}]}"""), Providers[0], now);
        RelayStates[Providers[0].Id] = state; spend.Track(Providers[0].Id, state.Results, now);
        currentProviders = JsonData.Parse("""{"current":[{"appType":"codex","name":"default","providerId":"default"}]}""")["current"].Array();
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true; timer.Stop(); timer.Tick -= Tick; stopping.Cancel();
        if (view is not null) { WindowPosition.Save(view.Window, Settings); SaveSettings(); view.Dispose(); }
        settingsView?.Window.Close(); relayManager?.Window.Close(); tray?.Dispose();
        // Pumps use ConfigureAwait(false); stopping owned children never needs the UI dispatcher.
        officialClient?.DisposeAsync().AsTask().GetAwaiter().GetResult(); relayClient?.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }
}
