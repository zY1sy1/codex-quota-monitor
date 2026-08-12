# CC Switch Usage Script Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a credential-safe, read-only workflow that imports CC Switch balance-query scripts into relay provider drafts, converts supported scripts to Generic providers, and permits an explicit tested Custom fallback.

**Architecture:** Extend `relay-quota-host.exe` with a separate one-shot SQLite inspection mode that selects only approved CC Switch fields and blocks scripts containing suspected literal credentials before they cross the process boundary. Add focused PowerShell modules for discovery, conversion, source-link persistence, and transactional provider/link writes; expose the workflow through a separate WPF import dialog connected to the existing relay manager. Keep `relay-providers.json` at schema 2 and store non-secret provenance in `relay-import-links.json`.

**Tech Stack:** PowerShell 7.4, WPF/XAML, Rust 2021, `rusqlite` with bundled SQLite, `regex`, `zeroize`, serde JSON, Pester 5, Cargo tests.

---

## File structure

### New files

- `sidecar/relay-quota-host/src/cc_switch.rs` — read-only database inspection, credential detection, bounded discovery response, and one-shot stdout protocol.
- `sidecar/relay-quota-host/tests/cc_switch_import.rs` — SQLite fixtures, credential-boundary tests, schema/busy/error tests, and process-mode tests.
- `companion/Private/CcSwitchUsageImport.ps1` — sidecar discovery client, descriptor validation, fingerprinting, and Generic/Custom draft conversion.
- `companion/Private/RelayImportLinkStore.ps1` — canonical source-link store and atomic provider/link transaction.
- `companion/Private/CcSwitchImportView.ps1` — WPF adapter for the import dialog.
- `companion/Private/CcSwitchImportController.ps1` — discovery, selection, update/copy decisions, and conversion orchestration.
- `companion/UI/CcSwitchImport.xaml` — accessible import dialog.
- `tests/Unit/CcSwitchUsageImport.Tests.ps1` — descriptor, fingerprint, conversion, and discovery-client tests.
- `tests/Unit/RelayImportLinkStore.Tests.ps1` — canonical store, corruption, mutation, and rollback tests.
- `tests/Unit/CcSwitchImportController.Tests.ps1` — controller behavior with fake views and discovery responses.
- `tests/Integration/CcSwitchImportComposition.Tests.ps1` — XAML contract and packaged sidecar-to-PowerShell discovery tests.

### Modified files

- `sidecar/relay-quota-host/Cargo.toml` and `Cargo.lock` — pinned SQLite, regex, and zeroization dependencies.
- `sidecar/relay-quota-host/src/main.rs` and `src/lib.rs` — register and dispatch `--inspect-cc-switch`.
- `companion/CodexQuotaMonitor.psm1` — load new modules, expose overridable functions, create the import dialog/controller, and route transactional saves.
- `companion/Private/Settings.ps1` — add `RelayImportLinks` to monitor paths.
- `companion/Private/InteractionController.ps1` — add import callback, imported-draft test fingerprint, and link mutation on save/delete.
- `companion/Private/RelayManagerView.ps1` and `companion/UI/RelayManager.xaml` — add the import entry point and carry hidden import metadata with the draft.
- `companion/Private/RelayState.ps1`, `RelayScheduler.ps1`, and `RelayPresentation.ps1` — preserve precise failure categories and present actionable Chinese text.
- `companion/ThirdPartyNotices.txt` — add SQLite/rusqlite/regex/zeroize notices.
- `README.md` and `docs/relay-provider-migration.md` — document import behavior and credential boundaries.
- Existing unit/integration tests named in the tasks below — update exact contracts and full-runtime composition.

## Task 1: Rust discovery types and credential boundary

**Files:**
- Create: `sidecar/relay-quota-host/src/cc_switch.rs`
- Modify: `sidecar/relay-quota-host/src/lib.rs`
- Modify: `sidecar/relay-quota-host/Cargo.toml`
- Modify: `sidecar/relay-quota-host/Cargo.lock`
- Create: `sidecar/relay-quota-host/tests/cc_switch_import.rs`

- [ ] **Step 1: Add failing credential-classification tests**

Create `sidecar/relay-quota-host/tests/cc_switch_import.rs` with table tests that require placeholders to pass and literal credentials to be blocked:

```rust
use relay_quota_host::cc_switch::{classify_script, ImportStatus};

#[test]
fn blocks_literal_credentials_without_blocking_placeholders() {
    let blocked = [
        r#"({request:{url:'{{baseUrl}}/usage',headers:{Authorization:'Bearer sk-live-1234567890abcdef'}},extractor:r=>r})"#,
        r#"const apiKey = 'abcdef0123456789abcdef0123456789';"#,
        r#"({request:{url:'https://name:password@relay.example/usage'},extractor:r=>r})"#,
        r#"({request:{url:'https://relay.example/usage?token=abcdef0123456789'},extractor:r=>r})"#,
    ];
    for script in blocked {
        assert_eq!(classify_script(script), ImportStatus::CredentialDetected);
    }

    let allowed = [
        r#"({request:{url:'{{baseUrl}}/usage',headers:{Authorization:'Bearer {{apiKey}}'}},extractor:r=>r})"#,
        r#"({request:{url:`${baseUrl}/usage`,headers:{Authorization:`Bearer ${apiKey}`}},extractor:r=>r})"#,
    ];
    for script in allowed {
        assert_eq!(classify_script(script), ImportStatus::Ready);
    }
}

#[test]
fn rejects_control_characters_and_oversized_scripts() {
    assert_eq!(classify_script("function x(){\u{0000}}"), ImportStatus::CredentialDetected);
    assert_eq!(classify_script(&"a".repeat(262_145)), ImportStatus::CredentialDetected);
}
```

- [ ] **Step 2: Run the Rust test to verify it fails**

Run:

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test cc_switch_import
```

Expected: compilation fails because `relay_quota_host::cc_switch` and `classify_script` do not exist.

- [ ] **Step 3: Add pinned dependencies and implement the scanner and response types**

Add to `[dependencies]` in `Cargo.toml`:

```toml
regex = "=1.13.1"
rusqlite = { version = "=0.40.2", features = ["bundled"] }
zeroize = "=1.9.0"
```

Add `pub mod cc_switch;` to `src/lib.rs`. Create `src/cc_switch.rs` with these public types and scanner:

```rust
use std::sync::OnceLock;

use regex::RegexSet;
use serde::Serialize;
use zeroize::Zeroize;

pub const MAX_SCRIPT_BYTES: usize = 262_144;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ImportStatus {
    Ready,
    CredentialDetected,
    UnsupportedLanguage,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CcSwitchProviderDescriptor {
    pub source_provider_id: String,
    pub source_app_type: String,
    pub name: String,
    pub endpoint_candidates: Vec<String>,
    pub language: String,
    pub code: Option<String>,
    pub timeout_seconds: u64,
    pub template_type: String,
    pub auto_query_interval_minutes: u64,
    pub import_status: ImportStatus,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CcSwitchDiscoveryError {
    pub category: &'static str,
    pub message: &'static str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CcSwitchDiscoveryResponse {
    pub ok: bool,
    pub providers: Vec<CcSwitchProviderDescriptor>,
    pub error: Option<CcSwitchDiscoveryError>,
}

fn credential_patterns() -> &'static RegexSet {
    static PATTERNS: OnceLock<RegexSet> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        RegexSet::new([
            r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}",
            r"(?i)\bsk-(?:ant-)?[A-Za-z0-9_-]{16,}",
            r#"(?i)\b(api[_-]?key|access[_-]?token|secret)\s*[:=]\s*[\"'][A-Za-z0-9._~+/=-]{16,}[\"']"#,
            r"(?i)https?://[^/\s:@]+:[^@\s/]+@",
            r#"(?i)[?&](api[_-]?key|access[_-]?token|token|secret)=[^&\s\"']{8,}"#,
        ])
        .expect("credential patterns are constants")
    })
}

pub fn classify_script(script: &str) -> ImportStatus {
    if script.len() > MAX_SCRIPT_BYTES
        || script.chars().any(|value| value == '\u{7f}' || (value < ' ' && !matches!(value, '\r' | '\n' | '\t')))
        || credential_patterns().is_match(script)
    {
        ImportStatus::CredentialDetected
    } else {
        ImportStatus::Ready
    }
}

fn block_script(mut code: String, status: ImportStatus) -> (Option<String>, ImportStatus) {
    code.zeroize();
    (None, status)
}
```

- [ ] **Step 4: Run the focused test and regenerate the lockfile**

Run:

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test cc_switch_import
cargo check --manifest-path .\sidecar\relay-quota-host\Cargo.toml --locked
```

Expected: credential tests pass; Cargo updates `Cargo.lock`; locked check succeeds.

- [ ] **Step 5: Commit the scanner boundary**

```powershell
git add sidecar/relay-quota-host/Cargo.toml sidecar/relay-quota-host/Cargo.lock sidecar/relay-quota-host/src/lib.rs sidecar/relay-quota-host/src/cc_switch.rs sidecar/relay-quota-host/tests/cc_switch_import.rs
git commit -m "feat: add CC Switch import credential boundary"
```

## Task 2: Read-only SQLite inspection with a field whitelist

**Files:**
- Modify: `sidecar/relay-quota-host/src/cc_switch.rs`
- Modify: `sidecar/relay-quota-host/tests/cc_switch_import.rs`

- [ ] **Step 1: Add failing SQLite fixture tests**

Add a fixture helper that creates `providers` and `provider_endpoints`, including credential sentinels in forbidden fields. Assert the public response contains the safe script and endpoint but not either sentinel:

```rust
use std::{fs, path::Path};
use rusqlite::{params, Connection};
use relay_quota_host::cc_switch::inspect_cc_switch_database;

fn create_cc_switch_fixture(path: &Path) {
    let connection = Connection::open(path).expect("create fixture database");
    connection.execute_batch(
        "CREATE TABLE providers (
            id TEXT PRIMARY KEY,
            app_type TEXT NOT NULL,
            name TEXT NOT NULL,
            settings_config TEXT NOT NULL,
            meta TEXT NOT NULL
         );
         CREATE TABLE provider_endpoints (
            id INTEGER PRIMARY KEY,
            provider_id TEXT NOT NULL,
            app_type TEXT NOT NULL,
            url TEXT NOT NULL,
            added_at INTEGER NOT NULL
         );"
    ).expect("create fixture schema");
    let meta = serde_json::json!({
        "usage_script": {
            "enabled": true,
            "language": "javascript",
            "code": "({request:{url:'{{baseUrl}}/v1/usage',method:'GET',headers:{Authorization:'Bearer {{apiKey}}'}},extractor:function(response){return {isValid:true,remaining:response.balance,unit:'USD'};}})",
            "timeout": 10,
            "templateType": "general",
            "autoQueryInterval": 10,
            "apiKey": "FORBIDDEN_META_SECRET_78431"
        }
    }).to_string();
    connection.execute(
        "INSERT INTO providers(id,app_type,name,settings_config,meta) VALUES(?1,?2,?3,?4,?5)",
        params!["source-1", "codex", "wakaka", "{\"apiKey\":\"FORBIDDEN_SETTINGS_SECRET_91357\"}", meta],
    ).expect("insert provider");
    connection.execute(
        "INSERT INTO provider_endpoints(provider_id,app_type,url,added_at) VALUES(?1,?2,?3,?4)",
        params!["source-1", "codex", "https://api.wkkapi.com", 1],
    ).expect("insert endpoint");
}

#[test]
fn reads_only_whitelisted_usage_fields() {
    let path = std::env::temp_dir().join(format!("cc-switch-import-{}.db", std::process::id()));
    let _ = fs::remove_file(&path);
    create_cc_switch_fixture(&path);
    let before = fs::metadata(&path).expect("fixture metadata").modified().expect("modified time");
    let response = inspect_cc_switch_database(&path);
    let serialized = serde_json::to_string(&response).expect("serialize response");
    assert!(response.ok);
    assert_eq!(response.providers[0].endpoint_candidates, ["https://api.wkkapi.com"]);
    assert!(serialized.contains("/v1/usage"));
    assert!(!serialized.contains("FORBIDDEN_META_SECRET_78431"));
    assert!(!serialized.contains("FORBIDDEN_SETTINGS_SECRET_91357"));
    assert_eq!(fs::metadata(&path).expect("metadata after").modified().expect("modified time"), before);
    fs::remove_file(path).expect("remove fixture");
}
```

Add tests for a missing database (`CcSwitchNotFound`), missing tables (`CcSwitchSchemaUnsupported`), multiple endpoints sorted and deduplicated, disabled usage scripts omitted, non-JavaScript scripts returned with `UnsupportedLanguage` and no code, and credential-containing code returned with `CredentialDetected` and no code.

- [ ] **Step 2: Run the focused test to verify it fails**

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test cc_switch_import
```

Expected: fails because `inspect_cc_switch_database` is undefined.

- [ ] **Step 3: Implement read-only opening, JSON-path selection, bounds, and error mapping**

Add these constants and the inspector to `cc_switch.rs`:

```rust
use std::{collections::BTreeMap, path::Path, time::Duration};
use rusqlite::{Connection, Error as SqlError, ErrorCode, OpenFlags};

const MAX_PROVIDERS: usize = 128;
const MAX_ENDPOINTS_PER_PROVIDER: usize = 16;
const MAX_TEXT_BYTES: usize = 4096;

const PROVIDER_QUERY: &str = r#"
SELECT
    id,
    app_type,
    name,
    json_extract(meta, '$.usage_script.enabled'),
    json_extract(meta, '$.usage_script.language'),
    json_extract(meta, '$.usage_script.code'),
    json_extract(meta, '$.usage_script.timeout'),
    json_extract(meta, '$.usage_script.templateType'),
    json_extract(meta, '$.usage_script.autoQueryInterval')
FROM providers
WHERE json_type(meta, '$.usage_script') = 'object'
  AND json_extract(meta, '$.usage_script.enabled') = 1
ORDER BY app_type, name, id
LIMIT 129
"#;

const ENDPOINT_QUERY: &str = r#"
SELECT provider_id, app_type, url
FROM provider_endpoints
ORDER BY provider_id, app_type, added_at, url
"#;

fn discovery_failure(category: &'static str, message: &'static str) -> CcSwitchDiscoveryResponse {
    CcSwitchDiscoveryResponse {
        ok: false,
        providers: Vec::new(),
        error: Some(CcSwitchDiscoveryError { category, message }),
    }
}

fn map_sql_error(error: &SqlError) -> CcSwitchDiscoveryResponse {
    match error {
        SqlError::SqliteFailure(inner, _)
            if matches!(inner.code, ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked) =>
        {
            discovery_failure("CcSwitchDatabaseBusy", "CC Switch database is busy.")
        }
        _ => discovery_failure("CcSwitchSchemaUnsupported", "CC Switch database schema is unsupported."),
    }
}

fn valid_text(value: &str) -> bool {
    !value.is_empty() && value.len() <= MAX_TEXT_BYTES && !value.chars().any(|character| character == '\u{7f}' || character < ' ')
}

pub fn inspect_cc_switch_database(path: &Path) -> CcSwitchDiscoveryResponse {
    if !path.is_file() {
        return discovery_failure("CcSwitchNotFound", "CC Switch database was not found.");
    }
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let connection = match Connection::open_with_flags(path, flags) {
        Ok(value) => value,
        Err(error) => return map_sql_error(&error),
    };
    if connection.busy_timeout(Duration::from_millis(250)).is_err() {
        return discovery_failure("CcSwitchDatabaseBusy", "CC Switch database is busy.");
    }

    let mut endpoints: BTreeMap<(String, String), Vec<String>> = BTreeMap::new();
    let mut endpoint_statement = match connection.prepare(ENDPOINT_QUERY) {
        Ok(value) => value,
        Err(error) => return map_sql_error(&error),
    };
    let endpoint_rows = match endpoint_statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
    }) {
        Ok(value) => value,
        Err(error) => return map_sql_error(&error),
    };
    for row in endpoint_rows {
        let (provider_id, app_type, endpoint) = match row { Ok(value) => value, Err(error) => return map_sql_error(&error) };
        if !valid_text(&provider_id) || !valid_text(&app_type) || !valid_text(&endpoint) { continue; }
        let values = endpoints.entry((provider_id, app_type)).or_default();
        if values.len() < MAX_ENDPOINTS_PER_PROVIDER && !values.contains(&endpoint) { values.push(endpoint); }
    }

    let mut statement = match connection.prepare(PROVIDER_QUERY) {
        Ok(value) => value,
        Err(error) => return map_sql_error(&error),
    };
    let rows = match statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?,
            row.get::<_, bool>(3)?, row.get::<_, String>(4)?, row.get::<_, String>(5)?,
            row.get::<_, u64>(6)?, row.get::<_, String>(7)?, row.get::<_, u64>(8)?,
        ))
    }) {
        Ok(value) => value,
        Err(error) => return map_sql_error(&error),
    };

    let mut providers = Vec::new();
    for row in rows {
        let (id, app_type, name, enabled, language, mut code, timeout, template_type, interval) =
            match row { Ok(value) => value, Err(error) => return map_sql_error(&error) };
        if !enabled || !valid_text(&id) || !valid_text(&app_type) || !valid_text(&name) { code.zeroize(); continue; }
        let status = if !language.eq_ignore_ascii_case("javascript") {
            ImportStatus::UnsupportedLanguage
        } else {
            classify_script(&code)
        };
        let code = if status == ImportStatus::Ready { Some(code) } else { block_script(code, status).0 };
        providers.push(CcSwitchProviderDescriptor {
            endpoint_candidates: endpoints.remove(&(id.clone(), app_type.clone())).unwrap_or_default(),
            source_provider_id: id,
            source_app_type: app_type,
            name,
            language,
            code,
            timeout_seconds: timeout.clamp(2, 30),
            template_type,
            auto_query_interval_minutes: interval.min(1440),
            import_status: status,
        });
        if providers.len() > MAX_PROVIDERS {
            return discovery_failure("CcSwitchSchemaUnsupported", "CC Switch provider result is too large.");
        }
    }
    CcSwitchDiscoveryResponse { ok: true, providers, error: None }
}
```

- [ ] **Step 4: Run focused and library tests**

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test cc_switch_import
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --lib
```

Expected: all new database tests and existing library tests pass.

- [ ] **Step 5: Commit the read-only inspector**

```powershell
git add sidecar/relay-quota-host/src/cc_switch.rs sidecar/relay-quota-host/tests/cc_switch_import.rs
git commit -m "feat: inspect CC Switch usage scripts read-only"
```

## Task 3: One-shot sidecar mode and PowerShell discovery client

**Files:**
- Modify: `sidecar/relay-quota-host/src/cc_switch.rs`
- Modify: `sidecar/relay-quota-host/src/main.rs`
- Modify: `sidecar/relay-quota-host/tests/cc_switch_import.rs`
- Create: `companion/Private/CcSwitchUsageImport.ps1`
- Create: `tests/Unit/CcSwitchUsageImport.Tests.ps1`

- [ ] **Step 1: Add failing process and PowerShell client tests**

In the Rust test, launch the compiled binary with `--inspect-cc-switch <fixture>` and assert one JSON line, exit code 0, empty stderr, and absence of credential sentinels. In `tests/Unit/CcSwitchUsageImport.Tests.ps1`, add:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\companion\Private\CcSwitchUsageImport.ps1')
}

Describe 'CC Switch usage discovery client' {
    It 'accepts only the exact sanitized discovery shape' {
        $response = ConvertTo-CcSwitchDiscoveryResponse ([pscustomobject][ordered]@{
            ok = $true
            providers = @([pscustomobject][ordered]@{
                sourceProviderId = 'source-1'; sourceAppType = 'codex'; name = 'wakaka'
                endpointCandidates = @('https://api.wkkapi.com'); language = 'javascript'
                code = "({request:{url:'{{baseUrl}}/v1/usage',method:'GET'},extractor:r=>({isValid:true,remaining:r.balance})})"
                timeoutSeconds = 10; templateType = 'general'; autoQueryIntervalMinutes = 10
                importStatus = 'ready'
            })
            error = $null
        })
        $response.Ok | Should -BeTrue
        $response.Providers[0].Name | Should -BeExactly 'wakaka'
        $response.Providers[0].Code | Should -Match '/v1/usage'
    }

    It 'rejects blocked descriptors that unexpectedly contain code' {
        {
            ConvertTo-CcSwitchDiscoveryResponse ([pscustomobject][ordered]@{
                ok = $true
                providers = @([pscustomobject][ordered]@{
                    sourceProviderId = 'source-1'; sourceAppType = 'codex'; name = 'blocked'
                    endpointCandidates = @(); language = 'javascript'; code = 'secret text'
                    timeoutSeconds = 10; templateType = 'general'; autoQueryIntervalMinutes = 10
                    importStatus = 'credentialDetected'
                })
                error = $null
            })
        } | Should -Throw 'CC Switch discovery response is invalid.'
    }
}
```

- [ ] **Step 2: Run tests to verify both fail**

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test cc_switch_import
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Unit\CcSwitchUsageImport.Tests.ps1 -Output Detailed }"
```

Expected: Rust process test fails because the CLI mode is absent; Pester fails because the new PowerShell file/functions are absent.

- [ ] **Step 3: Implement bounded one-shot JSON output**

Add this function to `cc_switch.rs`:

```rust
use std::io::{self, Write};

pub fn run_inspector_mode(path: &Path) -> i32 {
    let response = inspect_cc_switch_database(path);
    let stdout = io::stdout();
    let mut writer = stdout.lock();
    if serde_json::to_writer(&mut writer, &response).is_err()
        || writer.write_all(b"\n").is_err()
        || writer.flush().is_err()
    {
        return 1;
    }
    if response.ok { 0 } else { 1 }
}
```

Replace argument parsing in `main.rs` with an `OsString` vector and add the two-argument mode:

```rust
fn run() -> i32 {
    let arguments: Vec<_> = env::args_os().skip(1).collect();
    match arguments.as_slice() {
        [] => {
            let stdin = io::stdin();
            let stdout = io::stdout();
            if relay_quota_host::run_jsonl(stdin.lock(), stdout.lock()).is_ok() { 0 } else { 1 }
        }
        [mode] if mode == OsStr::new("--self-test") => write_self_test(),
        [mode] if mode == OsStr::new("--request-worker") => relay_quota_host::script::run_request_worker_mode(),
        [mode] if mode == OsStr::new("--extractor-worker") => relay_quota_host::script::run_extractor_worker_mode(),
        [mode, path] if mode == OsStr::new("--inspect-cc-switch") =>
            relay_quota_host::cc_switch::run_inspector_mode(std::path::Path::new(path)),
        _ => 2,
    }
}

fn write_self_test() -> i32 {
    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    if stdout.write_all(b"relay-quota-host: ok\n").and_then(|()| stdout.flush()).is_ok() { 0 } else { 1 }
}
```

- [ ] **Step 4: Implement the PowerShell discovery client and strict parser**

Create `CcSwitchUsageImport.ps1` with `Get-DefaultCcSwitchDatabasePath`, an exact-field helper, `ConvertTo-CcSwitchDiscoveryResponse`, and `Invoke-CcSwitchUsageDiscovery`. The process must use `--inspect-cc-switch`, a 5-second deadline, a 1 MiB stdout limit, drained-but-never-displayed stderr, and sanitized failure objects:

```powershell
function Get-DefaultCcSwitchDatabasePath {
    [CmdletBinding()]
    param([string]$UserProfile = $env:USERPROFILE)
    if ([string]::IsNullOrWhiteSpace($UserProfile)) { return $null }
    Join-Path ([IO.Path]::GetFullPath($UserProfile)) '.cc-switch\cc-switch.db'
}

function Invoke-CcSwitchUsageDiscovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$DatabasePath,
        [ValidateRange(100, 30000)][int]$TimeoutMilliseconds = 5000
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [IO.Path]::GetFullPath($ExecutablePath)
    $startInfo.ArgumentList.Add('--inspect-cc-switch')
    $startInfo.ArgumentList.Add([IO.Path]::GetFullPath($DatabasePath))
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill($true) } catch {}
            throw 'CC Switch discovery timed out.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()
        if ([Text.Encoding]::UTF8.GetByteCount($stdout) -gt 1048576) {
            throw 'CC Switch discovery response is too large.'
        }
        $raw = $stdout | ConvertFrom-Json -Depth 12 -ErrorAction Stop
        return ConvertTo-CcSwitchDiscoveryResponse $raw
    }
    catch {
        return [pscustomobject][ordered]@{
            Ok = $false; Providers = @(); Error = [pscustomobject][ordered]@{
                Category = 'CcSwitchSchemaUnsupported'
                Message = 'CC Switch usage discovery failed.'
            }
        }
    }
    finally { $process.Dispose() }
}
```

The strict parser must enforce exact root fields `ok,providers,error`, exact provider fields shown in the test, the `code = null` rule for blocked statuses, URI validation for endpoint candidates, provider/script count and byte limits, integer bounds, and allowed status values `ready`, `credentialDetected`, `unsupportedLanguage`.

- [ ] **Step 5: Run focused tests**

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test cc_switch_import
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Unit\CcSwitchUsageImport.Tests.ps1 -Output Detailed }"
```

Expected: process and PowerShell parser/client tests pass; stdout contains no sentinel and stderr remains empty.

- [ ] **Step 6: Commit the discovery protocol**

```powershell
git add sidecar/relay-quota-host/src/main.rs sidecar/relay-quota-host/src/cc_switch.rs sidecar/relay-quota-host/tests/cc_switch_import.rs companion/Private/CcSwitchUsageImport.ps1 tests/Unit/CcSwitchUsageImport.Tests.ps1
git commit -m "feat: expose CC Switch usage discovery"
```

## Task 4: Canonical import-link store and transactional writes

**Files:**
- Create: `companion/Private/RelayImportLinkStore.ps1`
- Create: `tests/Unit/RelayImportLinkStore.Tests.ps1`
- Modify: `companion/Private/Settings.ps1`
- Modify: `tests/Unit/Settings.Tests.ps1`

- [ ] **Step 1: Add failing link-store and rollback tests**

Create tests for the exact schema, duplicate relay IDs, duplicate source tuples, malformed SHA-256, corruption quarantine, upsert/remove mutations, and provider-write rollback. The core happy-path assertion is:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\companion\Private\RelayProviderStore.ps1')
    . (Join-Path $PSScriptRoot '..\..\companion\Private\RelayImportLinkStore.ps1')
}

It 'round-trips the exact non-secret link schema' {
    $path = Join-Path $TestDrive 'relay-import-links.json'
    $document = [ordered]@{
        SchemaVersion = 1
        Links = @([ordered]@{
            RelayProviderId = '11111111-1111-1111-1111-111111111111'
            SourceKind = 'CcSwitchUsageScript'
            SourceProviderId = 'source-1'
            SourceAppType = 'codex'
            ScriptFingerprint = ('a' * 64)
        })
    }
    Write-RelayImportLinkStore -Path $path -Document $document
    $read = Read-RelayImportLinkStore -Path $path
    ($read.PSObject.Properties.Name -join ',') | Should -BeExactly 'SchemaVersion,Links'
    ($read.Links[0].PSObject.Properties.Name -join ',') |
        Should -BeExactly 'RelayProviderId,SourceKind,SourceProviderId,SourceAppType,ScriptFingerprint'
    (Get-Content -Raw $path) |
        Should -Not -Match 'apiKey|accessToken|"token"|balance|BaseUrl|ExtractorScript|"Code"'
}
```

For rollback, seed valid provider/link files, inject a `ReplaceLinkFile` callback that throws, run `Write-RelayProviderImportTransaction`, and assert both original byte sequences remain unchanged.

- [ ] **Step 2: Run the unit test to verify it fails**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Unit\RelayImportLinkStore.Tests.ps1 -Output Detailed }"
```

Expected: fails because `RelayImportLinkStore.ps1` does not exist.

- [ ] **Step 3: Implement the exact store and mutation model**

Create `RelayImportLinkStore.ps1` with these public functions:

```powershell
function New-EmptyRelayImportLinkDocument {
    [pscustomobject][ordered]@{ SchemaVersion = 1; Links = [object[]]@() }
}

function New-RelayImportLinkMutation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('None','Upsert','Remove')][string]$Kind,
        [AllowNull()][object]$Link = $null,
        [AllowNull()][string]$ProviderId = $null
    )
    [pscustomobject][ordered]@{ Kind = $Kind; Link = $Link; ProviderId = $ProviderId }
}

function Update-RelayImportLinkDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Document, [Parameter(Mandatory)][object]$Mutation)
    $canonical = ConvertTo-CanonicalRelayImportLinkDocument $Document
    if ($null -eq $canonical) { throw 'Relay import link store is invalid.' }
    switch ([string]$Mutation.Kind) {
        'None' { return $canonical }
        'Remove' {
            $links = @($canonical.Links | Where-Object RelayProviderId -cne [string]$Mutation.ProviderId)
        }
        'Upsert' {
            $link = ConvertTo-CanonicalRelayImportLink $Mutation.Link
            if ($null -eq $link) { throw 'Relay import link is invalid.' }
            $links = @($canonical.Links | Where-Object RelayProviderId -cne $link.RelayProviderId) + @($link)
        }
    }
    $result = ConvertTo-CanonicalRelayImportLinkDocument ([ordered]@{ SchemaVersion = 1; Links = $links })
    if ($null -eq $result) { throw 'Relay import link mutation is invalid.' }
    return $result
}
```

Canonicalization must require valid non-empty provider/source IDs, `SourceKind` exactly `CcSwitchUsageScript`, source app text without control characters, and a lowercase 64-character hexadecimal fingerprint. Reuse the provider store's atomic UTF-8/no-BOM and corruption-quarantine conventions, with a separate mutex name derived from the absolute link path.

- [ ] **Step 4: Implement the provider/link transaction and path**

Add `RelayImportLinks = Join-Path $root 'data\relay-import-links.json'` to `Get-MonitorPaths`. Implement:

```powershell
function Write-RelayProviderImportTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProviderPath,
        [Parameter(Mandatory)][string]$LinkPath,
        [Parameter(Mandatory)][object]$ProviderDocument,
        [Parameter(Mandatory)][object]$Mutation,
        [scriptblock]$ReplaceProviderFile = ${function:Write-RelayProviderStore},
        [scriptblock]$ReplaceLinkFile = ${function:Write-RelayImportLinkStore}
    )
    $providers = ConvertTo-CanonicalRelayProviderDocument $ProviderDocument
    if ($null -eq $providers) { throw 'Relay provider store is invalid.' }
    $currentLinks = Read-RelayImportLinkStore -Path $LinkPath
    $nextLinks = Update-RelayImportLinkDocument -Document $currentLinks -Mutation $Mutation
    $providerFullPath = [IO.Path]::GetFullPath($ProviderPath)
    $linkFullPath = [IO.Path]::GetFullPath($LinkPath)
    $providerExisted = [IO.File]::Exists($providerFullPath)
    $linkExisted = [IO.File]::Exists($linkFullPath)
    $providerBackup = if ($providerExisted) { [IO.File]::ReadAllBytes($providerFullPath) } else { $null }
    $linkBackup = if ($linkExisted) { [IO.File]::ReadAllBytes($linkFullPath) } else { $null }
    try {
        & $ReplaceProviderFile -Path $ProviderPath -Document $providers
        & $ReplaceLinkFile -Path $LinkPath -Document $nextLinks
    }
    catch {
        $writeError = $_
        $rollbackErrors = [Collections.Generic.List[Exception]]::new()
        try {
            Restore-RelayImportTransactionFile -Path $providerFullPath -Existed $providerExisted -Bytes $providerBackup
        } catch {
            $rollbackErrors.Add($_.Exception)
        }
        try {
            Restore-RelayImportTransactionFile -Path $linkFullPath -Existed $linkExisted -Bytes $linkBackup
        } catch {
            $rollbackErrors.Add($_.Exception)
        }
        if ($rollbackErrors.Count -gt 0) {
            $allErrors = [Collections.Generic.List[Exception]]::new()
            $allErrors.Add($writeError.Exception)
            foreach ($rollbackError in $rollbackErrors) { $allErrors.Add($rollbackError) }
            throw [AggregateException]::new('Relay provider import failed and rollback was incomplete.', $allErrors)
        }
        throw [InvalidOperationException]::new('Relay provider import transaction failed and was rolled back.', $writeError.Exception)
    }
    finally {
        if ($null -ne $providerBackup) { [Array]::Clear($providerBackup, 0, $providerBackup.Length) }
        if ($null -ne $linkBackup) { [Array]::Clear($linkBackup, 0, $linkBackup.Length) }
    }
}

function Restore-RelayImportTransactionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$Existed,
        [AllowNull()][byte[]]$Bytes
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $Existed) {
        if ([IO.File]::Exists($fullPath)) { [IO.File]::Delete($fullPath) }
        return
    }
    if ($null -eq $Bytes) { throw 'Transaction backup bytes are missing.' }
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $tempPath = Join-Path $directory ('.{0}.restore.{1}.tmp' -f [IO.Path]::GetFileName($fullPath), [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllBytes($tempPath, $Bytes)
        if ([IO.File]::Exists($fullPath)) {
            [IO.File]::Replace($tempPath, $fullPath, $null)
        } else {
            [IO.File]::Move($tempPath, $fullPath)
        }
    }
    finally {
        if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
    }
}
```

Keep the public transaction function and its two injected writer callbacks exactly as shown so the write and rollback failure paths remain testable.

- [ ] **Step 5: Run link-store and settings tests**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Unit\RelayImportLinkStore.Tests.ps1,.\tests\Unit\Settings.Tests.ps1 -Output Detailed }"
```

Expected: exact-schema, mutation, rollback, corruption, and new path tests pass.

- [ ] **Step 6: Commit persistence support**

```powershell
git add companion/Private/RelayImportLinkStore.ps1 companion/Private/Settings.ps1 tests/Unit/RelayImportLinkStore.Tests.ps1 tests/Unit/Settings.Tests.ps1
git commit -m "feat: persist CC Switch import links"
```

## Task 5: Convert discovered rules into Generic or Custom drafts

**Files:**
- Modify: `companion/Private/CcSwitchUsageImport.ps1`
- Modify: `tests/Unit/CcSwitchUsageImport.Tests.ps1`
- Modify: `companion/Private/RelayProviderStore.ps1`
- Modify: `tests/Unit/RelayProviderStore.Tests.ps1`

- [ ] **Step 1: Add failing Wakaka, Custom fallback, update, and fingerprint tests**

Add a real-format Wakaka fixture matching the confirmed local CC Switch structure. Assert the existing legacy parser consumes the whole request and produces `GET /v1/usage` plus an Authorization placeholder:

```powershell
It 'converts a CC Switch Wakaka rule into a Generic draft' {
    $descriptor = New-TestCcSwitchDescriptor -Code @'
({
  request: { url: "{{baseUrl}}/v1/usage", method: "GET", headers: { Authorization: "Bearer {{apiKey}}" } },
  extractor: function(response) { const data = response.data ?? response; return { isValid: true, remaining: data.balance, unit: data.currency ?? "USD" }; }
})
'@
    $candidate = ConvertTo-CcSwitchRelayImportCandidate -Descriptor $descriptor `
        -Endpoint 'https://api.wkkapi.com' -ImportMode Auto
    $candidate.Draft.ProviderKind | Should -BeExactly 'Generic'
    $candidate.Draft.RequestDefinition.Method | Should -BeExactly 'GET'
    $candidate.Draft.RequestDefinition.Path | Should -BeExactly '/v1/usage'
    $candidate.Draft.RequestDefinition.Headers.Authorization | Should -BeExactly 'Bearer {{apiKey}}'
    $candidate.Draft.TrustedDestination | Should -BeNullOrEmpty
    $candidate.Link.SourceProviderId | Should -BeExactly 'source-1'
}
```

Add cases proving: an incomplete dynamic request returns `RequiresCustom`; `-ImportMode Custom` preserves the code exactly with `RequestDefinition = $null`; blocked status never converts; endpoint user-info/query/fragment is rejected; two identical descriptors have the same fingerprint; changing code, timeout, interval, or sorted endpoints changes the fingerprint; an update preserves existing ID/name/interval and trust only when the origin is unchanged.

- [ ] **Step 2: Run the unit tests to verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Unit\CcSwitchUsageImport.Tests.ps1,.\tests\Unit\RelayProviderStore.Tests.ps1 -Output Detailed }"
```

Expected: conversion and fingerprint tests fail because the functions are absent.

- [ ] **Step 3: Harden full-consumption legacy conversion**

Extract the current `ConvertFrom-RelayLegacyScript` logic into an import-safe result that reports whether the complete request was consumed. Keep the public compatibility wrapper, and add:

```powershell
function ConvertFrom-RelayUsageScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$TemplateType
    )
    $converted = ConvertFrom-RelayLegacyScript -Script $Script -BaseUrl $BaseUrl -TemplateType $TemplateType
    if ($null -eq $converted) {
        return [pscustomobject][ordered]@{ Status = 'RequiresCustom'; RequestDefinition = $null; ExtractorScript = $null }
    }
    $canonical = ConvertTo-CanonicalRelayRequestDefinition $converted.RequestDefinition
    if ($null -eq $canonical -or -not (Test-RelayExtractorFunctionExpression $converted.ExtractorScript)) {
        return [pscustomobject][ordered]@{ Status = 'Blocked'; RequestDefinition = $null; ExtractorScript = $null }
    }
    [pscustomobject][ordered]@{
        Status = 'Generic'
        RequestDefinition = $canonical
        ExtractorScript = [string]$converted.ExtractorScript
    }
}
```

Extend the parser tests with dynamic Authorization, `JSON.stringify`, unsupported method, absolute request target, and trailing unconsumed request properties; every uncertain case must return `RequiresCustom`, never a partially populated Generic request.

- [ ] **Step 4: Implement fingerprinting and candidate creation**

Add these functions to `CcSwitchUsageImport.ps1`:

```powershell
function Get-CcSwitchUsageScriptFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Descriptor)
    $canonical = [ordered]@{
        Language = [string]$Descriptor.Language
        Code = [string]$Descriptor.Code
        TimeoutSeconds = [int]$Descriptor.TimeoutSeconds
        TemplateType = [string]$Descriptor.TemplateType
        AutoQueryIntervalMinutes = [int]$Descriptor.AutoQueryIntervalMinutes
        EndpointCandidates = [string[]]@($Descriptor.EndpointCandidates | Sort-Object -CaseSensitive -Unique)
    }
    $json = $canonical | ConvertTo-Json -Depth 6 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function ConvertTo-CcSwitchRelayImportCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Descriptor,
        [Parameter(Mandatory)][string]$Endpoint,
        [ValidateSet('Auto','Custom')][string]$ImportMode = 'Auto',
        [AllowNull()][object]$ExistingProvider = $null
    )
    if ([string]$Descriptor.ImportStatus -cne 'Ready' -or $null -eq $Descriptor.Code) {
        throw 'CC Switch usage script cannot be imported.'
    }
    $origin = ConvertTo-RelayOriginFingerprint -BaseUrl $Endpoint
    if ($null -eq $origin) { throw 'CC Switch endpoint is invalid.' }
    $conversion = ConvertFrom-RelayUsageScript -Script ([string]$Descriptor.Code) `
        -BaseUrl $Endpoint -TemplateType ([string]$Descriptor.TemplateType)
    if ($conversion.Status -eq 'RequiresCustom' -and $ImportMode -eq 'Auto') {
        return [pscustomobject][ordered]@{ Status = 'RequiresCustom'; Draft = $null; Link = $null }
    }
    if ($conversion.Status -eq 'Blocked') { throw 'CC Switch usage script is unsupported.' }
    $generic = $conversion.Status -eq 'Generic' -and $ImportMode -eq 'Auto'
    $id = if ($null -eq $ExistingProvider) { [guid]::NewGuid().ToString('D') } else { [string]$ExistingProvider.Id }
    $existingOrigin = if ($null -eq $ExistingProvider) { $null } else { ConvertTo-RelayOriginFingerprint -BaseUrl ([string]$ExistingProvider.BaseUrl) }
    $draft = [pscustomobject][ordered]@{
        Id = $id
        Name = if ($null -eq $ExistingProvider) { [string]$Descriptor.Name } else { [string]$ExistingProvider.Name }
        Enabled = if ($null -eq $ExistingProvider) { $true } else { [bool]$ExistingProvider.Enabled }
        ProviderKind = if ($generic) { 'Generic' } else { 'Custom' }
        BaseUrl = $Endpoint
        RequestDefinition = if ($generic) { $conversion.RequestDefinition } else { $null }
        ExtractorScript = if ($generic) { [string]$conversion.ExtractorScript } else { [string]$Descriptor.Code }
        TimeoutSeconds = [Math]::Clamp([int]$Descriptor.TimeoutSeconds, 2, 30)
        IntervalMinutes = if ($null -eq $ExistingProvider) { [Math]::Clamp([int]$Descriptor.AutoQueryIntervalMinutes, 0, 1440) } else { [int]$ExistingProvider.IntervalMinutes }
        TrustedDestination = if ($origin -ceq $existingOrigin) { $ExistingProvider.TrustedDestination } else { $null }
        MigrationWarning = if ($generic) { $null } else { '已从 CC Switch 导入为 Custom；请检查目标地址并完成测试。' }
        Secrets = [pscustomobject][ordered]@{ ApiKey=''; AccessToken=''; UserId='' }
    }
    $link = [pscustomobject][ordered]@{
        RelayProviderId = $id
        SourceKind = 'CcSwitchUsageScript'
        SourceProviderId = [string]$Descriptor.SourceProviderId
        SourceAppType = [string]$Descriptor.SourceAppType
        ScriptFingerprint = Get-CcSwitchUsageScriptFingerprint $Descriptor
    }
    [pscustomobject][ordered]@{ Status = 'Ready'; Draft = $draft; Link = $link }
}
```

- [ ] **Step 5: Run conversion tests**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Unit\CcSwitchUsageImport.Tests.ps1,.\tests\Unit\RelayProviderStore.Tests.ps1 -Output Detailed }"
```

Expected: Wakaka becomes Generic `/v1/usage`; uncertain scripts require explicit Custom; update/fingerprint tests pass.

- [ ] **Step 6: Commit conversion support**

```powershell
git add companion/Private/CcSwitchUsageImport.ps1 companion/Private/RelayProviderStore.ps1 tests/Unit/CcSwitchUsageImport.Tests.ps1 tests/Unit/RelayProviderStore.Tests.ps1
git commit -m "feat: convert CC Switch usage rules"
```

## Task 6: Import dialog and controller

**Files:**
- Create: `companion/UI/CcSwitchImport.xaml`
- Create: `companion/Private/CcSwitchImportView.ps1`
- Create: `companion/Private/CcSwitchImportController.ps1`
- Create: `tests/Unit/CcSwitchImportController.Tests.ps1`
- Create: `tests/Integration/CcSwitchImportComposition.Tests.ps1`

- [ ] **Step 1: Add failing view-contract and controller tests**

The XAML contract must require these named controls:

```powershell
$required = @(
    'SourceList','RefreshButton','StatusText','EndpointComboBox','ConversionText',
    'ImportModeComboBox','UpdateRadioButton','CopyRadioButton','ImportButton','CancelButton'
)
foreach ($name in $required) {
    $xaml.SelectSingleNode("//*[@x:Name='$name']", $manager) | Should -Not -BeNullOrEmpty
}
```

Controller tests use a fake view and discovery callback to prove:

- discovery runs only when the dialog opens or Refresh is clicked;
- blocked rows disable Import and never expose code;
- one endpoint is preselected, multiple endpoints require selection, and no endpoint requires user text entry in the relay editor;
- an existing link selects Update by default; an unlinked source selects Copy;
- `RequiresCustom` prompts through `ConfirmCustomImport` and only continues after explicit acceptance;
- cancel returns no draft and changes no files.

- [ ] **Step 2: Run tests to verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Unit\CcSwitchImportController.Tests.ps1,.\tests\Integration\CcSwitchImportComposition.Tests.ps1 -Output Detailed }"
```

Expected: fails because the view, controller, and XAML do not exist.

- [ ] **Step 3: Create the accessible import XAML**

Create a 780×560 dialog with a source list on the left and details on the right. The functional core is:

```xml
<Grid Margin="14">
  <Grid.RowDefinitions>
    <RowDefinition Height="Auto" />
    <RowDefinition Height="*" />
    <RowDefinition Height="Auto" />
  </Grid.RowDefinitions>
  <DockPanel>
    <Button x:Name="RefreshButton" Content="刷新" DockPanel.Dock="Right" AutomationProperties.Name="刷新 CC Switch 查询规则" />
    <TextBlock Text="从 CC Switch 导入余额查询规则" FontSize="18" FontWeight="SemiBold" />
  </DockPanel>
  <Grid Grid.Row="1" Margin="0,12,0,0">
    <Grid.ColumnDefinitions><ColumnDefinition Width="300" /><ColumnDefinition Width="14" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
    <ListBox x:Name="SourceList" DisplayMemberPath="DisplayName" AutomationProperties.Name="CC Switch 查询规则" />
    <StackPanel Grid.Column="2">
      <TextBlock Text="目标地址" />
      <ComboBox x:Name="EndpointComboBox" IsEditable="True" AutomationProperties.Name="导入目标地址" />
      <TextBlock x:Name="ConversionText" Margin="0,12,0,0" TextWrapping="Wrap" AutomationProperties.Name="转换状态" />
      <ComboBox x:Name="ImportModeComboBox" Margin="0,12,0,0" AutomationProperties.Name="导入模式">
        <ComboBoxItem Content="自动转换为 Generic" Tag="Auto" />
        <ComboBoxItem Content="作为 Custom 导入" Tag="Custom" />
      </ComboBox>
      <RadioButton x:Name="UpdateRadioButton" Content="更新现有查询规则" Margin="0,12,0,0" />
      <RadioButton x:Name="CopyRadioButton" Content="创建副本" />
    </StackPanel>
  </Grid>
  <DockPanel Grid.Row="2" Margin="0,12,0,0">
    <TextBlock x:Name="StatusText" VerticalAlignment="Center" TextWrapping="Wrap" />
    <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
      <Button x:Name="ImportButton" Content="导入到编辑器" IsDefault="True" />
      <Button x:Name="CancelButton" Content="取消" IsCancel="True" />
    </StackPanel>
  </DockPanel>
</Grid>
```

Apply the existing dark/light resource conventions, minimum dimensions, keyboard tab order, non-color status text, and automation names to all interactive controls.

- [ ] **Step 4: Implement the view adapter contract**

`New-CcSwitchImportView` returns exactly:

```text
ShowDialog
SetSources
GetSelection
SetSelectionDetails
SetBusy
SetStatus
ConfirmCustomImport
SetCallbacks
Dispose
```

The adapter stores only sanitized descriptors supplied by the controller. `SetSources` projects rows to `SourceProviderId`, `SourceAppType`, `DisplayName`, `ImportStatus`, and endpoint display values; it must not bind script code to any WPF property. `GetSelection` returns source IDs, selected endpoint, `Auto|Custom`, and `Update|Copy`.

- [ ] **Step 5: Implement controller orchestration**

Use this public signature:

```powershell
function New-CcSwitchImportController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$View,
        [Parameter(Mandatory)][scriptblock]$Discover,
        [Parameter(Mandatory)][scriptblock]$ReadLinks,
        [Parameter(Mandatory)][scriptblock]$ConvertCandidate
    )
```

Return `Show` and `Dispose`. `Show` accepts current providers, refreshes discovery, opens the modal, and returns either `$null` or `{ Draft, Link }`. Keep raw code only in controller state, never in view state. Resolve Update by matching `(SourceKind, SourceProviderId, SourceAppType)` in the link document; find the corresponding existing relay provider by `RelayProviderId`. On `RequiresCustom`, call `ConfirmCustomImport` and rerun conversion with `ImportMode Custom` only after acceptance.

- [ ] **Step 6: Run controller and composition tests**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Unit\CcSwitchImportController.Tests.ps1,.\tests\Integration\CcSwitchImportComposition.Tests.ps1 -Output Detailed }"
```

Expected: dialog contract, no-code-binding, update/copy, Custom confirmation, refresh, cancel, and dispose tests pass.

- [ ] **Step 7: Commit the import dialog**

```powershell
git add companion/UI/CcSwitchImport.xaml companion/Private/CcSwitchImportView.ps1 companion/Private/CcSwitchImportController.ps1 tests/Unit/CcSwitchImportController.Tests.ps1 tests/Integration/CcSwitchImportComposition.Tests.ps1
git commit -m "feat: add CC Switch import dialog"
```

## Task 7: Relay manager integration, test gate, and atomic save

**Files:**
- Modify: `companion/CodexQuotaMonitor.psm1`
- Modify: `companion/Private/InteractionController.ps1`
- Modify: `companion/Private/RelayManagerView.ps1`
- Modify: `companion/UI/RelayManager.xaml`
- Modify: `tests/Integration/RelayManagerComposition.Tests.ps1`
- Modify: `tests/Integration/MonitorRuntime.Tests.ps1`

- [ ] **Step 1: Add failing integration tests for import/save/delete**

Extend the fake relay manager view with `OnImport` and hidden `ImportLink`. Test this sequence:

```powershell
& $view.TestState.Callbacks.OnImport
$view.TestState.Draft.Name | Should -BeExactly 'wakaka'
$view.TestState.Draft.ImportLink.SourceProviderId | Should -BeExactly 'source-1'

(& $view.TestState.Callbacks.OnSave) | Should -BeFalse
$view.TestState.TestStates[-1].Message | Should -BeExactly 'Imported providers must pass the current test before saving.'

& $view.TestState.Callbacks.OnTest
(& $view.TestState.Callbacks.OnSave) | Should -BeTrue
$script:WriteMutations[-1].Kind | Should -BeExactly 'Upsert'

& $view.TestState.Callbacks.OnDelete $view.TestState.Draft.Id
$script:WriteMutations[-1].Kind | Should -BeExactly 'Remove'
```

Add a second test that changes `BaseUrl` after a successful test and proves Save is blocked until retested. Add runtime composition assertions that discovery uses `$paths.RelayHost`, the default CC Switch database path, and `$paths.RelayImportLinks` without reading provider credentials.

- [ ] **Step 2: Run integration tests to verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Integration\RelayManagerComposition.Tests.ps1,.\tests\Integration\MonitorRuntime.Tests.ps1 -Output Detailed }"
```

Expected: fails because `OnImport`, import metadata, and transactional callbacks are absent.

- [ ] **Step 3: Add the manager import button and hidden metadata**

Add `ImportButton` below the provider list controls:

```xml
<Button x:Name="ImportButton"
        Content="从 CC Switch 导入"
        AutomationProperties.Name="从 CC Switch 导入余额查询规则" />
```

Extend the relay manager view contract:

- include `ImportButton` in named controls, event attachment, and disposal;
- extend `SetCallbacks` with `OnImport`;
- store `ImportLink` in view state when `SetDraft` is called;
- include `ImportLink` in `ReadDraft` without placing it in a text control;
- clear it on Add and Duplicate.

- [ ] **Step 4: Add stable imported-draft test fingerprints**

Add to `CcSwitchUsageImport.ps1`:

```powershell
function Get-RelayImportedDraftTestFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Draft, [Parameter(Mandatory)][object]$Secrets)
    $material = [ordered]@{
        ProviderKind = [string]$Draft.ProviderKind
        BaseUrl = [string]$Draft.BaseUrl
        RequestDefinition = $Draft.RequestDefinition
        ExtractorScript = [string]$Draft.ExtractorScript
        TimeoutSeconds = [int]$Draft.TimeoutSeconds
        ApiKey = [string]$Secrets.ApiKey
        AccessToken = [string]$Secrets.AccessToken
        UserId = [string]$Secrets.UserId
    } | ConvertTo-Json -Depth 12 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($material)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
    finally { [Array]::Clear($bytes, 0, $bytes.Length); $material = $null }
}
```

In `New-RelayManagerController`, replace `TestedDraftId` with `TestedDraftFingerprint`. On successful test of an imported draft, compute the fingerprint from the tested draft and resolved secrets. Before saving an imported draft, resolve the same secrets and require an exact fingerprint match. Clear it on Add, Edit, Duplicate, Import, failed test, and Cancel.

- [ ] **Step 5: Route save/delete through link mutations**

Change the controller constructor to require:

```powershell
[Parameter(Mandatory)][scriptblock]$WriteRelayState,
[Parameter(Mandatory)][scriptblock]$ImportProvider
```

The import callback calls `& $ImportProvider $state.Providers`; if a result is returned, attach `result.Link` as `Draft.ImportLink`, clear trust/test state as required, and send the draft to the editor. Save uses `New-RelayImportLinkMutation -Kind Upsert -Link $draft.ImportLink` for imported drafts and `Kind None` otherwise. Delete always sends `Kind Remove -ProviderId $ProviderId`. Call `WriteRelayState` before mutating runtime state.

- [ ] **Step 6: Compose importer and transaction in the runtime**

Load new private files before `InteractionController.ps1`:

```powershell
'CcSwitchUsageImport.ps1'
'RelayImportLinkStore.ps1'
'CcSwitchImportView.ps1'
'CcSwitchImportController.ps1'
```

Add overridable functions for discovery, link reads/writes, transaction writes, import view, and import controller. In desktop composition:

```powershell
$ccSwitchImportView = & $functions.NewCcSwitchImportView
$ccSwitchImportController = & $functions.NewCcSwitchImportController `
    -View $ccSwitchImportView `
    -Discover {
        & $functions.DiscoverCcSwitch -ExecutablePath $paths.RelayHost `
            -DatabasePath (Get-DefaultCcSwitchDatabasePath)
    } `
    -ReadLinks { & $functions.ReadRelayImportLinks -Path $paths.RelayImportLinks } `
    -ConvertCandidate ${function:ConvertTo-CcSwitchRelayImportCandidate}

$writeRelayStateAction = {
    param($Document, $Mutation)
    & $functions.WriteRelayImportTransaction -ProviderPath $paths.RelayProviders `
        -LinkPath $paths.RelayImportLinks -ProviderDocument $Document -Mutation $Mutation
}.GetNewClosure()

$importProviderAction = {
    param($Providers)
    & $ccSwitchImportController.Show -Providers $Providers
}.GetNewClosure()
```

Pass both actions to `New-RelayManagerController`; dispose the import controller and view in normal and exceptional shutdown paths.

- [ ] **Step 7: Run manager and runtime tests**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Integration\RelayManagerComposition.Tests.ps1,.\tests\Integration\MonitorRuntime.Tests.ps1 -Output Detailed }"
```

Expected: import opens, untested/modified drafts cannot save, successful tests upsert links, deletes remove links, and all objects dispose cleanly.

- [ ] **Step 8: Commit end-to-end UI wiring**

```powershell
git add companion/CodexQuotaMonitor.psm1 companion/Private/InteractionController.ps1 companion/Private/RelayManagerView.ps1 companion/UI/RelayManager.xaml companion/Private/CcSwitchUsageImport.ps1 tests/Integration/RelayManagerComposition.Tests.ps1 tests/Integration/MonitorRuntime.Tests.ps1
git commit -m "feat: wire CC Switch imports into relay manager"
```

## Task 8: Preserve and present precise runtime errors

**Files:**
- Modify: `companion/CodexQuotaMonitor.psm1`
- Modify: `companion/Private/RelayState.ps1`
- Modify: `companion/Private/RelayScheduler.ps1`
- Modify: `companion/Private/RelayPresentation.ps1`
- Modify: `tests/Unit/RelayState.Tests.ps1`
- Modify: `tests/Unit/RelayScheduler.Tests.ps1`
- Modify: `tests/Unit/RelayPresentation.Tests.ps1`
- Modify: `tests/Integration/RelayRuntime.Tests.ps1`

- [ ] **Step 1: Add failing category-preservation and presentation tests**

Add a table that requires these public messages:

```powershell
It 'shows the precise sanitized failure reason' -ForEach @(
    @{ Category='EndpointNotFound'; Expected='余额接口不存在' }
    @{ Category='InvalidJson'; Expected='返回内容不是 JSON' }
    @{ Category='ExtractorExecution'; Expected='返回内容无法解析' }
    @{ Category='ResultValidation'; Expected='余额字段不符合要求' }
    @{ Category='RateLimit'; Expected='查询频率受限' }
    @{ Category='DestinationTrustRequired'; Expected='需要确认目标地址' }
) {
    $provider = [pscustomobject]@{ Id='relay'; Name='Relay' }
    $state = New-TestRelayPresentationState -Status 'Unavailable' -Results @() -LastSuccessAt $null
    $state.LastErrorCategory = $Category
    $row = @(ConvertTo-RelayPresentationRow -Provider $provider -State $state)[0]
    $row.SecondaryText | Should -BeExactly $Expected
}
```

Add a runtime test proving HTTP 404 becomes state category `EndpointNotFound`, 429 becomes `RateLimit`, `ScriptSyntax` remains `ScriptSyntax`, and `ExtractorExecution` remains `ExtractorExecution` rather than all becoming `ResultValidation`.

- [ ] **Step 2: Run tests to verify current category collapse**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Unit\RelayState.Tests.ps1,.\tests\Unit\RelayScheduler.Tests.ps1,.\tests\Unit\RelayPresentation.Tests.ps1,.\tests\Integration\RelayRuntime.Tests.ps1 -Output Detailed }"
```

Expected: new tests fail because runtime currently converts every invalid-script policy to `ResultValidation` and presentation ignores `LastErrorCategory`.

- [ ] **Step 3: Preserve precise state categories**

Replace runtime state-category derivation with:

```powershell
$stateCategory = if ($category -eq 'HttpStatus' -and [int]$httpStatus -eq 404) {
    'EndpointNotFound'
}
elseif ($category -eq 'HttpStatus' -and [int]$httpStatus -eq 429) {
    'RateLimit'
}
elseif ($policy -eq 'Authentication') {
    'Authentication'
}
elseif ($policy -eq 'TrustRequired') {
    'DestinationTrustRequired'
}
else {
    $category
}
```

Add `EndpointNotFound` to the scheduler/state non-retryable configuration categories and `RateLimit` to retryable categories. Preserve last-good results as stale for every failure; only pause automatic scheduling for authentication, trust, and non-retryable configuration/script failures.

- [ ] **Step 4: Present messages by last error category**

Change `Get-RelayStatusSecondaryText` to accept `Status` and `ErrorCategory`:

```powershell
function Get-RelayStatusSecondaryText {
    param([Parameter(Mandatory)][string]$Status, [AllowNull()][string]$ErrorCategory)
    switch ($ErrorCategory) {
        'EndpointNotFound' { return '余额接口不存在' }
        'InvalidJson' { return '返回内容不是 JSON' }
        'ExtractorExecution' { return '返回内容无法解析' }
        'ResultValidation' { return '余额字段不符合要求' }
        'RateLimit' { return '查询频率受限' }
        'DestinationTrustRequired' { return '需要确认目标地址' }
        'Authentication' { return '需要重新验证凭据' }
        'ScriptSyntax' { return '查询脚本语法无效' }
        'RequestValidation' { return '查询请求配置无效' }
    }
    switch ($Status) {
        'Starting' { return '等待首次查询' }
        'AuthRequired' { return '需要重新验证凭据' }
        'InvalidScript' { return '查询规则无效' }
        'Unavailable' { return '暂无可用数据' }
        'Disabled' { return '已停用' }
        default { return '' }
    }
}
```

Pass `State.LastErrorCategory` from `ConvertTo-RelayPresentationRow` for status rows and stale result rows.

- [ ] **Step 5: Run error-model tests**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Unit\RelayState.Tests.ps1,.\tests\Unit\RelayScheduler.Tests.ps1,.\tests\Unit\RelayPresentation.Tests.ps1,.\tests\Integration\RelayRuntime.Tests.ps1 -Output Detailed }"
```

Expected: precise state category and Chinese presentation tests pass; existing retry/stale tests remain green.

- [ ] **Step 6: Commit precise errors**

```powershell
git add companion/CodexQuotaMonitor.psm1 companion/Private/RelayState.ps1 companion/Private/RelayScheduler.ps1 companion/Private/RelayPresentation.ps1 tests/Unit/RelayState.Tests.ps1 tests/Unit/RelayScheduler.Tests.ps1 tests/Unit/RelayPresentation.Tests.ps1 tests/Integration/RelayRuntime.Tests.ps1
git commit -m "fix: show precise relay query failures"
```

## Task 9: Packaging, documentation, and full verification

**Files:**
- Modify: `companion/ThirdPartyNotices.txt`
- Modify: `README.md`
- Modify: `docs/relay-provider-migration.md`
- Modify: `tests/Integration/PackagedRelayHost.Tests.ps1`
- Modify: `tests/Unit/Documentation.Tests.ps1`
- Modify: `tests/Integration/Installation.Tests.ps1`
- Modify: `tests/Integration/CcSwitchImportComposition.Tests.ps1`
- Modify: `companion/Bin/relay-quota-host.exe`
- Modify: `companion/Bin/relay-quota-host.sha256`

- [ ] **Step 1: Add failing documentation, notice, and installed-layout assertions**

Require README/migration docs to mention `从 CC Switch 导入`, read-only database access, no `settings_config`/credential import, Generic-first conversion, explicit Custom fallback, test-before-save, source-link independence, and exact error categories. Extend packaged-host notices:

```powershell
foreach ($dependency in @(
    'QuickJS','rquickjs','reqwest','serde','rustls','url',
    'SQLite','rusqlite','regex','zeroize'
)) {
    $notices | Should -Match ([regex]::Escape($dependency))
}
```

Extend installed-layout tests to require `UI\CcSwitchImport.xaml` and all new private modules. Add a packaged sidecar test that invokes `--inspect-cc-switch` against a temporary synthetic database and verifies a sanitized Ready descriptor.

- [ ] **Step 2: Run tests to verify docs/package are incomplete**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Unit\Documentation.Tests.ps1,.\tests\Integration\PackagedRelayHost.Tests.ps1,.\tests\Integration\Installation.Tests.ps1 -Output Detailed }"
```

Expected: fails on missing documentation text, dependency notices, new installed files, and the old packaged binary.

- [ ] **Step 3: Update notices and user documentation**

Document the exact workflow:

```text
管理中转站 → 从 CC Switch 导入 → 选择查询规则 → 检查目标地址
→ 在监视器中重新输入 API Key → 测试 → 保存并启用
```

State explicitly that the importer reads only approved usage-script JSON paths and public endpoint rows, does not select `settings_config` or `usage_script.apiKey`, does not probe guessed endpoints, and cannot query a provider that exposes no usable balance API. Add source/license references for SQLite, rusqlite, regex, and zeroize to `ThirdPartyNotices.txt`.

- [ ] **Step 4: Build and package the updated sidecar**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\build\Build-RelayQuotaHost.ps1
pwsh -NoLogo -NoProfile -NonInteractive -File .\build\Verify-PackagedRelayHost.ps1
```

Expected: release build succeeds, the packaged Windows x64 executable is replaced, SHA-256 manifest matches, and self-test succeeds.

- [ ] **Step 5: Run focused package and documentation tests**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Command "& { . .\build\Restore-TestDependencies.ps1; Invoke-Pester -Path .\tests\Unit\Documentation.Tests.ps1,.\tests\Integration\PackagedRelayHost.Tests.ps1,.\tests\Integration\Installation.Tests.ps1,.\tests\Integration\CcSwitchImportComposition.Tests.ps1 -Output Detailed }"
```

Expected: documentation, notices, installed layout, packaged inspector, and sanitized sentinel tests pass.

- [ ] **Step 6: Run complete Rust validation**

```powershell
cargo fmt --manifest-path .\sidecar\relay-quota-host\Cargo.toml --check
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --locked
```

Expected: formatting check passes and every Rust unit/integration test passes.

- [ ] **Step 7: Run complete PowerShell validation**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All
```

Expected: every Pester unit and integration test passes with zero failed tests.

- [ ] **Step 8: Run repository hygiene and credential-sentinel checks**

```powershell
git diff --check
rg -n -S "FORBIDDEN_META_SECRET_78431|FORBIDDEN_SETTINGS_SECRET_91357" companion outputs
git status --short
```

Expected: `git diff --check` is clean; no credential sentinel appears in runtime or packaged files; status contains only the pre-existing untracked `.superpowers/` directory after all intended commits.

- [ ] **Step 9: Commit packaging and documentation**

```powershell
git add README.md docs/relay-provider-migration.md companion/ThirdPartyNotices.txt companion/Bin/relay-quota-host.exe companion/Bin/relay-quota-host.sha256 tests/Unit/Documentation.Tests.ps1 tests/Integration/PackagedRelayHost.Tests.ps1 tests/Integration/Installation.Tests.ps1 tests/Integration/CcSwitchImportComposition.Tests.ps1
git commit -m "docs: document CC Switch usage imports"
```

- [ ] **Step 10: Perform optional live Wakaka acceptance only with explicit authorization**

Use the installed UI to import the local Wakaka rule, re-enter the API key through the password field, approve `https://api.wkkapi.com:443`, test `GET /v1/usage`, and confirm one valid USD result. Do not automate credential extraction from CC Switch. If live authorization is not provided during implementation, report this acceptance item as not run rather than as a failure of synthetic verification.

## Completion gate

Before claiming implementation complete:

1. Confirm every task commit exists and `git diff --check` is clean.
2. Confirm full locked Rust tests and full Pester `All` tests passed in the current checkout.
3. Confirm the packaged executable hash matches and the installed-layout tests include the importer files.
4. Confirm no credential sentinel appears outside test fixture source.
5. Confirm no code path selects `providers.settings_config`, complete `providers.meta`, `usage_script.apiKey`, request logs, usage rollups, or cached balances.
6. Confirm imported drafts cannot save before a matching successful test.
7. Confirm `EndpointNotFound`, `InvalidJson`, `ExtractorExecution`, `ResultValidation`, and `RateLimit` remain distinct through runtime state and presentation.
8. Preserve the pre-existing `.superpowers/` working-tree content and do not merge or push unless separately requested.
