using System.Globalization;
using System.Text.Json.Nodes;

namespace CodexQuotaMonitor.Core;

public sealed class RelayState
{
    public string Status { get; private set; } = "Starting";
    public string ErrorCategory { get; private set; } = "";
    public DateTimeOffset? UpdatedAt { get; private set; }
    public JsonArray Results { get; private set; } = new();
    public DateTimeOffset NextDue { get; private set; } = DateTimeOffset.MinValue;
    public bool Running { get; set; }
    public bool Blocked { get; private set; }
    private int failures;

    public void LoadCache(JsonNode cache)
    {
        if (cache.Field("Results") is JsonArray results && results.Count is > 0 and <= 32 && cache.Field("UpdatedAt").Date() is DateTimeOffset updated)
        { Results = (JsonArray)results.DeepClone(); UpdatedAt = updated; Status = "Stale"; }
    }
    public static void ValidateResponse(JsonObject response)
    {
        if (response["ok"] is not JsonValue ok || !ok.TryGetValue<bool>(out var succeeded)) throw new InvalidDataException("Invalid relay response.");
        if (!succeeded)
        {
            if (response["error"] is not JsonObject error || string.IsNullOrWhiteSpace(error["category"].Text())) throw new InvalidDataException("Invalid relay error.");
            return;
        }
        if (response["results"] is not JsonArray results || results.Count is < 1 or > 32) throw new InvalidDataException("Invalid usage results.");
        foreach (var row in results)
        {
            if (row is not JsonObject || row.Field("isValid") is not JsonValue valid || !valid.TryGetValue<bool>(out _)) throw new InvalidDataException("Invalid usage result.");
            foreach (var field in new[] { "remaining", "total", "used" })
                if (row.Field(field) is not null && row.Field(field).Number() is null) throw new InvalidDataException("Invalid usage amount.");
            foreach (var field in new[] { "invalidMessage", "unit", "planName", "extra" })
                if (row.Field(field) is not null && (row.Field(field) is not JsonValue text || !text.TryGetValue<string>(out var value) || value.Length > 4096))
                    throw new InvalidDataException("Invalid usage text.");
        }
    }
    public void Complete(JsonObject response, RelayProvider provider, DateTimeOffset now)
    {
        ValidateResponse(response);
        if (response["ok"].Bool())
        {
            Results = new JsonArray(response["results"].Array().Select(r => (JsonNode?)new JsonObject
            {
                ["IsValid"] = r.Field("isValid")?.DeepClone(), ["InvalidMessage"] = r.Field("invalidMessage")?.DeepClone(),
                ["Remaining"] = r.Field("remaining")?.DeepClone(), ["Unit"] = r.Field("unit")?.DeepClone(),
                ["PlanName"] = r.Field("planName")?.DeepClone(), ["Total"] = r.Field("total")?.DeepClone(),
                ["Used"] = r.Field("used")?.DeepClone(), ["Extra"] = r.Field("extra")?.DeepClone()
            }).ToArray());
            UpdatedAt = now; Status = "Live"; ErrorCategory = ""; failures = 0; Blocked = false;
            NextDue = provider.IntervalMinutes == 0 ? DateTimeOffset.MaxValue : now.AddMinutes(provider.IntervalMinutes);
            return;
        }
        var error = response["error"]!;
        Fail(error.Field("category").Text("SidecarLifecycle"), provider, now, error.Field("httpStatus").Int(), error.Field("retryAfterSeconds").Int());
    }
    public void Fail(string category, RelayProvider provider, DateTimeOffset now, int httpStatus = 0, int retryAfterSeconds = 0)
    {
        ErrorCategory = category;
        Blocked = category is "Authentication" or "AuthRequired" or "DestinationTrustRequired" or "Protocol" or "Script" or "Configuration" or
            "ScriptSyntax" or "ScriptTimeout" or "ScriptMemory" or "RequestValidation" or "RequestTooLarge" or "DestinationValidation" or
            "EndpointNotFound" or "ExtractorExecution" or "ResultValidation" || (category == "HttpStatus" && httpStatus is >= 400 and < 500 && httpStatus != 429);
        Status = category is "Authentication" or "AuthRequired" || httpStatus is 401 or 403 ? "AuthRequired" : Blocked ? "InvalidScript" : UpdatedAt is null ? "Unavailable" : "Stale";
        failures++;
        var backoff = new[] { 1, 2, 5, 10, 30, 60 }[Math.Min(failures - 1, 5)];
        NextDue = Blocked || provider.IntervalMinutes == 0 ? DateTimeOffset.MaxValue : now.AddSeconds(Math.Max(backoff * 60, Math.Clamp(retryAfterSeconds, 0, 86400)));
    }
    public JsonObject? Cache(string providerId) => UpdatedAt is DateTimeOffset date && Results.Count > 0
        ? new JsonObject { ["ProviderId"] = providerId, ["UpdatedAt"] = date.ToUniversalTime().ToString("o"), ["Results"] = Results.DeepClone() } : null;

    public IEnumerable<DisplayRow> Rows(RelayProvider provider, double? dailySpend = null)
    {
        if (!provider.Enabled) yield break;
        if (Results.Count == 0)
        {
            yield return new($"relay:{provider.Id}:status", provider.Id, provider.Name, provider.Name, "--", Quota.StatusText(Status), null, State: Status);
            yield break;
        }
        var spendShown = false;
        for (var i = 0; i < Results.Count; i++)
        {
            var result = Results[i];
            var remaining = result.Field("Remaining").Number(); var total = result.Field("Total").Number(); var used = result.Field("Used").Number();
            var unit = result.Field("Unit").Text(); var plan = result.Field("PlanName").Text();
            var value = remaining is double amount ? total is > 0 ? Ratio(amount, total.Value, unit) : Amount(amount, unit)
                : used is double consumed && total is > 0 ? Ratio(consumed, total.Value, unit) + " used" : "--";
            double? progress = remaining.HasValue && total is > 0 ? Math.Clamp(remaining.Value / total.Value * 100, 0, 100)
                : used.HasValue && total is > 0 ? Math.Clamp((total.Value - used.Value) / total.Value * 100, 0, 100) : unit == "%" ? remaining : null;
            var detail = Status != "Live" ? Quota.StatusText(Status) : result.Field("Extra").Text(result.Field("InvalidMessage").Text());
            if (detail.Length > 256) detail = detail[..256];
            if (!spendShown && dailySpend is double consumedToday && result.Field("IsValid").Bool() &&
                unit.Equals("USD", StringComparison.OrdinalIgnoreCase) && result.Field("Total") is null && remaining is >= 0)
            {
                var spendText = "今日消耗 " + Amount(consumedToday, "USD").Replace(" USD", "");
                detail = string.IsNullOrWhiteSpace(detail) ? spendText : detail + "\n" + spendText;
                spendShown = true;
            }
            yield return new($"relay:{provider.Id}:{i}", provider.Id, provider.Name, plan.Length > 0 ? plan : provider.Name,
                value, detail, progress, Stale: Status != "Live", State: Status);
        }
    }
    private static string Number(double number, string unit) => number.ToString(unit.ToUpperInvariant() is "USD" or "CNY" ? "0.00" : "0.########", CultureInfo.InvariantCulture);
    public static string Amount(double number, string unit) => (unit.ToUpperInvariant() switch { "USD" => "$", "CNY" => "¥", _ => "" }) + Number(number, unit) + (unit.Length > 0 ? " " + unit : "");
    private static string Ratio(double number, double total, string unit) => Amount(number, unit).Replace(" " + unit, "") + " / " + Amount(total, unit);
}

public sealed class DailySpend
{
    private JsonObject document;
    public DailySpend(JsonObject? value = null) => document = value ?? new() { ["SchemaVersion"] = 1, ["Date"] = "", ["Providers"] = new JsonObject() };
    public JsonObject Document => document;
    public bool Track(string id, JsonArray results, DateTimeOffset now)
    {
        var date = now.ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var changed = document["Date"].Text() != date;
        if (changed) document = new() { ["SchemaVersion"] = 1, ["Date"] = date, ["Providers"] = new JsonObject() };
        var peaks = (JsonObject)document["Providers"]!;
        double sum = 0; bool hasWallet = false;
        foreach (var result in results)
            if (result.Field("IsValid").Bool() && result.Field("Unit").Text().Equals("USD", StringComparison.OrdinalIgnoreCase) &&
                result.Field("Total") is null && result.Field("Remaining").Number() is double balance && balance >= 0)
            { sum += balance; hasWallet = true; }
        if (hasWallet && (peaks[id].Number() is not double old || sum > old)) { peaks[id] = sum; changed = true; }
        return changed;
    }
    public double? Get(string id, JsonArray results, DateTimeOffset now)
    {
        if (document["Date"].Text() != now.ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) || document["Providers"]?[id].Number() is not double peak) return null;
        var balances = results.Where(r => r.Field("IsValid").Bool() && r.Field("Unit").Text().Equals("USD", StringComparison.OrdinalIgnoreCase) && r.Field("Total") is null)
            .Select(r => r.Field("Remaining").Number()).Where(n => n.HasValue).ToList();
        return balances.Count > 0 ? Math.Max(0, peak - balances.Sum(n => n!.Value)) : null;
    }
}
