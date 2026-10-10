using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexQuotaMonitor.Core;

public static class JsonData
{
    public static readonly JsonSerializerOptions Options = new() { WriteIndented = true, MaxDepth = 32, TypeInfoResolver = new System.Text.Json.Serialization.Metadata.DefaultJsonTypeInfoResolver() };
    public static JsonObject Parse(string text) => JsonNode.Parse(text, documentOptions: new() { MaxDepth = 32 }) as JsonObject
        ?? throw new InvalidDataException("Expected a JSON object.");
    public static JsonNode? Field(this JsonNode? node, string key)
    {
        if (node is not JsonObject obj) return null;
        return obj[key] ?? obj.FirstOrDefault(p => string.Equals(p.Key, key, StringComparison.OrdinalIgnoreCase)).Value;
    }
    public static string Text(this JsonNode? node, string fallback = "") => node is JsonValue v && v.TryGetValue<string>(out var s) ? s : fallback;
    public static bool Bool(this JsonNode? node, bool fallback = false) => node is JsonValue v && v.TryGetValue<bool>(out var b) ? b : fallback;
    public static double? Number(this JsonNode? node)
    {
        if (node is JsonValue v && v.TryGetValue<double>(out var d) && double.IsFinite(d)) return d;
        if (node is JsonValue i && i.TryGetValue<int>(out var integer)) return integer;
        if (node is JsonValue l && l.TryGetValue<long>(out var longInteger)) return longInteger;
        return null;
    }
    public static int Int(this JsonNode? node, int fallback = 0) => node.Number() is double d && d == Math.Truncate(d) && d is >= int.MinValue and <= int.MaxValue ? (int)d : fallback;
    public static long Long(this JsonNode? node, long fallback = 0) => node is JsonValue v && v.TryGetValue<long>(out var n) ? n : node is JsonValue i && i.TryGetValue<int>(out var integer) ? integer : fallback;
    public static JsonArray Array(this JsonNode? node) => node as JsonArray ?? new JsonArray();
    public static DateTimeOffset? Date(this JsonNode? node) => DateTimeOffset.TryParse(node.Text(), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var d) ? d : null;
}

public static class JsonFiles
{
    public static JsonObject? Read(string path)
    {
        if (!File.Exists(path)) return null;
        if (new FileInfo(path).Length > 2 * 1024 * 1024) throw new InvalidDataException("The configuration file is too large.");
        return JsonData.Parse(File.ReadAllText(path, Encoding.UTF8));
    }

    public static void Write(string path, JsonObject value)
    {
        path = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(path.ToUpperInvariant())));
        using var mutex = new Mutex(false, "Local\\CodexQuotaMonitor.Settings." + hash);
        bool owned;
        try { owned = mutex.WaitOne(TimeSpan.FromSeconds(10)); }
        catch (AbandonedMutexException) { owned = true; }
        if (!owned) throw new TimeoutException("The configuration is busy.");
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var bytes = Encoding.UTF8.GetBytes(value.ToJsonString(JsonData.Options));
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { stream.Write(bytes); stream.Flush(true); }
            File.Move(temporary, path, true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
            mutex.ReleaseMutex();
        }
    }
}
