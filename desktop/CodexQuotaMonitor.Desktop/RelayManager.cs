using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using CodexQuotaMonitor.Core;

namespace CodexQuotaMonitor.Desktop;

public sealed class RelayManager
{
    public Window Window { get; }
    private readonly MonitorRuntime runtime;
    private RelayProvider draft = new();
    private bool loading, closed, tested;
    private CancellationTokenSource? query;
    private JsonObject? pendingSource;
    public RelayManager(MonitorRuntime runtime)
    {
        this.runtime = runtime; Window = ViewTools.Load("RelayManager"); Window.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Window.MaxHeight = Math.Max(520, SystemParameters.WorkArea.Height - 24);
        Window.Click("AddButton", Add); Window.Click("EditButton", Edit); Window.Click("DuplicateButton", Duplicate); Window.Click("DeleteButton", Delete);
        Window.Click("MoveUpButton", () => Move(-1)); Window.Click("MoveDownButton", () => Move(1)); Window.Click("SaveButton", Save); Window.Click("CancelButton", () => Load(draft));
        Window.Click("ImportButton", Import);
        Window.Get<Button>("TestButton").Click += async (_, _) => await TestAsync();
        Window.Get<ListBox>("ProviderList").SelectionChanged += (_, _) => { if (!loading && Window.Get<ListBox>("ProviderList").SelectedItem is RelayProvider selected) Load(selected); };
        foreach (var text in ViewTools.Children(Window).OfType<TextBox>()) text.TextChanged += (_, _) => Invalidate();
        foreach (var password in ViewTools.Children(Window).OfType<PasswordBox>()) password.PasswordChanged += (_, _) => Invalidate();
        Window.Get<CheckBox>("EnabledCheckBox").Checked += (_, _) => Invalidate(); Window.Get<CheckBox>("EnabledCheckBox").Unchecked += (_, _) => Invalidate();
        Window.Get<ComboBox>("ProviderKindComboBox").SelectionChanged += (_, _) => { Invalidate(); ViewTools.Visible(Window.Get<Expander>("AdvancedRequestExpander"), Kind() == "Generic"); };
        Window.Get<ComboBox>("MethodComboBox").SelectionChanged += (_, _) => Invalidate();
        Window.Closed += (_, _) => { closed = true; query?.Cancel(); ClearPasswords(); };
        ApplyTheme(); RefreshList(); Add();
    }
    public void ApplyTheme()
    {
        Palette.Settings(Window, runtime.Settings.Theme);
        var palette = new Palette(runtime.Settings.Theme);
        foreach (var control in ViewTools.Children(Window))
        {
            if (control is TextBlock text) text.Foreground = palette.Primary;
            if (control is Control child) { child.Foreground = child is ComboBox or ComboBoxItem ? Brushes.Black : palette.Primary; if (child is TextBox or PasswordBox or ListBox or Button) child.Background = palette.Strong; }
        }
    }
    private string Kind() => (Window.Get<ComboBox>("ProviderKindComboBox").SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "Generic";
    private void Invalidate() { if (loading) return; tested = false; query?.Cancel(); Window.Get<Button>("SaveButton").IsEnabled = pendingSource is null; Window.Get<TextBlock>("TestStateText").Text = "配置已修改，请重新测试。"; }
    private void RefreshList(string? selectedId = null)
    {
        loading = true; try { var list = Window.Get<ListBox>("ProviderList"); list.ItemsSource = runtime.Providers.ToArray(); list.SelectedItem = runtime.Providers.FirstOrDefault(p => p.Id == selectedId); } finally { loading = false; }
    }
    private void Add()
    {
        pendingSource = null; var preset = JsonFiles.Read(Path.Combine(AppContext.BaseDirectory, "Presets", "relay-usage.json"))?["Presets"].Array().FirstOrDefault();
        var provider = new RelayProvider { RequestDefinition = preset?.Field("RequestDefinition")?.DeepClone() as JsonObject, ExtractorScript = preset?.Field("ExtractorScript").Text() ?? "function(response){return {isValid:true,remaining:response.balance,unit:'USD'};}" };
        Load(provider);
    }
    private void Edit() { if (Window.Get<ListBox>("ProviderList").SelectedItem is RelayProvider provider) { pendingSource = null; Load(provider); } }
    private void Duplicate()
    {
        if (Window.Get<ListBox>("ProviderList").SelectedItem is not RelayProvider provider) return;
        var copy = RelayProvider.FromJson(provider.ToJson()); copy.Id = Guid.NewGuid().ToString("D"); copy.Name += " 副本"; pendingSource = null; Load(copy);
    }
    private void Delete()
    {
        if (Window.Get<ListBox>("ProviderList").SelectedItem is not RelayProvider provider) return;
        if (MessageBox.Show(Window, "确定删除中转站「" + provider.Name + "」吗？", "删除中转站", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        try
        {
            runtime.SaveProviders(runtime.Providers.Where(p => p.Id != provider.Id).ToList()); RemoveLink(provider.Id); RefreshList(); Add();
        }
        catch (IOException) { Status("删除未能保存，请重试。"); }
    }
    private void Move(int offset) { if (Window.Get<ListBox>("ProviderList").SelectedItem is RelayProvider provider) { try { runtime.MoveProvider(provider.Id, offset); RefreshList(provider.Id); } catch (IOException) { Status("排序未能保存。"); } } }
    public void Load(RelayProvider provider)
    {
        query?.Cancel(); loading = true; draft = provider; tested = false;
        try
        {
            void Text(string name, string value) => Window.Get<TextBox>(name).Text = value;
            Text("NameTextBox", provider.Name); Text("BaseUrlTextBox", provider.BaseUrl); Text("ExtractorScriptTextBox", provider.ExtractorScript);
            Text("TimeoutTextBox", provider.TimeoutSeconds.ToString()); Text("IntervalTextBox", provider.IntervalMinutes.ToString());
            Window.Get<CheckBox>("EnabledCheckBox").IsChecked = provider.Enabled;
            Select("ProviderKindComboBox", provider.ProviderKind); Select("MethodComboBox", provider.RequestDefinition?["Method"].Text("GET") ?? "GET");
            Text("PathTextBox", provider.RequestDefinition?["Path"].Text("/user/balance") ?? "/user/balance");
            Text("QueryTextBox", provider.RequestDefinition?["Query"]?.ToJsonString(JsonData.Options) ?? "{}");
            Text("HeadersTextBox", provider.RequestDefinition?["Headers"]?.ToJsonString(JsonData.Options) ?? "{}"); Text("BodyTextBox", provider.RequestDefinition?["Body"].Text() ?? "");
            ClearPasswords(); foreach (var name in new[] { "ApiKey", "AccessToken", "UserId" }) Window.Get<PasswordBox>(name + "PasswordBox").ToolTip = provider.Secrets[name].Text().Length > 0 ? "已保存加密凭据；留空保留，输入内容替换。" : "输入凭据";
            Window.Get<ListBox>("PreviewList").ItemsSource = null; Status("可测试当前配置；保存后按独立间隔查询。"); Window.Get<Button>("SaveButton").IsEnabled = pendingSource is null;
            ViewTools.Visible(Window.Get<Expander>("AdvancedRequestExpander"), provider.ProviderKind == "Generic");
        }
        finally { loading = false; }
    }
    private void Select(string name, string tag) { var combo = Window.Get<ComboBox>(name); combo.SelectedItem = combo.Items.OfType<ComboBoxItem>().FirstOrDefault(item => item.Tag?.ToString() == tag); }
    private void ClearPasswords() { foreach (var name in new[] { "ApiKey", "AccessToken", "UserId" }) Window.Get<PasswordBox>(name + "PasswordBox").Clear(); }
    private RelayProvider ReadDraft()
    {
        var provider = new RelayProvider { Id = draft.Id, Name = ViewTools.Text(Window, "NameTextBox"), BaseUrl = ViewTools.Text(Window, "BaseUrlTextBox").Trim(),
            ProviderKind = Kind(), ExtractorScript = ViewTools.Text(Window, "ExtractorScriptTextBox"), Enabled = Window.Get<CheckBox>("EnabledCheckBox").IsChecked == true,
            TimeoutSeconds = int.TryParse(ViewTools.Text(Window, "TimeoutTextBox"), out var timeout) ? timeout : -1,
            IntervalMinutes = int.TryParse(ViewTools.Text(Window, "IntervalTextBox"), out var interval) ? interval : -1,
            Secrets = (JsonObject)draft.Secrets.DeepClone(), TrustedDestination = draft.TrustedDestination };
        if (provider.ProviderKind == "Generic")
        {
            var queryMap = JsonData.Parse(ViewTools.Text(Window, "QueryTextBox")); var headers = JsonData.Parse(ViewTools.Text(Window, "HeadersTextBox"));
            provider.RequestDefinition = new JsonObject { ["Method"] = (Window.Get<ComboBox>("MethodComboBox").SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "GET",
                ["Path"] = ViewTools.Text(Window, "PathTextBox"), ["Query"] = queryMap, ["Headers"] = headers,
                ["Body"] = string.IsNullOrEmpty(ViewTools.Text(Window, "BodyTextBox")) ? null : ViewTools.Text(Window, "BodyTextBox") };
        }
        foreach (var name in new[] { "ApiKey", "AccessToken", "UserId" })
        { var password = Window.Get<PasswordBox>(name + "PasswordBox").Password; if (password.Length > 0) provider.Secrets[name] = NativeSecrets.Protect(password); }
        var origin = RelayProvider.Origin(provider.BaseUrl);
        string? oldOrigin = null; try { oldOrigin = RelayProvider.Origin(draft.BaseUrl); } catch (InvalidDataException) { }
        if (oldOrigin != origin) provider.TrustedDestination = null;
        provider.Validate(); return provider;
    }
    private void Status(string message) => Window.Get<TextBlock>("TestStateText").Text = message;
    private async Task TestAsync()
    {
        query?.Cancel(); query = new CancellationTokenSource(); var activeQuery = query;
        var button = Window.Get<Button>("TestButton"); button.IsEnabled = false;
        try
        {
            var provider = ReadDraft(); var origin = RelayProvider.Origin(provider.BaseUrl);
            if (provider.TrustedDestination is null)
            {
                if (MessageBox.Show(Window, "允许向以下地址查询额度吗？\n" + origin, "确认查询目标", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
                provider.TrustedDestination = origin;
            }
            Status("正在测试…"); var response = await runtime.QueryAsync(provider, activeQuery.Token);
            if (!response["ok"].Bool() && response["error"].Field("category").Text() == "DestinationTrustRequired" && response["error"].Field("destinationFingerprint").Text() is string destination && destination.Length > 0)
            {
                _ = RelayProvider.Origin(destination);
                if (MessageBox.Show(Window, "该查询需要访问以下目标，是否允许？\n" + destination, "确认查询目标", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                { provider.TrustedDestination = destination; response = await runtime.QueryAsync(provider, activeQuery.Token); }
            }
            if (closed || activeQuery.IsCancellationRequested) return;
            if (response["ok"].Bool())
            {
                tested = true; draft = provider; Status("测试成功"); Window.Get<Button>("SaveButton").IsEnabled = true;
                var state = new RelayState(); state.Complete(response, provider, DateTimeOffset.UtcNow);
                Window.Get<ListBox>("PreviewList").ItemsSource = state.Rows(provider).Select(row => row.Label + " · " + row.Value).ToArray();
            }
            else Status("测试失败：" + SafeCategory(response["error"].Field("category").Text()));
        }
        catch (OperationCanceledException) { if (!closed) Status("配置已修改，测试已取消。"); }
        catch (Exception ex) when (ex is InvalidDataException or System.Text.Json.JsonException or CryptographicException or IOException or TimeoutException or System.ComponentModel.Win32Exception)
        { if (!closed) Status(ex is InvalidDataException ? ex.Message : "测试失败，请检查配置与网络。"); }
        finally { if (!closed) button.IsEnabled = true; }
    }
    private static string SafeCategory(string category) => category switch
    { "Authentication" => "凭据验证失败", "DestinationTrustRequired" => "需要确认请求或重定向目标", "EndpointNotFound" => "接口不存在", "Timeout" => "请求超时", "RateLimit" => "查询频率受限", _ => "请求或提取规则未通过验证" };
    private void Save()
    {
        try
        {
            if (pendingSource is not null && !tested) { Status("导入配置必须测试成功后才能保存。"); return; }
            var provider = ReadDraft(); var providers = runtime.Providers.ToList(); var index = providers.FindIndex(p => p.Id == provider.Id);
            if (index >= 0) providers[index] = provider; else providers.Add(provider);
            runtime.SaveProviders(providers, provider.Id);
            if (pendingSource is not null) { SaveLink(provider.Id, pendingSource); pendingSource = null; }
            RefreshList(provider.Id); Load(provider); Status("已保存");
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or System.Text.Json.JsonException or CryptographicException)
        { Status(ex is InvalidDataException ? ex.Message : "配置未能保存，请重试。"); }
    }
    private void Import()
    {
        var importer = new CcSwitchImport(runtime) { Owner = Window };
        if (importer.Window.ShowDialog() == true && importer.Provider is not null)
        { pendingSource = importer.Source; Load(importer.Provider); Status("导入草稿：请输入凭据并测试后保存。"); }
    }
    private void SaveLink(string id, JsonObject source)
    {
        var document = JsonFiles.Read(runtime.DataFile("relay-import-links.json")) ?? new JsonObject { ["SchemaVersion"] = 1, ["Links"] = new JsonArray() };
        var links = document["Links"].Array(); foreach (var old in links.Where(n => n.Field("RelayProviderId").Text() == id).ToArray()) links.Remove(old);
        source["RelayProviderId"] = id; links.Add(source.DeepClone()); document["Links"] = links; JsonFiles.Write(runtime.DataFile("relay-import-links.json"), document);
    }
    private void RemoveLink(string id)
    {
        var document = JsonFiles.Read(runtime.DataFile("relay-import-links.json")); if (document is null) return;
        var links = document["Links"].Array(); foreach (var old in links.Where(n => n.Field("RelayProviderId").Text() == id).ToArray()) links.Remove(old);
        JsonFiles.Write(runtime.DataFile("relay-import-links.json"), document);
    }
}
