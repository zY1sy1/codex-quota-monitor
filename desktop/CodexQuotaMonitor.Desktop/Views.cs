using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Xml;
using CodexQuotaMonitor.Core;
using Microsoft.Win32;

namespace CodexQuotaMonitor.Desktop;

public static class ViewTools
{
    public static Window Load(string name)
    {
        using var reader = XmlReader.Create(Path.Combine(AppContext.BaseDirectory, "UI", name + ".xaml"), new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit });
        var window = (Window)XamlReader.Load(reader);
        var icon = Path.Combine(AppContext.BaseDirectory, "CodexQuotaMonitor.ico");
        if (File.Exists(icon)) window.Icon = BitmapFrame.Create(new Uri(icon));
        return window;
    }
    public static T Get<T>(this Window window, string name) where T : class => window.FindName(name) as T ?? throw new InvalidDataException("Missing UI control: " + name);
    public static T? Find<T>(this Window window, string name) where T : class => window.FindName(name) as T;
    public static void Click(this Window window, string name, Action action) { if (window.Find<Button>(name) is Button button) button.Click += (_, _) => action(); }
    public static IEnumerable<DependencyObject> Children(DependencyObject parent)
    {
        yield return parent;
        foreach (var child in LogicalTreeHelper.GetChildren(parent).OfType<DependencyObject>()) foreach (var nested in Children(child)) yield return nested;
    }
    public static SolidColorBrush Brush(string color) { var result = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color)); result.Freeze(); return result; }
    public static void Visible(UIElement? element, bool value) { if (element is not null) element.Visibility = value ? Visibility.Visible : Visibility.Collapsed; }
    public static string Text(Window window, string name) => window.Get<TextBox>(name).Text;
    public static void Snapshot(Window window, string path)
    {
        window.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth), (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        var drawing = new DrawingVisual();
        using (var context = drawing.RenderOpen())
        {
            var bounds = new Rect(0, 0, window.ActualWidth, window.ActualHeight);
            context.DrawRectangle(window.Background, null, bounds);
        }
        bitmap.Render(drawing); bitmap.Render(window); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(path); encoder.Save(file);
    }
}

public sealed class Palette
{
    public Brush Surface { get; } public Brush Strong { get; } public Brush Primary { get; } public Brush Secondary { get; }
    public Brush Accent { get; } public Brush Track { get; } public Brush Separator { get; }
    public Palette(string theme)
    {
        var light = theme == "Light";
        Surface = ViewTools.Brush(light ? "#E6F4EFEA" : "#E6323A4C"); Strong = ViewTools.Brush(light ? "#D9EEE7E1" : "#D93A4358");
        Primary = ViewTools.Brush(light ? "#FF201F1D" : "#FFF4F3F1"); Secondary = ViewTools.Brush(light ? "#FF6F6B67" : "#FFAFB8CB");
        Accent = ViewTools.Brush(light ? "#FF4DADB3" : "#FF58C2C7"); Track = ViewTools.Brush(light ? "#667E8588" : "#664D566A"); Separator = ViewTools.Brush(light ? "#40716D68" : "#4D707A90");
    }
    public static void Settings(Window window, string theme)
    {
        var light = theme == "Light";
        string[] names = { "Surface", "Sidebar", "SurfaceStrong", "TextPrimary", "TextSecondary", "Accent", "AccentText", "Success", "Selection", "Border", "Separator", "Hover", "Pressed", "Danger" };
        string[] colors = light ? new[] { "#FFF9FAFA", "#FFF1F5F5", "#FFFFFFFF", "#FF201F1D", "#FF6F6B67", "#FF348186", "#FFFFFFFF", "#FF24757A", "#FFE2F0F0", "#FF7A878C", "#FFD1D9DC", "#FFEAF3F3", "#FFD9EAEA", "#FFB42323" }
            : new[] { "#FF323A4C", "#FF272E3D", "#FF3A4358", "#FFF4F3F1", "#FFAFB8CB", "#FF58C2C7", "#FF1F2832", "#FF79D9DD", "#FF354D58", "#FF8792A6", "#FF566074", "#FF3A4658", "#FF425264", "#FFFFA0A0" };
        for (var i = 0; i < names.Length; i++) window.Resources["Settings" + names[i] + "Brush"] = ViewTools.Brush(colors[i]);
        window.Background = ViewTools.Brush(colors[0]); window.Foreground = ViewTools.Brush(colors[3]);
    }
    public Brush Severity(double? value) => value is < 15 ? ViewTools.Brush("#FFFF6B6B") : value is <= 40 ? ViewTools.Brush("#FFF1B84B") : Accent;
}

public sealed class QuotaView : IDisposable
{
    private readonly MonitorRuntime runtime;
    public Window Window { get; }
    private readonly Dictionary<string, QuotaCard> cards = new(StringComparer.Ordinal);
    private bool closing;
    private bool relayTab;
    private DisplayRow? focused;
    private IReadOnlyList<DisplayRow> rows = Array.Empty<DisplayRow>();
    private Palette palette;
    public int RenderedOfficialCount => Window.Find<StackPanel>(runtime.Settings.Layout == "Tabs" ? "OfficialTabRows" : "OfficialRows")?.Children.OfType<Border>().Count() ?? (focused?.Official == true ? 1 : 0);
    public QuotaView(MonitorRuntime runtime)
    {
        this.runtime = runtime; palette = new(runtime.Settings.Theme);
        Window = ViewTools.Load(runtime.Settings.Mode switch { "CompactBar" => "CompactBar", "Orb" => "QuotaOrb", _ => "MainWindow" });
        Window.Topmost = runtime.Settings.Topmost;
        Window.Closing += Closing;
        Window.SourceInitialized += (_, _) => { if (!SystemParameters.HighContrast) CodexQuotaMonitor.Theme.NativeMethods.EnableBlur(new WindowInteropHelper(Window).Handle); };
        Window.Click("CloseButton", runtime.Hide); Window.Click("HideButton", runtime.Hide);
        Window.Click("PinButton", runtime.ToggleTopmost); Window.Click("ThemeButton", () => runtime.SetTheme(runtime.Settings.Theme == "Dark" ? "Light" : "Dark"));
        Window.Click("ModeButton", () => runtime.SetMode(runtime.Settings.Mode switch { "Full" => "CompactBar", "CompactBar" => "Orb", _ => "Full" }));
        Window.Click("LayoutButton", () => runtime.SetLayout(runtime.Settings.Layout == "Overview" ? "Tabs" : "Overview"));
        Window.Click("RefreshButton", runtime.Refresh); Window.Click("OfficialTabButton", () => { relayTab = false; Render(rows); }); Window.Click("RelayTabButton", () => { relayTab = true; Render(rows); });
        Window.Get<FrameworkElement>("HeaderDragArea").MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2 && runtime.Settings.Mode != "Full") { runtime.SetMode("Full"); return; }
            try { Window.DragMove(); WindowPosition.Save(Window, runtime.Settings); runtime.SaveSettings(); } catch (InvalidOperationException) { }
            e.Handled = true;
        };
        var context = new ContextMenu();
        void Item(string label, Action action) { var item = new MenuItem { Header = label }; item.Click += (_, _) => action(); context.Items.Add(item); }
        foreach (var (mode, label) in new[] { ("Full", "完整窗口"), ("CompactBar", "迷你条"), ("Orb", "额度球") }) Item(label, () => runtime.SetMode(mode));
        context.Items.Add(new Separator()); Item("立即刷新", runtime.Refresh); Item("设置", runtime.OpenSettings); Item("隐藏", runtime.Hide);
        Window.ContextMenu = context;
        Window.SizeChanged += (_, _) => UpdateCountdown(DateTimeOffset.UtcNow);
        ApplyTheme();
    }
    private void Closing(object? sender, CancelEventArgs e) { if (closing || runtime.ShutdownRequested) return; e.Cancel = true; runtime.Hide(); }
    public void ApplyTheme()
    {
        palette = new(runtime.Settings.Theme);
        Window.Resources["QuotaFocusRingBrush"] = palette.Accent;
        Window.Resources["QuotaFocusHoverBrush"] = ViewTools.Brush(runtime.Settings.Theme == "Light" ? "#244DADB3" : "#2458C2C7");
        Window.Resources["QuotaFocusPressedBrush"] = ViewTools.Brush(runtime.Settings.Theme == "Light" ? "#3D4DADB3" : "#3D58C2C7");
        var root = Window.Get<Border>("RootBorder"); root.Background = palette.Surface; root.BorderBrush = palette.Separator;
        bool transparent = true; using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")) transparent = key?.GetValue("EnableTransparency", 1) is not int value || value != 0;
        if (SystemParameters.HighContrast || (RenderCapability.Tier >> 16) == 0 || !transparent)
        { var color = ((SolidColorBrush)palette.Surface).Color; color.A = 255; root.Background = new SolidColorBrush(color); root.Effect = null; }
        foreach (var control in ViewTools.Children(Window))
        {
            if (control is TextBlock text) text.Foreground = palette.Primary;
            if (control is Button button) button.Foreground = palette.Primary;
            if (control is Expander expander) expander.Foreground = palette.Primary;
        }
        Render(rows);
    }
    public void Render(IReadOnlyList<DisplayRow> snapshot)
    {
        rows = snapshot;
        if (runtime.Settings.Mode != "Full") { focused = Quota.Focus(snapshot, runtime.Settings.Focus); RenderFocus(); return; }
        var tabs = runtime.Settings.Layout == "Tabs";
        ViewTools.Visible(Window.Get<StackPanel>("OverviewPanel"), !tabs); ViewTools.Visible(Window.Get<StackPanel>("TabsPanel"), tabs);
        ViewTools.Visible(Window.Get<StackPanel>("OfficialTabRows"), !relayTab); ViewTools.Visible(Window.Get<StackPanel>("RelayTabRows"), relayTab);
        var hasRelay = snapshot.Any(r => !r.Official);
        ViewTools.Visible(Window.Get<Expander>("RelayExpander"), hasRelay); ViewTools.Visible(Window.Get<Button>("RelayTabButton"), hasRelay);
        if (!hasRelay) { relayTab = false; ViewTools.Visible(Window.Get<StackPanel>("OfficialTabRows"), true); ViewTools.Visible(Window.Get<StackPanel>("RelayTabRows"), false); }
        foreach (var key in cards.Keys.Where(key => snapshot.All(r => r.Key != key)).ToArray())
        { if (cards[key].Element.Parent is Panel parent) parent.Children.Remove(cards[key].Element); cards.Remove(key); }
        foreach (var name in new[] { "OfficialRows", "RelayRows", "OfficialTabRows", "RelayTabRows" }) Window.Get<StackPanel>(name).Children.Clear();
        foreach (var row in snapshot)
        {
            if (!cards.TryGetValue(row.Key, out var card)) { card = new QuotaCard(Window, () => runtime.SetFocus(row.Key)); cards[row.Key] = card; }
            card.Update(row, palette, runtime.Settings.Focus == row.Key);
            Window.Get<StackPanel>(row.Official ? tabs ? "OfficialTabRows" : "OfficialRows" : tabs ? "RelayTabRows" : "RelayRows").Children.Add(card.Element);
        }
        if (!snapshot.Any(r => r.Official)) Window.Get<StackPanel>(tabs ? "OfficialTabRows" : "OfficialRows").Children.Add(new TextBlock
            { Text = runtime.OfficialStatus == "Live" ? "当前账户未返回额度窗口" : runtime.OfficialError.Length > 0 ? runtime.OfficialError : Quota.StatusText(runtime.OfficialStatus), Foreground = palette.Secondary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 16, 0, 12) });
        Window.Get<TextBlock>("FreshnessText").Text = runtime.LastSuccess is DateTimeOffset time ? $"{Quota.StatusText(runtime.OfficialStatus)} · 更新于 {time.ToLocalTime():HH:mm:ss}" : Quota.StatusText(runtime.OfficialStatus);
        Window.Get<TextBlock>("FreshnessText").Foreground = palette.Secondary;
        Window.Get<Border>("ConnectionDot").Background = runtime.OfficialStatus == "Live" ? palette.Accent : palette.Secondary;
        UpdateCountdown(DateTimeOffset.UtcNow);
    }
    private void RenderFocus()
    {
        var value = focused?.DisplayValue ?? "--"; var label = focused?.Label ?? Quota.StatusText(runtime.OfficialStatus);
        if (runtime.Settings.Mode == "CompactBar")
        {
            Window.Get<TextBlock>("MetricLabel").Text = label; Window.Get<TextBlock>("MetricLabel").Foreground = palette.Secondary;
            Window.Get<TextBlock>("MetricValue").Text = value; Window.Get<Border>("ProgressTrack").Background = palette.Track;
            Window.Get<Border>("ProgressFill").Background = palette.Severity(focused?.Progress);
            ViewTools.Visible(Window.Get<Border>("ProgressTrack"), focused?.Progress is not null);
        }
        else
        {
            Window.Get<TextBlock>("MetricText").Text = focused?.Progress is double progress ? $"{progress:0.#}%" : "余额";
            Window.Get<TextBlock>("ValueText").Text = value;
            ViewTools.Visible(Window.Get<TextBlock>("ValueText"), focused?.Progress is null);
            Window.Get<TextBlock>("SourceText").Text = focused?.Source ?? "Codex"; Window.Get<TextBlock>("SourceText").Foreground = palette.Secondary;
            var track = Window.Get<System.Windows.Shapes.Path>("RingTrack"); track.Data = new EllipseGeometry(new Point(40, 40), 35, 35); track.Stroke = palette.Track;
            ViewTools.Visible(track, focused?.Progress is not null);
            var ring = Window.Get<System.Windows.Shapes.Path>("RingValue"); ring.Stroke = palette.Severity(focused?.Progress); ring.Data = Arc(focused?.Progress);
        }
        Window.ToolTip = focused is not null ? $"{focused.Source} · {focused.Label}\n{focused.Value}\n{focused.Detail}" : runtime.OfficialError;
        Window.Opacity = focused?.Stale == true ? .78 : 1;
        UpdateCountdown(DateTimeOffset.UtcNow);
    }
    private static Geometry Arc(double? value)
    {
        if (value is null or <= 0) return Geometry.Empty;
        if (value >= 100) return new EllipseGeometry(new Point(40, 40), 35, 35);
        var radians = value.Value / 100 * Math.PI * 2;
        var figure = new PathFigure { StartPoint = new Point(40, 5) };
        figure.Segments.Add(new ArcSegment(new Point(40 + 35 * Math.Sin(radians), 40 - 35 * Math.Cos(radians)), new Size(35, 35), 0, value > 50, SweepDirection.Clockwise, true));
        return new PathGeometry(new[] { figure });
    }
    public void UpdateCountdown(DateTimeOffset now)
    {
        foreach (var card in cards.Values) card.Countdown(now);
        if (runtime.Settings.Mode == "CompactBar")
        {
            Window.Get<TextBlock>("CountdownText").Text = focused?.ResetsAt > 0 ? Quota.Countdown(focused.ResetsAt, now) : focused?.Detail ?? "";
            Window.Get<TextBlock>("CountdownText").Foreground = palette.Accent; Window.Get<TextBlock>("ResetTimeText").Text = Quota.ResetTime(focused?.ResetsAt ?? 0);
            Window.Get<TextBlock>("ResetTimeText").Foreground = palette.Secondary;
            Window.Get<Border>("ProgressFill").Width = Math.Max(0, Window.Get<Border>("ProgressTrack").ActualWidth * (focused?.Progress ?? 0) / 100);
        }
    }
    public void Dispose() { if (closing) return; closing = true; Window.Closing -= Closing; Window.Close(); cards.Clear(); }
}

public sealed class QuotaCard
{
    public Border Element { get; }
    private readonly TextBlock label = new(), value = new(), detail = new(), countdown = new(), reset = new();
    private readonly Border current = new() { Width = 7, Height = 7, CornerRadius = new CornerRadius(3.5), Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly ProgressBar progress = new() { Height = 6, Maximum = 100, Margin = new Thickness(0, 7, 0, 7) };
    private readonly Button focus;
    private DisplayRow? row;
    public QuotaCard(Window window, Action pin)
    {
        var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var body = new StackPanel(); var heading = new StackPanel { Orientation = Orientation.Horizontal };
        heading.Children.Add(current); label.FontSize = 13; label.FontWeight = FontWeights.SemiBold; heading.Children.Add(label); body.Children.Add(heading);
        value.FontSize = 23; value.FontWeight = FontWeights.SemiBold; value.Margin = new Thickness(0, 3, 0, 0); body.Children.Add(value); body.Children.Add(progress);
        detail.FontSize = 11; detail.TextWrapping = TextWrapping.Wrap; body.Children.Add(detail);
        var footer = new Grid(); footer.ColumnDefinitions.Add(new ColumnDefinition()); footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        countdown.FontSize = 11; reset.FontSize = 10; Grid.SetColumn(reset, 1); footer.Children.Add(countdown); footer.Children.Add(reset); body.Children.Add(footer);
        grid.Children.Add(body); focus = new Button { Content = "◎", FontSize = 18, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(8, 0, 0, 0), Style = (Style)window.Resources["QuotaFocusButton"], ToolTip = "固定为迷你条 / 额度球焦点" };
        AutomationProperties.SetName(focus, "固定额度焦点"); focus.Click += (_, _) => pin(); Grid.SetColumn(focus, 1); grid.Children.Add(focus);
        Element = new Border { Child = grid, Padding = new Thickness(12, 10, 10, 10), Margin = new Thickness(0, 6, 0, 0), CornerRadius = new CornerRadius(7), BorderThickness = new Thickness(1) };
    }
    public void Update(DisplayRow row, Palette palette, bool pinned)
    {
        this.row = row; Element.Background = palette.Strong; Element.BorderBrush = pinned ? palette.Accent : palette.Separator;
        Element.Opacity = row.Stale ? .78 : 1; Element.ToolTip = $"{row.Source} · {row.Label}\n{row.Value}\n{row.Detail}";
        label.Text = row.Official ? row.Label : row.Source + (row.Label == row.Source ? "" : " · " + row.Label); label.Foreground = palette.Secondary;
        value.Text = row.DisplayValue; value.Foreground = palette.Primary; value.TextAlignment = row.Official ? TextAlignment.Left : TextAlignment.Center;
        detail.Text = row.Detail; detail.Foreground = palette.Secondary; detail.TextAlignment = row.Official ? TextAlignment.Left : TextAlignment.Center;
        ViewTools.Visible(detail, row.Detail.Length > 0); ViewTools.Visible(current, row.Current); current.Background = palette.Accent;
        progress.Value = row.Progress ?? 0; progress.Foreground = palette.Severity(row.Progress); progress.Background = palette.Track; ViewTools.Visible(progress, row.Progress.HasValue);
        focus.Foreground = pinned ? palette.Accent : palette.Secondary; countdown.Foreground = palette.Accent; reset.Foreground = palette.Secondary;
        Countdown(DateTimeOffset.UtcNow);
    }
    public void Countdown(DateTimeOffset now) { countdown.Text = row?.ResetsAt > 0 ? Quota.Countdown(row.ResetsAt, now) : ""; reset.Text = Quota.ResetTime(row?.ResetsAt ?? 0); }
}
