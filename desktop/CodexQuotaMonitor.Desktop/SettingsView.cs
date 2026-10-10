using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using CodexQuotaMonitor.Core;

namespace CodexQuotaMonitor.Desktop;

public sealed class SettingsView
{
    public Window Window { get; }
    private readonly MonitorRuntime runtime;
    private bool hydrating;
    private string orderSignature = "";
    public SettingsView(MonitorRuntime runtime)
    {
        this.runtime = runtime; Window = ViewTools.Load("Settings");
        Window.MaxHeight = Math.Max(480, SystemParameters.WorkArea.Height - 32);
        Window.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        void Radio(string name, Action action) => Window.Get<RadioButton>(name).Checked += (_, _) => { if (!hydrating) Run(action); };
        Radio("AppearanceNavRadio", () => Navigate("Appearance")); Radio("BehaviorNavRadio", () => Navigate("Behavior")); Radio("RelayNavRadio", () => Navigate("Relay"));
        Radio("FullModeRadio", () => runtime.SetMode("Full")); Radio("CompactBarModeRadio", () => runtime.SetMode("CompactBar")); Radio("OrbModeRadio", () => runtime.SetMode("Orb"));
        Radio("LightThemeRadio", () => runtime.SetTheme("Light")); Radio("DarkThemeRadio", () => runtime.SetTheme("Dark"));
        Radio("OverviewLayoutRadio", () => runtime.SetLayout("Overview")); Radio("TabsLayoutRadio", () => runtime.SetLayout("Tabs"));
        void Check(string name, Action<bool> action)
        {
            var control = Window.Get<CheckBox>(name);
            RoutedEventHandler handler = (_, _) => { if (!hydrating) Run(() => action(control.IsChecked == true)); };
            control.Checked += handler; control.Unchecked += handler;
        }
        Check("TopmostCheckBox", enabled => { if (runtime.Settings.Topmost != enabled) runtime.ToggleTopmost(); });
        Check("StartupCheckBox", enabled =>
        {
            if (runtime.Options.Demo) { Window.Get<TextBlock>("StatusText").Text = "演示模式：开机启动设置未应用。"; Refresh(); return; }
            StartupShortcut.Set(enabled, Environment.ProcessPath!); runtime.Settings.Startup = enabled; runtime.SaveSettings();
        });
        Check("TodaySpendCheckBox", enabled => { runtime.Settings.TodaySpend = enabled; runtime.SaveSettings(); runtime.RebuildRows(); });
        Window.Click("RefreshButton", runtime.Refresh); Window.Click("ManageRelaysButton", runtime.OpenRelayManager);
        runtime.PresentationChanged += Refresh; Window.Closed += (_, _) => runtime.PresentationChanged -= Refresh;
        Navigate("Appearance"); Refresh();
    }
    private void Run(Action action)
    {
        try { action(); Window.Get<TextBlock>("StatusText").Text = "设置已应用"; }
        catch (Exception ex) when (ex is IOException or InvalidDataException or System.Runtime.InteropServices.COMException or InvalidOperationException)
        { Window.Get<TextBlock>("StatusText").Text = "设置未能保存，请重试。"; runtime.Log("SettingsAction", "A settings action failed."); }
        Refresh();
    }
    public void Navigate(string page)
    {
        hydrating = true;
        try { foreach (var name in new[] { "Appearance", "Behavior", "Relay" }) { ViewTools.Visible(Window.Get<StackPanel>(name + "Page"), name == page); Window.Get<RadioButton>(name + "NavRadio").IsChecked = name == page; } }
        finally { hydrating = false; }
    }
    public void Refresh()
    {
        hydrating = true;
        try
        {
            Palette.Settings(Window, runtime.Settings.Theme);
            foreach (var mode in new[] { "Full", "CompactBar", "Orb" }) Window.Get<RadioButton>(mode + "ModeRadio").IsChecked = runtime.Settings.Mode == mode;
            Window.Get<RadioButton>("LightThemeRadio").IsChecked = runtime.Settings.Theme == "Light"; Window.Get<RadioButton>("DarkThemeRadio").IsChecked = runtime.Settings.Theme == "Dark";
            Window.Get<RadioButton>("OverviewLayoutRadio").IsChecked = runtime.Settings.Layout == "Overview"; Window.Get<RadioButton>("TabsLayoutRadio").IsChecked = runtime.Settings.Layout == "Tabs";
            Window.Get<Border>("FullLayoutGroup").IsEnabled = runtime.Settings.Mode == "Full";
            Window.Get<TextBlock>("LayoutAvailabilityText").Text = runtime.Settings.Mode == "Full" ? "" : "切换到完整窗口后可调整布局";
            Window.Get<CheckBox>("TopmostCheckBox").IsChecked = runtime.Settings.Topmost; Window.Get<CheckBox>("StartupCheckBox").IsChecked = runtime.Settings.Startup;
            Window.Get<CheckBox>("TodaySpendCheckBox").IsChecked = runtime.Settings.TodaySpend;
            var signature = string.Join("|", runtime.Providers.Select(p => p.Id + p.Name + p.Enabled)) + runtime.Settings.Theme;
            if (signature != orderSignature) { orderSignature = signature; RenderOrder(); }
        }
        finally { hydrating = false; }
    }
    private void RenderOrder()
    {
        var panel = Window.Get<StackPanel>("RelayOrderList"); panel.Children.Clear();
        ViewTools.Visible(Window.Get<Border>("RelayOrderSurface"), runtime.Providers.Count > 0);
        ViewTools.Visible(Window.Get<TextBlock>("RelayOrderEmptyText"), runtime.Providers.Count == 0);
        foreach (var provider in runtime.Providers)
        {
            var border = new Border { Padding = new Thickness(10, 8, 8, 8), Margin = new Thickness(0, 0, 0, 4), CornerRadius = new CornerRadius(6), Cursor = Cursors.SizeAll, AllowDrop = true };
            border.SetResourceReference(Border.BackgroundProperty, "SettingsSurfaceStrongBrush");
            var row = new Grid(); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var label = new TextBlock { Text = (provider.Enabled ? "● " : "○ ") + provider.Name, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
            label.SetResourceReference(TextBlock.ForegroundProperty, "SettingsTextPrimaryBrush"); row.Children.Add(label);
            for (var offset = -1; offset <= 1; offset += 2)
            {
                var move = offset; var button = new Button { Content = offset < 0 ? "↑" : "↓", Width = 30, Height = 28, Margin = new Thickness(4, 0, 0, 0), IsEnabled = offset < 0 ? runtime.Providers[0] != provider : runtime.Providers[^1] != provider };
                button.Style = (Style)Window.Resources["OrderMoveButtonStyle"];
                button.SetResourceReference(Control.BackgroundProperty, "SettingsSurfaceStrongBrush"); button.SetResourceReference(Control.ForegroundProperty, "SettingsTextPrimaryBrush");
                AutomationProperties.SetName(button, (offset < 0 ? "上移 " : "下移 ") + provider.Name); button.Click += (_, _) => Run(() => runtime.MoveProvider(provider.Id, move)); Grid.SetColumn(button, offset < 0 ? 1 : 2); row.Children.Add(button);
            }
            border.Child = row; Point origin = default;
            border.PreviewMouseLeftButtonDown += (_, e) => origin = e.GetPosition(border);
            border.MouseMove += (_, e) =>
            {
                if (e.LeftButton != MouseButtonState.Pressed) return;
                var point = e.GetPosition(border); if (Math.Abs(point.Y - origin.Y) < SystemParameters.MinimumVerticalDragDistance && Math.Abs(point.X - origin.X) < SystemParameters.MinimumHorizontalDragDistance) return;
                if (e.OriginalSource is DependencyObject child && FindButton(child)) return;
                DragDrop.DoDragDrop(border, new DataObject("CodexQuotaMonitor.RelayId", provider.Id), DragDropEffects.Move);
            };
            border.Drop += (_, e) => { if (e.Data.GetData("CodexQuotaMonitor.RelayId") is string id) Run(() => runtime.ReorderProvider(id, provider.Id)); e.Handled = true; };
            panel.Children.Add(border);
        }
    }
    private static bool FindButton(DependencyObject element)
    {
        while (element is not null) { if (element is Button) return true; var parent = VisualTreeHelper.GetParent(element); if (parent is null) return false; element = parent; }
        return false;
    }
}
