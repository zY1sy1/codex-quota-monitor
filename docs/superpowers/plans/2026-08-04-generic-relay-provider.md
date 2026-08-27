# Generic Relay Provider Queries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace brand-specific relay templates with a schema-2 Generic provider model that can safely query arbitrary trusted HTTP/HTTPS relay APIs while migrating existing providers without manual reconstruction.

**Architecture:** Keep the PowerShell runtime, cache, scheduler, official Codex session, and sanitized result contract unchanged at their boundaries. Move request construction into a typed `RequestDefinition` handled by the Rust sidecar, keep extraction as bounded QuickJS code, and make every provider use one canonical destination fingerprint. The PowerShell store reads schema 1, migrates each provider independently to schema 2, and writes only the new model.

**Tech Stack:** PowerShell 7.4/WPF, Rust stable, `serde`, `reqwest`, `url`, `rquickjs`, Pester 5.7, Cargo tests, fake loopback HTTP fixtures.

---

### Task 1: Add failing schema-2 model and migration tests

**Files:**
- Modify: `tests/Unit/RelayProviderStore.Tests.ps1`
- Modify: `tests/Integration/RelayScriptClient.Tests.ps1`
- Modify: `tests/Integration/RelayEndToEnd.Tests.ps1`
- Test command: `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite Unit`

- [ ] **Step 1: Add a schema-2 fixture helper before changing production code**

```powershell
function New-TestSchemaTwoGenericProvider {
    param(
        [string]$Id = '3d07f147-5d2d-44e3-9184-cf70acc2b30c',
        [string]$BaseUrl = 'https://relay.example'
    )

    [ordered]@{
        Id = $Id
        Name = 'Generic relay'
        Enabled = $true
        ProviderKind = 'Generic'
        BaseUrl = $BaseUrl
        RequestDefinition = [ordered]@{
            Method = 'GET'
            Path = '/usage'
            Query = [ordered]@{ scope = 'current' }
            Headers = [ordered]@{ Authorization = 'Bearer {{apiKey}}' }
            Body = $null
        }
        ExtractorScript = 'function(response){return {isValid:true,remaining:response.balance,unit:"USD"};}'
        TimeoutSeconds = 10
        IntervalMinutes = 10
        TrustedDestination = 'https://relay.example:443'
        Secrets = [ordered]@{ ApiKey = 'AQIDBA=='; AccessToken = ''; UserId = '' }
    }
}
```

- [ ] **Step 2: Add one failing schema-2 canonicalization test**

```powershell
It 'canonicalizes a Generic schema-two provider with structured request fields' {
    $document = [ordered]@{
        SchemaVersion = 2
        Providers = [object[]]@(New-TestSchemaTwoGenericProvider)
    }

    $canonical = ConvertTo-CanonicalRelayProviderDocument -Document $document

    $canonical.SchemaVersion | Should -Be 2
    ($canonical.Providers[0].Keys -join ',') |
        Should -BeExactly 'Id,Name,Enabled,ProviderKind,BaseUrl,RequestDefinition,ExtractorScript,TimeoutSeconds,IntervalMinutes,TrustedDestination,Secrets'
    $canonical.Providers[0].RequestDefinition.Method | Should -BeExactly 'GET'
    $canonical.Providers[0].RequestDefinition.Query.scope | Should -BeExactly 'current'
}
```

- [ ] **Step 3: Add one failing migration test per legacy kind**

```powershell
It 'migrates Wakaka, General, NewApi, and Custom schema-one providers independently' {
    $legacy = [ordered]@{
        SchemaVersion = 1
        Providers = [object[]]@(
            (New-TestRelayProviderDocument).Providers[0],
            (New-TestRelayProviderDocument -Id '41111111-1111-1111-1111-111111111111'),
            (New-TestRelayProviderDocument -Id '42222222-2222-2222-2222-222222222222'),
            (New-TestRelayProviderDocument -Id '43333333-3333-3333-3333-333333333333')
        )
    }
    $legacy.Providers[1].TemplateType = 'General'
    $legacy.Providers[1].Script = '({request:{url:"{{baseUrl}}/user/balance",method:"GET",headers:{}},extractor:r=>r})'
    $legacy.Providers[2].TemplateType = 'NewApi'
    $legacy.Providers[2].Script = '({request:{url:"{{baseUrl}}/api/user/self",method:"GET",headers:{}},extractor:r=>r})'
    $legacy.Providers[3].TemplateType = 'Custom'
    $legacy.Providers[3].BaseUrl = 'https://custom.example'
    $legacy.Providers[3].Script = '({request:{url:"https://custom.example/private",method:"GET",headers:{}},extractor:r=>r})'

    $migrated = ConvertTo-CanonicalRelayProviderDocument -Document $legacy

    $migrated.SchemaVersion | Should -Be 2
    @($migrated.Providers | Where-Object ProviderKind -eq 'Generic').Count | Should -Be 3
    @($migrated.Providers | Where-Object ProviderKind -eq 'Custom').Count | Should -Be 1
    $migrated.Providers[0].Secrets.ApiKey | Should -BeExactly 'AQIDBA=='
}
```

- [ ] **Step 4: Run the focused suite and verify the new tests fail for the missing schema-2 behavior**

Run: `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite Unit`

Expected: FAIL in the new schema-2 tests with the current schema-one field/order or unsupported schema-version behavior; existing tests may also identify the exact compatibility assertions that need updating.

### Task 2: Implement PowerShell schema-2 canonicalization and independent migration

**Files:**
- Modify: `companion/Private/RelayProviderStore.ps1`
- Modify: `tests/Unit/RelayProviderStore.Tests.ps1`

- [ ] **Step 1: Add bounded helpers for structured request dictionaries and canonical origin fingerprints**

Implement these functions before changing the existing canonicalizer:

```powershell
function ConvertTo-CanonicalRelayStringMap {
    param(
        [AllowNull()][object]$Value,
        [int]$MaximumEntries = 128,
        [int]$MaximumStringBytes = 16384
    )
    if ($null -eq $Value) { return [ordered]@{} }
    if (-not (Test-RelayProviderObject $Value)) { return $null }
    $result = [ordered]@{}
    foreach ($name in @(Get-RelayProviderPropertyNames $Value)) {
        if ($name.Length -eq 0 -or $name.Length -gt 256 -or $result.Contains($name)) { return $null }
        $item = Get-RelayProviderField $Value $name
        if ($item -isnot [string] -or [Text.Encoding]::UTF8.GetByteCount($item) -gt $MaximumStringBytes) {
            return $null
        }
        $result[$name] = $item
    }
    if ($result.Count -gt $MaximumEntries) { return $null }
    return $result
}

function ConvertTo-CanonicalRelayRequestDefinition {
    param([AllowNull()][object]$RequestDefinition)
    if (-not (Test-RelayProviderExactFields $RequestDefinition @('Method','Path','Query','Headers','Body'))) { return $null }
    $method = [string](Get-RelayProviderField $RequestDefinition 'Method').Trim().ToUpperInvariant()
    $path = [string](Get-RelayProviderField $RequestDefinition 'Path')
    $body = Get-RelayProviderField $RequestDefinition 'Body'
    if ($method -notin @('GET','POST','PUT') -or [string]::IsNullOrWhiteSpace($path) -or
        $path.Length -gt 4096 -or $path -match '^(?i)(https?:|//)|[#\x00-\x1f]') { return $null }
    if ($null -ne $body -and $body -isnot [string]) { return $null }
    [ordered]@{
        Method = $method
        Path = $path
        Query = ConvertTo-CanonicalRelayStringMap (Get-RelayProviderField $RequestDefinition 'Query')
        Headers = ConvertTo-CanonicalRelayStringMap (Get-RelayProviderField $RequestDefinition 'Headers')
        Body = $body
    }
}

function ConvertTo-RelayOriginFingerprint {
    param([Parameter(Mandatory)][string]$BaseUrl)
    $uri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http','https') -or [string]::IsNullOrEmpty($uri.Host) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or -not [string]::IsNullOrEmpty($uri.Query)) {
        return $null
    }
    $host = if ($uri.HostNameType -eq [UriHostNameType]::IPv6) { "[$($uri.Host)]" } else { $uri.IdnHost }
    $port = if ($uri.IsDefaultPort) { if ($uri.Scheme -eq 'https') { 443 } else { 80 } } else { $uri.Port }
    "$($uri.Scheme.ToLowerInvariant())://$($host.ToLowerInvariant()):$port"
}
```

The implementation must return `$null` for malformed maps instead of coercing values or copying unknown nested objects. It must reject CR/LF in header names/values and reject URL credentials before the sidecar sees the request.

- [ ] **Step 2: Replace the schema-one canonical provider with a schema-aware canonicalizer**

Use exact fields for schema 2:

```text
Id,Name,Enabled,ProviderKind,BaseUrl,RequestDefinition,ExtractorScript,
TimeoutSeconds,IntervalMinutes,TrustedDestination,Secrets
```

Rules:

1. `ProviderKind` is `Generic` or `Custom`.
2. Generic requires a canonical `RequestDefinition` and non-empty `ExtractorScript`.
3. Custom requires a non-empty `ExtractorScript` containing the complete legacy request/extractor script and stores `RequestDefinition = $null`.
4. Generic and Custom both accept a null trust value; the sidecar will require a matching fingerprint before network access.
5. Preserve the existing ID, name, enabled flag, timeout, interval, DPAPI ciphertext shape, and 100-provider/256-KiB script limits.
6. Normalize a supplied trust value through `ConvertTo-RelayOriginFingerprint`; reject paths, queries, fragments, credentials, and non-canonical ports.

- [ ] **Step 3: Add schema-one migration with safe fallback and no provider-wide abort**

Add `ConvertTo-RelayProviderV1` and `ConvertTo-RelayProviderV1RequestDefinition` helpers. Map legacy values as follows:

```text
Wakaka  -> Generic, GET /v1/usage, Authorization Bearer {{apiKey}}
General -> Generic, GET /user/balance, request extracted from old script
NewApi  -> Generic, GET /api/user/self, request extracted from old script
Custom  -> Custom, RequestDefinition null, full old Script retained in ExtractorScript
```

For legacy Generic candidates, parse the old script only to identify the literal request object. The parser must accept the existing script form and the built-in preset form, extract `url`, `method`, `headers`, and optional string `body`, and reject absolute URLs or dynamic expressions. When extraction fails, migrate the provider as `Custom` with the original script intact and set a non-persistent migration warning returned to the caller; never drop the provider.

For migrated built-ins with no old trust, set `TrustedDestination` to the canonical BaseUrl origin. This preserves no-prompt behavior while the sidecar uses the same exact-fingerprint policy for all provider kinds.

- [ ] **Step 4: Make `Read-RelayProviderStore` write schema 2 only after a successful full-document migration**

`Read-RelayProviderStore` must:

- return an empty schema-2 document when the file is missing;
- accept schema 1 or schema 2;
- migrate each valid provider independently;
- quarantine only a completely unreadable/invalid root document using the existing corruption routine;
- write the canonical schema-2 JSON atomically when the input differs;
- preserve the original provider ID, cache identity, schedule interval, enabled state, and encrypted secrets;
- produce the same schema-2 JSON on the second read.

`Write-RelayProviderStore` must reject schema 1 callers and accept only the canonical schema-2 document.

- [ ] **Step 5: Update the unit assertions and run the store suite**

Update field-order, empty-document, persistence, and preset assertions to schema 2. Add assertions that the raw migrated file contains no legacy `TemplateType`/`Script` fields and that a malformed one-provider script falls back to `ProviderKind = Custom` without losing its script.

Run: `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite Unit`

Expected: all `RelayProviderStore.Tests.ps1` tests pass, including the new migration and idempotence cases.

### Task 3: Add typed Generic request construction to the Rust sidecar

**Files:**
- Modify: `sidecar/relay-quota-host/src/protocol.rs`
- Modify: `sidecar/relay-quota-host/src/script.rs`
- Modify: `sidecar/relay-quota-host/src/lib.rs`
- Create: `sidecar/relay-quota-host/tests/generic_request.rs`

- [ ] **Step 1: Add failing Rust protocol tests for Generic command round trips**

```rust
#[test]
fn generic_query_command_round_trips_structured_request_definition() {
    let command = serde_json::json!({
        "id": "generic-1",
        "operation": "query",
        "providerKind": "generic",
        "baseUrl": "http://127.0.0.1:1234",
        "requestDefinition": {
            "method": "POST",
            "path": "/usage",
            "query": {"scope": "current"},
            "headers": {"Authorization": "Bearer {{apiKey}}"},
            "body": "{\"token\":\"{{accessToken}}\"}"
        },
        "extractorScript": "function(response){return {remaining:response.balance};}",
        "secrets": {"apiKey":"a","accessToken":"b","userId":""},
        "timeoutMs": 10000,
        "trustedDestination": "http://127.0.0.1:1234"
    });
    let parsed: QueryCommand = serde_json::from_value(command).expect("generic command");
    assert_eq!(parsed.provider_kind, ProviderKind::Generic);
    assert_eq!(parsed.request_definition.expect("request").method, "POST");
}
```

- [ ] **Step 2: Run the Rust tests to verify the protocol test fails before implementation**

Run: `cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml generic_query_command_round_trips_structured_request_definition`

Expected: FAIL because `ProviderKind` and `RequestDefinition` do not exist in the current protocol.

- [ ] **Step 3: Define the typed protocol model**

Add the following serde-compatible types and replace `TemplateType` in `QueryCommand`:

```rust
#[derive(Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ProviderKind { Generic, Custom }

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RequestDefinition {
    pub method: String,
    pub path: String,
    pub query: BTreeMap<String, String>,
    pub headers: BTreeMap<String, String>,
    pub body: Option<String>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QueryCommand {
    pub id: String,
    pub operation: Operation,
    pub provider_kind: ProviderKind,
    pub base_url: String,
    pub request_definition: Option<RequestDefinition>,
    pub extractor_script: String,
    pub secrets: SecretSet,
    pub timeout_ms: u64,
    pub trusted_destination: Option<String>,
}
```

`Generic` requires `request_definition`; `Custom` requires the existing combined request/extractor script representation in `extractor_script` and leaves `request_definition` null. Validate that relationship in `execute_query`, returning the existing sanitized `RequestValidation` category.

- [ ] **Step 4: Add bounded token expansion and URL construction for Generic requests**

Implement `evaluate_generic_request(request_definition, base_url, secrets)` without QuickJS. It must:

- allow only `GET`, `POST`, and `PUT`;
- reject empty or absolute `path`, `//` network-path references, fragments, control characters, embedded credentials, and path values that change the origin;
- replace only `{{baseUrl}}`, `{{apiKey}}`, `{{accessToken}}`, and `{{userId}}` in path, query, headers, and body;
- never recursively scan replacement values for more tokens;
- reject invalid header names, CR/LF values, more than 128 entries, and serialized requests over 64 KiB;
- append encoded query pairs with `Url::query_pairs_mut()`;
- preserve `body = null` as no body;
- return the existing `ScriptRequest` type so `http_client.rs` remains the network boundary.

- [ ] **Step 5: Generalize extractor evaluation while retaining Custom compatibility**

Keep `evaluate_extractor_with_context` as the public function used by the host, but make it accept either:

```text
Generic: a function expression, for example function(response){...}
Custom:  the existing object expression containing request and extractor
```

Wrap Generic source as `({extractor: (<source>)})` before QuickJS evaluation. Keep the existing bounded worker, memory limit, timeout, native result normalization, secret substitution, and response-size checks. Do not expose HTTP helpers, filesystem APIs, or process APIs to either script mode.

- [ ] **Step 6: Run focused Rust tests and then the existing sidecar suite**

Run:

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml generic_request
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml request_script extractor_contract protocol_contract
```

Expected: all new Generic request tests and all legacy script/extractor tests pass.

### Task 4: Unify destination trust and HTTP safety for every provider kind

**Files:**
- Modify: `sidecar/relay-quota-host/src/destination.rs`
- Modify: `sidecar/relay-quota-host/src/lib.rs`
- Modify: `sidecar/relay-quota-host/tests/destination_policy.rs`
- Modify: `sidecar/relay-quota-host/tests/http_client.rs`
- Modify: `sidecar/relay-quota-host/tests/protocol_contract.rs`

- [ ] **Step 1: Add failing tests for Generic trust, loopback HTTP, and cross-origin rejection**

```rust
#[test]
fn generic_requires_exact_trusted_origin_and_allows_https_after_trust() {
    let error = validate_destination(
        "https://relay.example/usage",
        "https://relay.example/usage",
        None,
    ).expect_err("first generic destination must require trust");
    assert_eq!(error.category, "DestinationTrustRequired");
    let destination = validate_destination(
        "https://relay.example/usage",
        "https://relay.example/usage",
        Some("https://relay.example:443"),
    ).expect("exact trust");
    assert_eq!(destination.fingerprint(), "https://relay.example:443");
}

#[test]
fn generic_rejects_a_path_that_changes_the_origin() {
    let error = validate_destination(
        "https://relay.example",
        "https://other.example/private",
        Some("https://relay.example:443"),
    ).expect_err("cross origin");
    assert_eq!(error.category, "DestinationValidation");
}
```

- [ ] **Step 2: Run the policy tests and verify they fail against the template-type API**

Run: `cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml destination_policy generic_requires_exact_trusted_origin_and_allows_https_after_trust`

Expected: FAIL because `validate_destination` still accepts `TemplateType` and has brand-specific branches.

- [ ] **Step 3: Change `validate_destination` to compare only canonical origins and trust**

Change the signature to:

```rust
pub fn validate_destination(
    base_url: &str,
    request_url: &str,
    trusted_destination: Option<&str>,
) -> Result<ValidatedDestination, SanitizedError>
```

The function must parse both URLs, reject credentials/non-http schemes/fragments, require the request origin to equal the trusted fingerprint, and permit HTTP only for loopback origins. A null or different fingerprint returns `DestinationTrustRequired` with only sanitized host/fingerprint metadata. There must be no `Wakaka`, `General`, `NewApi`, or `TemplateType` branch in the Rust destination module.

- [ ] **Step 4: Keep redirects disabled and preserve sanitized HTTP error behavior**

Retain the current reqwest redirect policy, timeout, maximum response size, status-first handling, retry-after parsing, and raw-response redaction. Add tests for Generic GET, POST, and PUT requests with query/header/body fields and for a redirect to a different origin.

- [ ] **Step 5: Run all sidecar security tests**

Run: `cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml`

Expected: zero failures and no test output containing credential sentinels.

### Task 5: Update the PowerShell sidecar client and runtime boundary

**Files:**
- Modify: `companion/Private/RelayScriptClient.ps1`
- Modify: `companion/CodexQuotaMonitor.psm1`
- Modify: `tests/Integration/RelayScriptClient.Tests.ps1`
- Modify: `tests/Integration/MonitorRuntime.Tests.ps1`

- [ ] **Step 1: Add a failing client serialization test**

Extend the fake client fixture with a command recorder and assert that Generic calls serialize only the new public fields:

```powershell
It 'serializes a Generic request definition without legacy template fields' {
    $client = Start-TestRelayClient
    $provider = [pscustomobject][ordered]@{
        Id = 'generic-provider'
        ProviderKind = 'Generic'
        BaseUrl = 'https://fixture.invalid'
        RequestDefinition = [pscustomobject][ordered]@{
            Method = 'POST'; Path = '/usage'; Query = @{ scope = 'current' }
            Headers = @{ Authorization = 'Bearer {{apiKey}}' }
            Body = '{"token":"{{accessToken}}"}'
        }
        ExtractorScript = 'function(response){return {remaining:response.balance};}'
        TimeoutSeconds = 2
        TrustedDestination = 'https://fixture.invalid:443'
    }
    $result = Invoke-RelayScriptQuery -Client $client -Provider $provider -Secrets @{
        ApiKey = 'api-secret'; AccessToken = 'access-secret'; UserId = ''
    }
    $result.Ok | Should -BeTrue
    $client.LastCommand.providerKind | Should -BeExactly 'Generic'
    $client.LastCommand.requestDefinition.method | Should -BeExactly 'POST'
    $client.LastCommand.PSObject.Properties.Name | Should -Not -Contain 'templateType'
    ($client.LastCommand | ConvertTo-Json -Depth 12 -Compress) | Should -Not -Match 'api-secret|access-secret'
}
```

- [ ] **Step 2: Run the focused client tests and confirm the new test fails**

Run: `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite Integration`

Expected: FAIL because `Invoke-RelayScriptQuery` currently sends `script` and `templateType`.

- [ ] **Step 3: Serialize the schema-2 provider shape**

Update `Invoke-RelayScriptQuery` to read `ProviderKind`, `RequestDefinition`, and `ExtractorScript`, construct a command with `providerKind`, `requestDefinition`, `extractorScript`, `baseUrl`, `secrets`, `timeoutMs`, and `trustedDestination`, and never include DPAPI ciphertext or raw legacy provider fields. Keep the existing response allowlist and process lifecycle behavior unchanged.

- [ ] **Step 4: Update runtime and controller assumptions to schema 2**

Change all runtime-created provider documents in `CodexQuotaMonitor.psm1` and `InteractionController.ps1` from `SchemaVersion = 1` to `SchemaVersion = 2`. Keep cache schema version 1 because cache rows contain only normalized results. The official App Server functions, relay state transitions, scheduler concurrency, and cache invalidation must not be modified.

- [ ] **Step 5: Run the existing integration suite**

Run: `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite Integration`

Expected: the relay client, runtime isolation, cache, scheduler, and official quota tests pass with schema-2 providers.

### Task 6: Convert presets and fake API coverage to Generic GET and POST providers

**Files:**
- Modify: `companion/Presets/relay-usage.json`
- Modify: `tests/Fixtures/FakeRelayApi.ps1`
- Modify: `tests/Integration/RelayEndToEnd.Tests.ps1`
- Modify: `tests/Unit/RelayProviderStore.Tests.ps1`
- Create: `tests/Fixtures/FakeGenericRelayApi.ps1`

- [ ] **Step 1: Add failing end-to-end tests for arbitrary Generic GET and POST endpoints**

Add two fake routes with request capture:

```powershell
It 'queries a Generic GET provider on an arbitrary loopback path' {
    $provider = New-EndToEndGenericProvider -BaseUrl $api.BaseUrl -Method 'GET' -Path '/generic/get'
    $result = Invoke-RelayScriptQuery -Client $client -Provider $provider -Secrets @{ ApiKey = 'get-secret' }
    $result.Ok | Should -BeTrue
    $result.Results[0].Remaining | Should -Be 42
}

It 'queries a Generic POST provider with body and header authentication' {
    $provider = New-EndToEndGenericProvider -BaseUrl $api.BaseUrl -Method 'POST' -Path '/generic/post' `
        -Headers @{ 'X-Api-Key' = '{{apiKey}}' } -Body '{"user":"{{userId}}"}'
    $result = Invoke-RelayScriptQuery -Client $client -Provider $provider -Secrets @{
        ApiKey = 'post-secret'; AccessToken = ''; UserId = 'user-7'
    }
    $result.Ok | Should -BeTrue
    $result.Results[0].PlanName | Should -BeExactly 'Generic POST'
    ($api.LastRequest | ConvertTo-Json -Depth 8 -Compress) | Should -Not -Match 'post-secret'
}
```

- [ ] **Step 2: Run the new end-to-end tests and verify they fail before fixture and provider support**

Run: `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite EndToEnd`

Expected: FAIL because the fake API has no Generic routes and the provider helper still builds schema-one scripts.

- [ ] **Step 3: Convert the three built-in presets**

Write `SchemaVersion = 2` and `ProviderKind = Generic` for `wakaka`, `general`, and `new-api`. Store `RequestDefinition` separately from `ExtractorScript`; preserve endpoint paths and existing extractor behavior. Add a fourth `custom` preset only if the preset loader/UI needs a visible custom template; it must contain no credentials and no fixed host.

- [ ] **Step 4: Extend the fake API with method, query, header, and body assertions**

The loopback server must return normalized JSON for `/generic/get` and `/generic/post`, record only method/path/query and boolean presence of auth values, and never write actual request headers/body to the stats file. Keep existing Wakaka, General, New API, 429, auth, invalid JSON, and slow routes intact.

- [ ] **Step 5: Update preset registry tests and run end-to-end coverage**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite EndToEnd
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite Unit
```

Expected: legacy fixture queries and both arbitrary Generic routes pass; explicit zero, stale cache, HTTP 429, invalid JSON, concurrency, and official quota isolation remain green.

### Task 7: Update the manager view for Generic request fields

**Files:**
- Modify: `companion/UI/RelayManager.xaml`
- Modify: `companion/Private/RelayManagerView.ps1`
- Modify: `tests/Integration/RelayManagerComposition.Tests.ps1`

- [ ] **Step 1: Add failing WPF contract tests for the Generic controls**

Require these named controls in addition to the existing identity, secret, timing, test, and preview controls:

```text
ProviderKindComboBox
MethodComboBox
PathTextBox
QueryTextBox
HeadersTextBox
BodyTextBox
ExtractorScriptTextBox
AdvancedRequestExpander
MigrationWarningText
```

The test must also assert that `ProviderKindComboBox` contains exactly `Generic` and `Custom`, and that the three secret controls remain `PasswordBox` instances.

- [ ] **Step 2: Run the WPF composition suite and verify it fails on missing controls**

Run: `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite Integration`

Expected: FAIL because the XAML currently exposes only `TemplateComboBox` and one combined `ScriptTextBox`.

- [ ] **Step 3: Add the Generic request editor while preserving the password-only secret boundary**

Add a `ComboBox` for `GET`/`POST`/`PUT`, a path input, and collapsed multiline JSON editors for Query, Headers, and Body. Keep the extraction editor separate from request definition. Custom mode shows only the full script editor and disables the structured request fields. `TextBox.Text` must never be populated with existing ciphertext or decrypted credentials.

- [ ] **Step 4: Update the view adapter contract**

`ReadDraft` must return:

```powershell
[pscustomobject][ordered]@{
    Id; Name; Enabled; ProviderKind; BaseUrl; RequestDefinition;
    ExtractorScript; TimeoutSeconds; IntervalMinutes; TrustedDestination;
    Secrets = [pscustomobject][ordered]@{ ApiKey; AccessToken; UserId }
}
```

`SetDraft` must parse canonical JSON maps for the structured fields, clear password boxes, preserve only the trust fingerprint, and render sanitized preview rows. Trust prompts must continue to display only `scheme://host:port`.

- [ ] **Step 5: Add JSON editor validation and migration warning display**

Malformed Query/Header JSON, non-object maps, invalid body JSON when the user labels it JSON, and empty required Generic fields must disable Test and show `Provider settings are invalid.` without logging the input. Providers migrated to Custom because request extraction failed must display `MigrationWarningText` with a fixed message and keep the original script editable.

- [ ] **Step 6: Run the view composition tests**

Run: `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite Integration`

Expected: all manager adapter tests pass, including secret isolation, sanitized preview, canonical trust display, duplicate/delete behavior, and Generic draft round trips.

### Task 8: Update the manager controller and provider persistence flow

**Files:**
- Modify: `companion/Private/InteractionController.ps1`
- Modify: `tests/Integration/RelayManagerComposition.Tests.ps1`
- Modify: `tests/Unit/RelayScheduler.Tests.ps1`

- [ ] **Step 1: Add failing controller tests for Generic save, trust reset, and preservation of encrypted secrets**

Cover these behaviors:

1. Saving a Generic draft writes schema-2 provider fields and does not write `TemplateType` or legacy `Script`.
2. Changing `BaseUrl`, `RequestDefinition.Path`, or `ProviderKind` clears a previous trust fingerprint unless the canonical origin remains the same and the new test explicitly re-accepts it.
3. Blank password boxes preserve existing ciphertext; entered secrets are protected exactly once.
4. Test success does not persist until Save succeeds.
5. A single invalid provider does not prevent other providers from being applied.

- [ ] **Step 2: Run the controller tests and verify the schema-one candidate fails**

Run: `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite Integration`

Expected: FAIL because `Copy-RelayManagerDraft`, `New-EmptyRelayManagerDraft`, and the save path still use `TemplateType`, `Script`, and `SchemaVersion = 1`.

- [ ] **Step 3: Update draft creation/copy/save to schema 2**

`New-EmptyRelayManagerDraft` defaults to `ProviderKind = Generic`, `GET`, `/user/balance`, empty Query/Body, an Authorization header using `{{apiKey}}`, and the General extractor. `Copy-RelayManagerDraft` copies structured values but returns blank secret fields. Save canonicalizes the schema-2 candidate, writes the document, and passes the same provider object to the runtime.

- [ ] **Step 4: Implement trust invalidation by canonical origin**

Before querying, compare the draft’s current request origin (BaseUrl plus structured path) with `TrustedDestination`. If they differ, pass null trust to the sidecar. On `DestinationTrustRequired`, confirm only the sanitized fingerprint, update the in-memory draft, and retry once. Do not persist until the user presses Save.

- [ ] **Step 5: Preserve scheduler and cache isolation**

When a provider definition changes, remove only that provider’s cache row and state, rebuild its scheduler entry, and leave the official App Server session untouched. Keep `IntervalMinutes = 0` as manual-only.

- [ ] **Step 6: Run all PowerShell unit and integration tests**

Run: `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All`

Expected: all suites pass without raw credential values appearing in Pester output or test artifacts.

### Task 9: Add migration documentation and configuration examples

**Files:**
- Modify: `README.md`
- Create: `docs/relay-provider-migration.md`
- Create: `docs/examples/generic-relay-provider.json`
- Modify: `docs/verification-stage5.md`

- [ ] **Step 1: Add a documentation test for required examples and safety statements**

```powershell
It 'documents Generic providers and schema-two migration' {
    $readme = Get-Content -Raw (Join-Path $script:RepoRoot 'README.md')
    $readme | Should -Match '通用中转站'
    $readme | Should -Match 'ProviderKind'
    $readme | Should -Match 'Schema 1'
    $readme | Should -Match 'POST'
    Test-Path (Join-Path $script:RepoRoot 'docs\relay-provider-migration.md') | Should -BeTrue
    Test-Path (Join-Path $script:RepoRoot 'docs\examples\generic-relay-provider.json') | Should -BeTrue
}
```

- [ ] **Step 2: Document the user-visible model and migration rules**

Explain Generic vs Custom, the request fields, supported placeholders, single/multi-result extraction, unit isolation, explicit destination trust, non-HTTPS loopback restriction, no raw response/credential persistence, provider-by-provider migration fallback, and the fact that official Codex quota is independent.

- [ ] **Step 3: Add a GET and POST configuration example with redacted placeholders**

The JSON example must contain no real host credentials. Include one `GET + Authorization` provider and one `POST + JSON body` provider with `{{apiKey}}`, `{{accessToken}}`, and `{{userId}}` placeholders.

- [ ] **Step 4: Run the documentation test and inspect the rendered JSON**

Run: `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite Unit`

Expected: documentation assertions pass and the example parses as valid schema-2 JSON.

### Task 10: Build, package, and perform fresh requirement verification

**Files:**
- Modify: `build/Build-RelayQuotaHost.ps1` only if the new Rust sources require packaging changes
- Modify: `companion/Bin/relay-quota-host.exe` and `companion/Bin/relay-quota-host.sha256` through the existing build script
- Modify: `outputs/test-results/*.xml` through the existing test script

- [ ] **Step 1: Run formatting and compile checks**

Run:

```powershell
cargo fmt --manifest-path .\sidecar\relay-quota-host\Cargo.toml -- --check
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml
```

Expected: formatting check exits 0 and every Rust test passes.

- [ ] **Step 2: Build the packaged sidecar and verify its hash**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\build\Build-RelayQuotaHost.ps1
pwsh -NoLogo -NoProfile -NonInteractive -File .\build\Verify-PackagedRelayHost.ps1
```

Expected: release build exits 0, the hash manifest matches, and the packaged self-test prints exactly `relay-quota-host: ok` with no stderr.

- [ ] **Step 3: Run the complete PowerShell test matrix**

Run: `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All -CI`

Expected: Pester reports a passed result with zero failed tests for Unit and Integration suites, including the relay end-to-end test file.

- [ ] **Step 4: Verify the acceptance checklist against source and tests**

Confirm all of the following with `rg` and test output:

```text
No production destination branch uses Wakaka/General/NewApi as a security decision.
Generic GET + header auth works.
Generic POST + body auth works.
Single and multi-result extractors work.
Schema-one Wakaka config migrates without rebuilding.
Failed relay providers do not change official quota state.
Credentials, expanded requests, raw responses, and full scripts are absent from logs/cache/health/test diagnostics.
README, migration notes, and examples exist.
```

- [ ] **Step 5: Review the diff and commit only implementation artifacts**

Run: `git diff --check; git status --short; git diff --stat`

Do not add the pre-existing `.superpowers/` directory. Commit the implementation with:

```powershell
git add companion sidecar tests docs README.md build
git commit -m "feat: add generic relay provider queries"
```

