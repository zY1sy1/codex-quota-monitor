using System.Text;
using System.Text.Json.Nodes;

namespace CodexQuotaMonitor.Core;

public sealed class RelayProvider
{
    public string Id { get; set; } = Guid.NewGuid().ToString("D");
    public string Name { get; set; } = "新中转站";
    public bool Enabled { get; set; } = true;
    public string ProviderKind { get; set; } = "Generic";
    public string BaseUrl { get; set; } = "";
    public JsonObject? RequestDefinition { get; set; }
    public string ExtractorScript { get; set; } = "";
    public int TimeoutSeconds { get; set; } = 10;
    public int IntervalMinutes { get; set; } = 5;
    public string? TrustedDestination { get; set; }
    public JsonObject Secrets { get; set; } = new() { ["ApiKey"] = "", ["AccessToken"] = "", ["UserId"] = "" };
    public string DisplayName => (Enabled ? "● " : "○ ") + Name;
    public override string ToString() => DisplayName;

    public static string Origin(string url)
    {
        if (!Uri.TryCreate(url.Trim(), UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") ||
            string.IsNullOrEmpty(uri.Host) || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0 || uri.Query.Length != 0 ||
            (uri.Scheme == "http" && !uri.IsLoopback)) throw new InvalidDataException("基础地址必须为 HTTPS，或本机回环 HTTP 地址。不能包含凭据、查询参数或片段。");
        return $"{uri.Scheme}://{uri.IdnHost.ToLowerInvariant()}:{uri.Port}";
    }
    public void Validate()
    {
        if (!Guid.TryParse(Id, out var id) || id == Guid.Empty || Name.Trim().Length is < 1 or > 256) throw new InvalidDataException("中转站名称或标识无效。");
        _ = Origin(BaseUrl);
        if (ProviderKind is not ("Generic" or "Custom") || Encoding.UTF8.GetByteCount(ExtractorScript) is 0 or > 262144)
            throw new InvalidDataException("查询规则无效。");
        if (TimeoutSeconds is < 2 or > 30 || IntervalMinutes is < 0 or > 1440) throw new InvalidDataException("超时须为 2–30 秒，间隔须为 0–1440 分钟。");
        if (TrustedDestination is not null && Origin(TrustedDestination) != TrustedDestination) throw new InvalidDataException("目标地址信任无效。");
        foreach (var name in new[] { "ApiKey", "AccessToken", "UserId" })
        {
            var value = Secrets[name].Text();
            if (value.Length > 0) { try { _ = Convert.FromBase64String(value); } catch (FormatException) { throw new InvalidDataException("加密凭据无效。"); } }
        }
        if (ProviderKind == "Custom") { if (RequestDefinition is not null) throw new InvalidDataException("Custom 类型不能使用结构化请求。"); return; }
        if (RequestDefinition is null || RequestDefinition["Method"].Text() is not ("GET" or "POST" or "PUT") ||
            RequestDefinition["Path"].Text() is not string path || !path.StartsWith('/') || path.StartsWith("//")) throw new InvalidDataException("请求方法或路径无效。");
        foreach (var key in new[] { "Query", "Headers" })
            if (RequestDefinition[key] is not JsonObject map || map.Any(p => p.Value is not JsonValue v || !v.TryGetValue<string>(out _)))
                throw new InvalidDataException("查询参数和请求头必须为字符串键值 JSON。");
    }
    public JsonObject ToJson() => new()
    {
        ["Id"] = Id, ["Name"] = Name.Trim(), ["Enabled"] = Enabled, ["ProviderKind"] = ProviderKind, ["BaseUrl"] = BaseUrl.Trim(),
        ["RequestDefinition"] = RequestDefinition?.DeepClone(), ["ExtractorScript"] = ExtractorScript, ["TimeoutSeconds"] = TimeoutSeconds,
        ["IntervalMinutes"] = IntervalMinutes, ["TrustedDestination"] = TrustedDestination, ["Secrets"] = Secrets.DeepClone()
    };
    public static RelayProvider FromJson(JsonNode node, bool legacy = false)
    {
        var expected = legacy ? new[] { "Id", "Name", "Enabled", "BaseUrl", "TemplateType", "Script", "TimeoutSeconds", "IntervalMinutes", "TrustedDestination", "Secrets" }
            : new[] { "Id", "Name", "Enabled", "ProviderKind", "BaseUrl", "RequestDefinition", "ExtractorScript", "TimeoutSeconds", "IntervalMinutes", "TrustedDestination", "Secrets" };
        if (node is not JsonObject obj || obj.Count != expected.Length || expected.Any(name => !obj.ContainsKey(name)) ||
            node.Field("Enabled") is not JsonValue enabled || !enabled.TryGetValue<bool>(out _)) throw new InvalidDataException("Invalid provider definition.");
        var provider = new RelayProvider
        {
            Id = node.Field("Id").Text(), Name = node.Field("Name").Text(), Enabled = node.Field("Enabled").Bool(),
            ProviderKind = legacy ? "Custom" : node.Field("ProviderKind").Text(), BaseUrl = node.Field("BaseUrl").Text(),
            RequestDefinition = legacy ? null : node.Field("RequestDefinition")?.DeepClone() as JsonObject,
            ExtractorScript = node.Field(legacy ? "Script" : "ExtractorScript").Text(), TimeoutSeconds = node.Field("TimeoutSeconds").Int(),
            IntervalMinutes = node.Field("IntervalMinutes").Int(), TrustedDestination = node.Field("TrustedDestination")?.Text(),
            Secrets = node.Field("Secrets")?.DeepClone() as JsonObject ?? new JsonObject()
        };
        provider.Validate(); return provider;
    }
    public static List<RelayProvider> ReadDocument(JsonObject? document)
    {
        if (document is null) return new();
        var schema = document["SchemaVersion"].Int();
        if (schema is not (1 or 2) || document["Providers"] is not JsonArray providers || providers.Count > 100)
            throw new InvalidDataException("Unsupported relay provider file.");
        var items = providers.Select(n => FromJson(n ?? throw new InvalidDataException("Invalid provider."), schema == 1)).ToList();
        if (items.Select(p => p.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != items.Count) throw new InvalidDataException("Duplicate provider identifiers.");
        return items;
    }
    public static JsonObject Document(IEnumerable<RelayProvider> providers) => new() { ["SchemaVersion"] = 2, ["Providers"] = new JsonArray(providers.Select(p => (JsonNode)p.ToJson()).ToArray()) };
    public JsonObject Command(string id, Func<string, string> unprotect) => new()
    {
        ["id"] = id, ["operation"] = "query", ["providerKind"] = ProviderKind.ToLowerInvariant(), ["baseUrl"] = BaseUrl,
        ["requestDefinition"] = RequestDefinition is null ? null : new JsonObject
        {
            ["method"] = RequestDefinition["Method"]?.DeepClone(), ["path"] = RequestDefinition["Path"]?.DeepClone(),
            ["query"] = RequestDefinition["Query"]?.DeepClone(), ["headers"] = RequestDefinition["Headers"]?.DeepClone(), ["body"] = RequestDefinition["Body"]?.DeepClone()
        },
        ["extractorScript"] = ExtractorScript, ["secrets"] = new JsonObject
        { ["apiKey"] = unprotect(Secrets["ApiKey"].Text()), ["accessToken"] = unprotect(Secrets["AccessToken"].Text()), ["userId"] = unprotect(Secrets["UserId"].Text()) },
        ["timeoutMs"] = TimeoutSeconds * 1000, ["trustedDestination"] = TrustedDestination
    };
}
