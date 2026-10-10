using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using CodexQuotaMonitor.Core;

namespace CodexQuotaMonitor.Desktop;

public static class SmokeTests
{
    public static async Task RunAsync(MonitorRuntime runtime, string directory)
    {
        Directory.CreateDirectory(directory); var captures = new JsonArray();
        foreach (var theme in new[] { "Dark", "Light" })
        {
            runtime.SetTheme(theme);
            foreach (var mode in new[] { "Full", "CompactBar", "Orb" })
            {
                runtime.SetMode(mode); await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                var window = runtime.CurrentView?.Window ?? throw new InvalidOperationException("The active quota window is missing.");
                if (!window.IsVisible || window.ActualWidth <= 0 || window.ActualHeight <= 0) throw new InvalidOperationException("The quota window was not laid out.");
                if (mode == "Full" && window.Get<StackPanel>("OfficialRows").Children.Count != 2) throw new InvalidOperationException("Official quotas were not rendered in the UI.");
                var path = Path.Combine(directory, mode + "-" + theme + ".png"); ViewTools.Snapshot(window, path); captures.Add(path);
            }
            var settings = new SettingsView(runtime); settings.Window.Show();
            foreach (var page in new[] { "Appearance", "Behavior", "Relay" })
            {
                settings.Navigate(page); await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                if (settings.Window.Get<StackPanel>(page + "Page").Visibility != Visibility.Visible) throw new InvalidOperationException("Settings navigation failed.");
                if (page == "Relay" && (settings.Window.Get<StackPanel>("RelayOrderList").Children.Count != runtime.Providers.Count || settings.Window.Get<Border>("RelayOrderSurface").Visibility != Visibility.Visible))
                    throw new InvalidOperationException("The settings relay order is not visible.");
                var path = Path.Combine(directory, "Settings-" + page + "-" + theme + ".png"); ViewTools.Snapshot(settings.Window, path); captures.Add(path);
            }
            settings.Window.Close(); var manager = new RelayManager(runtime); manager.Window.Show();
            await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            if (manager.Window.Get<ListBox>("ProviderList").Items.Count != runtime.Providers.Count || runtime.Providers[0].DisplayName.Length == 0)
                throw new InvalidOperationException("The provider list lost its display names.");
            var managerPath = Path.Combine(directory, "RelayManager-" + theme + ".png"); ViewTools.Snapshot(manager.Window, managerPath); captures.Add(managerPath); manager.Window.Close();
        }
        runtime.SetMode("Full");
        runtime.SetLayout("Tabs"); await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        if (runtime.CurrentView!.Window.Get<StackPanel>("TabsPanel").Visibility != Visibility.Visible) throw new InvalidOperationException("Full-window tabs failed.");
        runtime.SetLayout("Overview"); runtime.SetFocus(runtime.Rows[0].Key); runtime.SetMode("CompactBar");
        if (runtime.CurrentView!.Window.Get<TextBlock>("MetricValue").Text != runtime.Rows[0].DisplayValue) throw new InvalidOperationException("Pinned compact metric changed.");
        runtime.CurrentView.Window.Close();
        if (runtime.Settings.Visible || runtime.CurrentView.Window.IsVisible) throw new InvalidOperationException("Closing did not hide to the tray.");
        runtime.ToggleVisible(); if (!runtime.CurrentView.Window.IsVisible) throw new InvalidOperationException("The tray could not restore the window.");
        runtime.SetMode("Orb"); if (Application.Current.Windows.Count != 1) throw new InvalidOperationException("An inactive window was retained.");
        if (AppDomain.CurrentDomain.GetAssemblies().Any(a => a.GetName().Name is "System.Management.Automation" or "System.Windows.Forms")) throw new InvalidOperationException("A legacy resident framework was loaded.");
        using var process = Process.GetCurrentProcess();
        JsonFiles.Write(Path.Combine(directory, "smoke-result.json"), new JsonObject { ["Passed"] = true, ["Captures"] = captures,
            ["WorkingSetMB"] = Math.Round(process.WorkingSet64 / 1048576d, 1), ["PrivateCommittedMB"] = Math.Round(process.PrivateMemorySize64 / 1048576d, 1),
            ["AssemblyCount"] = AppDomain.CurrentDomain.GetAssemblies().Length });
    }
}
