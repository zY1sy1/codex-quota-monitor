using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using CodexQuotaMonitor.Core;

namespace CodexQuotaMonitor.Desktop;

public sealed class CcSwitchImport
{
    private sealed record Descriptor(JsonObject Data) { public string DisplayName => Data["name"].Text() + " · " + Data["sourceAppType"].Text(); public override string ToString() => DisplayName; }
    private readonly MonitorRuntime runtime;
    public Window Window { get; }
    public Window Owner { set => Window.Owner = value; }
    public RelayProvider? Provider { get; private set; }
    public JsonObject? Source { get; private set; }
    public CcSwitchImport(MonitorRuntime runtime)
    {
        this.runtime = runtime; Window = ViewTools.Load("CcSwitchImport"); Palette.Settings(Window, runtime.Settings.Theme);
        Window.Get<ComboBox>("ImportModeComboBox").SelectedIndex = 0; Window.Get<RadioButton>("CopyRadioButton").IsChecked = true;
        Window.Get<Button>("RefreshButton").Click += async (_, _) => await DiscoverAsync(); Window.Click("ImportButton", Import); Window.Click("CancelButton", () => Window.Close());
        Window.Get<ListBox>("SourceList").SelectionChanged += (_, _) => Select();
        Window.Loaded += async (_, _) => { if (!runtime.Options.Demo) await DiscoverAsync(); else Window.Get<TextBlock>("StatusText").Text = "演示模式：此处将列出 CC Switch 中可导入的额度查询规则。"; };
    }
    private async Task DiscoverAsync()
    {
        Window.Get<Button>("RefreshButton").IsEnabled = false;
        try
        {
            var response = await runtime.DiscoverCcSwitchAsync();
            Window.Get<ListBox>("SourceList").ItemsSource = response["providers"].Array().OfType<JsonObject>().Select(n => new Descriptor(n)).ToArray();
            Window.Get<TextBlock>("StatusText").Text = response["ok"].Bool() ? "只导入查询规则；凭据须重新输入。" : "未找到可读取的 CC Switch 数据库。";
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or System.ComponentModel.Win32Exception or OperationCanceledException) { Window.Get<TextBlock>("StatusText").Text = "无法读取 CC Switch，请检查数据库路径。"; }
        finally { Window.Get<Button>("RefreshButton").IsEnabled = true; }
    }
    private void Select()
    {
        if (Window.Get<ListBox>("SourceList").SelectedItem is not Descriptor descriptor) return;
        var endpoints = descriptor.Data["endpointCandidates"].Array().Select(n => n.Text()).ToArray();
        var combo = Window.Get<ComboBox>("EndpointComboBox"); combo.ItemsSource = endpoints; combo.Text = endpoints.FirstOrDefault() ?? "";
        Window.Get<TextBlock>("ConversionText").Text = descriptor.Data["importStatus"].Text() == "ready" ? "选择目标地址并导入；无法拆分的规则可确认后按 Custom 导入。" : "该规则缺少有效脚本或包含凭据，无法导入。";
    }
    private void Import()
    {
        try
        {
            if (Window.Get<ListBox>("SourceList").SelectedItem is not Descriptor descriptor) return;
            var source = descriptor.Data; if (source["importStatus"].Text() != "ready" || string.IsNullOrWhiteSpace(source["code"].Text())) throw new InvalidDataException("该规则无法导入。");
            var endpoint = Window.Get<ComboBox>("EndpointComboBox").Text.Trim(); _ = RelayProvider.Origin(endpoint);
            var mode = (Window.Get<ComboBox>("ImportModeComboBox").SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "Auto";
            var code = source["code"].Text(); var generic = UsageScriptConversion.TryGeneric(code, endpoint, out var request, out var extractor);
            if (mode == "Auto" && !generic)
            { if (MessageBox.Show(Window, "该规则无法安全拆分为通用配置。确认作为 Custom 脚本导入？", "导入查询规则", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return; mode = "Custom"; }
            var provider = new RelayProvider { Name = source["name"].Text(), BaseUrl = endpoint, ProviderKind = mode == "Custom" ? "Custom" : "Generic",
                RequestDefinition = mode == "Custom" ? null : request, ExtractorScript = mode == "Custom" ? code : extractor,
                TimeoutSeconds = Math.Clamp(source["timeoutSeconds"].Int(10), 2, 30), IntervalMinutes = 5 };
            if (Window.Get<RadioButton>("UpdateRadioButton").IsChecked == true)
            {
                var links = JsonFiles.Read(runtime.DataFile("relay-import-links.json"))?["Links"].Array();
                var link = links?.FirstOrDefault(n => n.Field("SourceProviderId").Text() == source["sourceProviderId"].Text() && n.Field("SourceAppType").Text() == source["sourceAppType"].Text());
                if (link is null) throw new InvalidDataException("未找到已导入的规则，请选择创建副本。");
                var old = runtime.Providers.FirstOrDefault(p => p.Id == link.Field("RelayProviderId").Text());
                if (old is null) throw new InvalidDataException("对应中转站已删除，请选择创建副本。");
                provider.Id = old.Id; provider.Name = old.Name; provider.Enabled = old.Enabled; provider.IntervalMinutes = old.IntervalMinutes;
                if (RelayProvider.Origin(old.BaseUrl) == RelayProvider.Origin(endpoint)) provider.TrustedDestination = old.TrustedDestination;
            }
            provider.Validate(); Provider = provider;
            Source = new JsonObject { ["RelayProviderId"] = provider.Id, ["SourceKind"] = "CcSwitchUsageScript", ["SourceProviderId"] = source["sourceProviderId"]?.DeepClone(),
                ["SourceAppType"] = source["sourceAppType"]?.DeepClone(), ["ScriptFingerprint"] = Fingerprint(source) };
            Window.DialogResult = true;
        }
        catch (Exception ex) when (ex is InvalidDataException or IOException or System.Text.Json.JsonException) { Window.Get<TextBlock>("StatusText").Text = ex is InvalidDataException ? ex.Message : "导入失败，请重试。"; }
    }
    public static string Fingerprint(JsonObject source)
    {
        var canonical = new JsonObject { ["Language"] = source["language"].Text(), ["Code"] = source["code"].Text(), ["TimeoutSeconds"] = source["timeoutSeconds"].Int(),
            ["TemplateType"] = source["templateType"].Text(), ["AutoQueryIntervalMinutes"] = source["autoQueryIntervalMinutes"].Int(),
            ["EndpointCandidates"] = new JsonArray(source["endpointCandidates"].Array().Select(n => n.Text()).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).Select(s => (JsonNode?)JsonValue.Create(s)).ToArray()) };
        var json = canonical.ToJsonString(new System.Text.Json.JsonSerializerOptions(JsonData.Options) { WriteIndented = false, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(json))).ToLowerInvariant();
    }
}
