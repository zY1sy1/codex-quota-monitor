using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace CodexQuotaMonitor.Core;

public sealed record QuotaWindow(string Key, string LimitId, string LimitName, string Kind, int Minutes, long ResetsAt, double? Remaining);
public sealed record DisplayRow(string Key, string SourceId, string Source, string Label, string Value, string Detail,
    double? Progress, long ResetsAt = 0, bool Stale = false, string State = "Live", bool Current = false)
{
    public bool Official => SourceId == "official";
    public string DisplayValue => Regex.Replace(Value, @"\s+[A-Z]{3,4}(\s+used)?\s*$", "$1").Trim();
}

public static class Quota
{
    public static List<QuotaWindow> Normalize(JsonObject result)
    {
        var buckets = result.Field("rateLimitsByLimitId") as JsonObject;
        if (buckets is null || buckets.Count == 0)
        {
            buckets = new JsonObject();
            if (result.Field("rateLimits") is JsonObject compatibility)
                buckets[compatibility.Field("limitId").Text("codex")] = compatibility.DeepClone();
        }
        var windows = new List<QuotaWindow>();
        foreach (var pair in buckets)
        {
            var id = pair.Value.Field("limitId").Text(pair.Key);
            var name = pair.Value.Field("limitName").Text();
            foreach (var kind in new[] { "primary", "secondary" })
            {
                if (pair.Value.Field(kind) is not JsonObject window) continue;
                var minutes = window.Field("windowDurationMins").Int();
                var reset = window.Field("resetsAt").Long();
                var used = window.Field("usedPercent").Number();
                windows.Add(new($"{id}|{kind}|{minutes}|{reset}", id, name, kind, minutes, reset,
                    used is double n ? Math.Clamp(100 - n, 0, 100) : null));
            }
        }
        return windows.OrderBy(w => Rank(w.Minutes)).ThenBy(w => w.Minutes).ThenBy(w => w.LimitId, StringComparer.Ordinal)
            .ThenBy(w => w.Kind, StringComparer.Ordinal).ThenBy(w => w.ResetsAt).ThenByDescending(w => w.LimitName.Length)
            .DistinctBy(w => w.Key).ToList();
    }
    private static int Rank(int n) => n is >= 270 and <= 330 ? 0 : n is >= 9000 and <= 11000 ? 1 : 2;
    public static string Label(int minutes, string name) => Rank(minutes) switch { 0 => "5 小时额度", 1 => "周额度", _ => string.IsNullOrWhiteSpace(name) ? $"其他额度 · {minutes} 分钟" : name };
    public static string Countdown(long resetsAt, DateTimeOffset now)
    {
        if (resetsAt <= 0 || resetsAt > DateTimeOffset.MaxValue.ToUnixTimeSeconds()) return "重置时间未知";
        var seconds = resetsAt - now.ToUnixTimeSeconds();
        if (seconds <= 0) return "正在刷新";
        var span = TimeSpan.FromSeconds(seconds);
        return (span.Days > 0 ? $"{span.Days}天 " : "") + $"{span.Hours:00}:{span.Minutes:00}:{span.Seconds:00}";
    }
    public static string ResetTime(long seconds) => seconds > 0 && seconds <= DateTimeOffset.MaxValue.ToUnixTimeSeconds()
        ? DateTimeOffset.FromUnixTimeSeconds(seconds).ToLocalTime().ToString("MM-dd HH:mm", CultureInfo.InvariantCulture) : "";
    public static List<DisplayRow> Official(IEnumerable<QuotaWindow> windows, string state) => windows.Select(w => new DisplayRow(
        "official:" + w.Key, "official", "Codex 官方", Label(w.Minutes, w.LimitName),
        w.Remaining is double n ? n.ToString("0.#", CultureInfo.InvariantCulture) + "%" : "--", "", w.Remaining, w.ResetsAt, state != "Live", state)).ToList();
    public static string StatusText(string state) => state switch
    {
        "Starting" => "正在连接", "Live" => "已连接", "Stale" => "数据已过期", "AuthRequired" => "需要登录或验证凭据",
        "InvalidScript" => "查询规则无效", "Disabled" => "已停用", "Unavailable" => "暂无可用数据", _ => "连接中断，正在重连"
    };
    public static DisplayRow? Focus(IReadOnlyList<DisplayRow> rows, string key) => rows.FirstOrDefault(r => r.Key == key)
        ?? rows.Where(r => r.Progress.HasValue).OrderBy(r => r.Stale).ThenBy(r => r.Progress).FirstOrDefault() ?? rows.FirstOrDefault();
}
