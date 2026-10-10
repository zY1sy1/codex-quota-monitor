using System.Globalization;
using System.Windows;
using System.Windows.Threading;
using CodexQuotaMonitor.Core;

namespace CodexQuotaMonitor.Desktop;

public sealed class LaunchOptions
{
    public string DataRoot { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexQuotaMonitor");
    public string Prefix { get; set; } = "Local\\CodexQuotaMonitor";
    public string? Codex { get; set; }
    public string? RelayHost { get; set; }
    public string? CcSwitchDatabase { get; set; }
    public string? SmokeDirectory { get; set; }
    public int RunSeconds { get; set; }
    public bool Demo { get; set; }
    public bool Headless { get; set; }
    public bool Exit { get; set; }
    public string? Mode { get; set; }
    public string? Theme { get; set; }
    public List<string> CodexArguments { get; } = new();
    public static LaunchOptions Parse(string[] arguments)
    {
        var options = new LaunchOptions();
        for (var i = 0; i < arguments.Length; i++)
        {
            string Value() => ++i < arguments.Length ? arguments[i] : throw new ArgumentException("Missing argument value.");
            switch (arguments[i])
            {
                case "--data-root": options.DataRoot = Path.GetFullPath(Value()); break;
                case "--instance-prefix": options.Prefix = Value(); break;
                case "--codex": options.Codex = Value(); break;
                case "--codex-argument": options.CodexArguments.Add(Value()); break;
                case "--relay-host": options.RelayHost = Value(); break;
                case "--cc-switch-db": options.CcSwitchDatabase = Value(); break;
                case "--run-for-seconds": options.RunSeconds = int.Parse(Value(), CultureInfo.InvariantCulture); break;
                case "--smoke-test": options.SmokeDirectory = Path.GetFullPath(Value()); options.Demo = true; break;
                case "--mode": options.Mode = Value(); break;
                case "--theme": options.Theme = Value(); break;
                case "--demo": options.Demo = true; break;
                case "--headless": options.Headless = true; break;
                case "--exit": options.Exit = true; break;
                default: throw new ArgumentException("Unknown launch option.");
            }
        }
        if (options.RunSeconds is < 0 or > 86400 || options.Mode is not (null or "Full" or "CompactBar" or "Orb") || options.Theme is not (null or "Light" or "Dark"))
            throw new ArgumentException("Invalid launch options.");
        if (options.Demo && options.DataRoot == Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexQuotaMonitor"))
            throw new ArgumentException("Demo runs require an isolated --data-root.");
        return options;
    }
}

public static class Program
{
    [STAThread]
    public static int Main(string[] arguments)
    {
        LaunchOptions? options = null;
        try
        {
            options = LaunchOptions.Parse(arguments);
            using var instance = new MonitorInstance(options.Prefix);
            if (!instance.Primary) { if (options.Exit) instance.Exit.Set(); else instance.Activate.Set(); return 0; }
            if (options.Exit) return 0;
            var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            using var runtime = new MonitorRuntime(options, instance);
            application.DispatcherUnhandledException += (_, e) => { runtime.Log("DesktopError", "A desktop operation failed."); e.Handled = true; };
            application.Startup += (_, _) => application.Dispatcher.BeginInvoke(new Action(async () =>
            {
                try { await runtime.StartAsync(); }
                catch (Exception ex)
                {
                    if (options.SmokeDirectory is not null) { Directory.CreateDirectory(options.SmokeDirectory); File.WriteAllText(Path.Combine(options.SmokeDirectory, "smoke-error.txt"), ex.ToString()); }
                    runtime.Log("StartupError", ex.GetType().FullName + "\n" + ex.StackTrace); runtime.Quit(1);
                }
            }));
            return application.Run();
        }
        catch (Exception ex)
        {
            if (options is not null)
            {
                try { Directory.CreateDirectory(Path.Combine(options.DataRoot, "logs")); File.AppendAllText(Path.Combine(options.DataRoot, "logs", "desktop-startup.log"), DateTimeOffset.UtcNow.ToString("o") + " " + ex.GetType().FullName + "\n" + ex.StackTrace + "\n"); }
                catch (IOException) { }
            }
            return 1;
        }
    }
}
