using System.Text.Json.Nodes;

namespace CodexQuotaMonitor.Core;

public sealed class MonitorSettings
{
    public JsonObject Document { get; }
    public MonitorSettings(JsonObject? document = null)
    {
        Document = document?.DeepClone() as JsonObject ?? Defaults();
        var schema = Document["SchemaVersion"].Int();
        if (schema is < 1 or > 3) throw new InvalidDataException("Unsupported settings schema.");
        if (schema == 1)
        {
            var old = Document;
            Document = Defaults();
            if (old["Window"] is JsonObject window)
            {
                var full = (JsonObject)Document["Window"]!["Full"]!;
                foreach (var name in new[] { "Left", "Top", "Width", "Height", "Topmost", "Visible" })
                    if (window.ContainsKey(name)) full[name] = window[name]?.DeepClone();
            }
            if (old["Appearance"] is JsonObject appearance)
                foreach (var name in new[] { "Theme", "DisplayMode", "FullLayout", "RememberLastMode" })
                    if (appearance.ContainsKey(name)) Document["Appearance"]![name] = appearance[name]?.DeepClone();
            if (old.ContainsKey("Startup")) Document["Startup"] = old["Startup"]?.DeepClone();
        }
        Document["SchemaVersion"] = 3;
        FillDefaults(Document, Defaults());
        if (Theme is not ("Dark" or "Light") || Mode is not ("Full" or "CompactBar" or "Orb") || Layout is not ("Overview" or "Tabs"))
            throw new InvalidDataException("Invalid display settings.");
        foreach (var mode in new[] { "Full", "CompactBar", "Orb" })
            foreach (var coordinate in new[] { "Left", "Top" })
                if (Position(mode)[coordinate] is not null && Position(mode)[coordinate].Number() is null) throw new InvalidDataException("Invalid window position.");
    }

    private static void FillDefaults(JsonObject target, JsonObject defaults)
    {
        foreach (var pair in defaults)
        {
            if (!target.ContainsKey(pair.Key)) { target[pair.Key] = pair.Value?.DeepClone(); continue; }
            if (pair.Value is JsonObject child)
            {
                if (target[pair.Key] is not JsonObject value) throw new InvalidDataException("Invalid settings section.");
                FillDefaults(value, child);
            }
            else if (pair.Value is JsonValue boolean && boolean.TryGetValue<bool>(out _) && (target[pair.Key] is not JsonValue value || !value.TryGetValue<bool>(out _)))
                throw new InvalidDataException("Invalid settings value.");
        }
    }

    public static JsonObject Defaults() => JsonData.Parse("""
        {"SchemaVersion":3,"Appearance":{"Theme":"Dark","DisplayMode":"Full","FullLayout":"Overview","RememberLastMode":true},
        "Window":{"Full":{"Left":null,"Top":null,"Width":420,"Height":560,"Topmost":true,"Visible":true},"CompactBar":{"Left":null,"Top":null},"Orb":{"Left":null,"Top":null}},
        "Compact":{"FocusMetric":"Auto"},"Relay":{"AutoQueryIntervalMinutes":10,"ShowTodaySpend":true},"Startup":true}
        """);

    public string Theme { get => Document["Appearance"]!["Theme"].Text("Dark"); set => Document["Appearance"]!["Theme"] = value; }
    public string Mode { get => Document["Appearance"]!["DisplayMode"].Text("Full"); set => Document["Appearance"]!["DisplayMode"] = value; }
    public string Layout { get => Document["Appearance"]!["FullLayout"].Text("Overview"); set => Document["Appearance"]!["FullLayout"] = value; }
    public string Focus { get => Document["Compact"]!["FocusMetric"].Text("Auto"); set => Document["Compact"]!["FocusMetric"] = value; }
    public bool Topmost { get => Position("Full")["Topmost"].Bool(true); set => Position("Full")["Topmost"] = value; }
    public bool Visible { get => Position("Full")["Visible"].Bool(true); set => Position("Full")["Visible"] = value; }
    public bool Startup { get => Document["Startup"].Bool(true); set => Document["Startup"] = value; }
    public bool TodaySpend { get => Document["Relay"]!["ShowTodaySpend"].Bool(true); set => Document["Relay"]!["ShowTodaySpend"] = value; }
    public JsonObject Position(string mode)
    {
        var windows = (JsonObject)Document["Window"]!;
        return windows[mode] as JsonObject ?? (JsonObject)(windows[mode] = new JsonObject())!;
    }
}
