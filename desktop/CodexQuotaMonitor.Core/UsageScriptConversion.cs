using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace CodexQuotaMonitor.Core;

// Only a literal request object and a standalone extractor are split. Anything
// dynamic remains Custom and requires the user's explicit choice in the importer.
public static class UsageScriptConversion
{
    public static bool TryGeneric(string script, string endpoint, out JsonObject? request, out string extractor)
    {
        request = null; extractor = "";
        try
        {
            var prefix = Regex.Match(script, @"^\s*\(?\s*\{\s*request\s*:\s*"); if (!prefix.Success) return false;
            var reader = new LiteralReader(script, prefix.Length); var literal = reader.Object();
            reader.Expect(','); reader.Word("extractor"); reader.Expect(':');
            var start = reader.Position; var function = Regex.Match(script[start..], @"^\s*function\s*\([^)]*\)\s*\{");
            if (!function.Success) return false;
            reader.Position = start + function.Length - 1; reader.Balanced(); var end = reader.Position;
            extractor = script[start..end].Trim();
            if (!Regex.IsMatch(script[end..], @"^\s*\}\s*\)?\s*;?\s*$")) return false;
            if (literal.Any(p => p.Key is not ("url" or "method" or "headers" or "query" or "body"))) return false;
            var url = literal["url"].Text(); var path = "";
            if (url.StartsWith("{{baseUrl}}", StringComparison.Ordinal)) path = url[11..];
            else if (Uri.TryCreate(url, UriKind.Absolute, out var uri) && RelayProvider.Origin(endpoint) == RelayProvider.Origin(uri.GetLeftPart(UriPartial.Authority))) path = uri.PathAndQuery;
            else return false;
            if (path.Length == 0) path = "/";
            request = new JsonObject { ["Method"] = literal["method"].Text("GET").ToUpperInvariant(), ["Path"] = path,
                ["Query"] = literal["query"]?.DeepClone() ?? new JsonObject(), ["Headers"] = literal["headers"]?.DeepClone() ?? new JsonObject(), ["Body"] = literal["body"]?.DeepClone() };
            var provider = new RelayProvider { BaseUrl = endpoint, RequestDefinition = request, ExtractorScript = extractor }; provider.Validate();
            return true;
        }
        catch (Exception ex) when (ex is InvalidDataException or ArgumentOutOfRangeException or FormatException) { request = null; extractor = ""; return false; }
    }
    private sealed class LiteralReader
    {
        private readonly string text; public int Position { get; set; }
        public LiteralReader(string text, int position) { this.text = text; Position = position; }
        private void Space() { while (Position < text.Length && char.IsWhiteSpace(text[Position])) Position++; }
        private char Peek() { Space(); return Position < text.Length ? text[Position] : '\0'; }
        public void Expect(char token) { Space(); if (Position >= text.Length || text[Position++] != token) throw new InvalidDataException(); }
        public void Word(string word) { if (Identifier() != word) throw new InvalidDataException(); }
        private string Identifier()
        {
            Space(); var match = Regex.Match(text[Position..], @"^[A-Za-z_$][A-Za-z0-9_$]*"); if (!match.Success) throw new InvalidDataException();
            Position += match.Length; return match.Value;
        }
        private string String()
        {
            Space(); var quote = text[Position++]; var value = new StringBuilder(); bool closed = false;
            while (Position < text.Length)
            {
                var c = text[Position++]; if (c == quote) { closed = true; break; }
                if (c == '\\') { if (Position >= text.Length) throw new InvalidDataException(); c = text[Position++]; if (c is not ('\\' or '\'' or '"' or '`' or '/')) throw new InvalidDataException(); }
                value.Append(c);
            }
            if (!closed) throw new InvalidDataException();
            var result = Regex.Replace(value.ToString(), @"\$\{(baseUrl|apiKey|accessToken|userId)\}", "{{$1}}");
            if (result.Contains("${", StringComparison.Ordinal)) throw new InvalidDataException(); return result;
        }
        private JsonNode? Expression()
        {
            if (Peek() == '{') return Object();
            if (Peek() == '\0') throw new InvalidDataException();
            string first;
            if (Peek() is '\'' or '"' or '`') first = String();
            else { var name = Identifier(); if (name == "null") return null; if (name is not ("baseUrl" or "apiKey" or "accessToken" or "userId")) throw new InvalidDataException(); first = "{{" + name + "}}"; }
            if (Peek() == '+') { Position++; var second = Expression(); if (second is not JsonValue value || !value.TryGetValue<string>(out var content)) throw new InvalidDataException(); first += content; }
            return JsonValue.Create(first);
        }
        public JsonObject Object()
        {
            Expect('{'); var result = new JsonObject();
            while (Peek() != '}')
            {
                var key = Peek() is '\'' or '"' ? String() : Identifier(); Expect(':'); if (result.ContainsKey(key)) throw new InvalidDataException(); result[key] = Expression();
                if (Peek() == ',') { Position++; continue; } if (Peek() != '}') throw new InvalidDataException();
            }
            Expect('}'); return result;
        }
        public void Balanced()
        {
            Expect('{'); int depth = 1;
            while (Position < text.Length && depth > 0)
            {
                var c = text[Position++];
                if (c is '\'' or '"' or '`') { Position--; _ = String(); }
                else if (c == '/' && Position < text.Length && text[Position] is '/' or '*') throw new InvalidDataException();
                else if (c == '{') depth++; else if (c == '}') depth--;
            }
            if (depth != 0) throw new InvalidDataException();
        }
    }
}
