# Relay Script Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a stateless Windows x64 sidecar that executes the supported CC Switch usage-script contract in QuickJS, performs bounded host-side HTTP, and returns normalized non-secret JSONL results.

**Architecture:** Split the sidecar into protocol types, QuickJS evaluation, destination policy, and HTTP modules. Every command receives a fresh QuickJS runtime; JavaScript can describe a request and extract a result but receives no direct filesystem, process, environment, module, timer, or network capability.

**Tech Stack:** Rust stable MSVC, rquickjs 0.8.1, reqwest 0.12.28 with rustls and blocking client, serde 1.0.228, serde_json 1.0.149, url 2.5.8, Rust unit/integration tests.

---

## Task 0: Prepare the build-only Rust toolchain

**Files:**
- Verify only: `sidecar/relay-quota-host/Cargo.toml`

- [x] **Step 1: Confirm the branch and baseline**

Run:

```powershell
git branch --show-current
git status --short
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All -CI
```

Expected: branch is `feature/relay-quota-monitor`, status is empty, and all 355 baseline Pester tests pass.

- [x] **Step 2: Install build tools on D: only when the probes fail**

Run the probes first:

```powershell
Get-Command cargo.exe -ErrorAction SilentlyContinue
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path -LiteralPath $vswhere) {
    & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
```

If Cargo is absent, install rustup with build state on D::

```powershell
$rustRoot = 'D:\Developer\Rust'
[IO.Directory]::CreateDirectory($rustRoot) | Out-Null
$rustupExe = Join-Path $rustRoot 'rustup-init.exe'
Invoke-WebRequest -UseBasicParsing -Uri 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' -OutFile $rustupExe
$env:RUSTUP_HOME = Join-Path $rustRoot 'rustup'
$env:CARGO_HOME = Join-Path $rustRoot 'cargo'
& $rustupExe -y --profile minimal --default-toolchain stable --default-host x86_64-pc-windows-msvc
$env:Path = "$env:CARGO_HOME\bin;$env:Path"
cargo --version
rustc --version
```

If the Visual C++ workload is absent, install it on D::

```powershell
winget install --exact --id Microsoft.VisualStudio.2022.BuildTools --location 'D:\Microsoft Visual Studio\2022\BuildTools' --override '--wait --quiet --norestart --installPath "D:\Microsoft Visual Studio\2022\BuildTools" --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
```

Expected: `cargo --version` and the Visual C++ installation probe both succeed. Rust remains a developer-only dependency.

## Task 1: Lock the crate and JSONL protocol

**Files:**
- Create: `sidecar/relay-quota-host/Cargo.toml`
- Create: `sidecar/relay-quota-host/src/protocol.rs`
- Create: `sidecar/relay-quota-host/src/lib.rs`
- Create: `sidecar/relay-quota-host/tests/protocol_contract.rs`
- Create by Cargo: `sidecar/relay-quota-host/Cargo.lock`

- [x] **Step 1: Write the failing protocol serialization test**

Create `tests/protocol_contract.rs` with the exact public boundary:

```rust
use relay_quota_host::protocol::{HostResponse, UsageResult};

#[test]
fn success_response_has_stable_camel_case_shape() {
    let response = HostResponse::success(
        "query-1",
        vec![UsageResult {
            is_valid: true,
            invalid_message: None,
            remaining: Some(18.42),
            unit: Some("USD".into()),
            plan_name: None,
            total: None,
            used: None,
            extra: None,
        }],
        200,
        "api.wkkapi.com",
        84,
    );
    let value = serde_json::to_value(response).unwrap();
    assert_eq!(value["id"], "query-1");
    assert_eq!(value["ok"], true);
    assert_eq!(value["results"][0]["remaining"], 18.42);
    assert_eq!(value["meta"]["destinationHost"], "api.wkkapi.com");
    assert!(value.get("error").is_none());
}
```

- [x] **Step 2: Run the test and verify the crate is absent**

Run:

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test protocol_contract
```

Expected: FAIL because `Cargo.toml` or `relay_quota_host::protocol` does not exist.

- [x] **Step 3: Add the exact crate manifest**

Create `Cargo.toml`:

```toml
[package]
name = "relay-quota-host"
version = "0.1.0"
edition = "2021"
license = "MIT"
publish = false

[lib]
name = "relay_quota_host"
path = "src/lib.rs"

[[bin]]
name = "relay-quota-host"
path = "src/main.rs"

[dependencies]
reqwest = { version = "=0.12.28", default-features = false, features = ["blocking", "json", "rustls-tls"] }
rquickjs = { version = "=0.8.1", features = ["array-buffer", "classes"] }
serde = { version = "=1.0.228", features = ["derive"] }
serde_json = "=1.0.149"
url = "=2.5.8"
```

Create `src/lib.rs`:

```rust
pub mod destination;
pub mod http_client;
pub mod protocol;
pub mod script;
```

Run `cargo generate-lockfile --manifest-path .\sidecar\relay-quota-host\Cargo.toml` and commit `Cargo.lock`.

- [x] **Step 4: Implement the protocol types without secret-bearing Debug output**

`protocol.rs` defines these exact types:

```rust
use serde::{Deserialize, Serialize};

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QueryCommand {
    pub id: String,
    pub operation: Operation,
    pub script: String,
    pub template_type: TemplateType,
    pub base_url: String,
    pub secrets: SecretSet,
    pub timeout_ms: u64,
    pub trusted_destination: Option<String>,
}

#[derive(Clone, Copy, Deserialize, PartialEq, Eq)]
pub enum TemplateType { Wakaka, General, NewApi, Custom }

#[derive(Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Operation { Query }

#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SecretSet {
    pub api_key: String,
    pub access_token: String,
    pub user_id: String,
}

#[derive(Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageResult {
    pub is_valid: bool,
    pub invalid_message: Option<String>,
    pub remaining: Option<f64>,
    pub unit: Option<String>,
    pub plan_name: Option<String>,
    pub total: Option<f64>,
    pub used: Option<f64>,
    pub extra: Option<String>,
}
```

Implement `HostResponse::success` and `HostResponse::failure` as an internally tagged untagged enum so successful JSON contains `results` and `meta`, failed JSON contains `error`, and neither branch serializes the absent branch.

- [x] **Step 5: Run and commit the protocol contract**

Run:

```powershell
cargo fmt --manifest-path .\sidecar\relay-quota-host\Cargo.toml -- --check
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test protocol_contract --locked
```

Expected: PASS.

Commit:

```powershell
git add sidecar/relay-quota-host
git commit -m "feat: define relay host protocol"
```

## Task 2: Evaluate request objects in an isolated QuickJS runtime

**Files:**
- Modify: `sidecar/relay-quota-host/src/script.rs`
- Create: `sidecar/relay-quota-host/tests/request_script.rs`

- [x] **Step 1: Write failing request and sandbox tests**

```rust
use relay_quota_host::protocol::SecretSet;
use relay_quota_host::script::evaluate_request;

#[test]
fn replaces_only_the_four_supported_tokens_and_serializes_request() {
    let request = evaluate_request(
        "({request:{url:'{{baseUrl}}/v1/usage',method:'GET',headers:{Authorization:'Bearer {{apiKey}}','X-User':'{{userId}}'},body:'{{accessToken}}'}})",
        "https://api.wkkapi.com",
        &SecretSet { api_key: "key-a".into(), access_token: "access-a".into(), user_id: "42".into() },
    ).unwrap();
    assert_eq!(request.url, "https://api.wkkapi.com/v1/usage");
    assert_eq!(request.method, "GET");
    assert_eq!(request.headers["Authorization"], "Bearer key-a");
    assert_eq!(request.headers["X-User"], "42");
    assert_eq!(request.body.as_deref(), Some("access-a"));
}

#[test]
fn direct_host_capabilities_are_absent() {
    let request = evaluate_request(
        "({request:{url:'https://example.com',method:'GET',headers:{},body:[typeof process,typeof require,typeof fetch,typeof setTimeout].join(',')}})",
        "https://example.com",
        &SecretSet::default(),
    ).unwrap();
    assert_eq!(request.body.as_deref(), Some("undefined,undefined,undefined,undefined"));
}
```

- [x] **Step 2: Run and verify the missing implementation failure**

Run:

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test request_script --locked
```

Expected: FAIL because `script::evaluate_request` is missing.

- [x] **Step 3: Implement bounded token replacement and the request shape**

Add:

```rust
#[derive(Clone, PartialEq)]
pub struct ScriptRequest {
    pub url: String,
    pub method: String,
    pub headers: std::collections::BTreeMap<String, String>,
    pub body: Option<String>,
}

pub fn replace_tokens(script: &str, base_url: &str, secrets: &SecretSet) -> String {
    script
        .replace("{{apiKey}}", &secrets.api_key)
        .replace("{{baseUrl}}", base_url.trim_end_matches('/'))
        .replace("{{accessToken}}", &secrets.access_token)
        .replace("{{userId}}", &secrets.user_id)
}
```

`evaluate_request` must create `rquickjs::Runtime::new()`, set a 16 MiB memory limit and interrupt deadline, create a fresh `Context`, evaluate `JSON.stringify((SCRIPT).request)`, parse only the resulting JSON into a private `RawRequest`, require nonempty `url` and `method`, require every header value and body to be a string, and return `ScriptRequest`. It must reject scripts over 256 KiB and serialized requests over 64 KiB.

- [x] **Step 4: Add syntax, type, size, and global-absence cases**

Extend the test with table cases for malformed JavaScript, missing request, array-valued header, object body, script size `262145`, and request JSON size `65537`. Each must return one of `ScriptSyntax`, `RequestValidation`, or `RequestTooLarge` without containing the API key sentinel.

Add an ES2020 case using optional chaining and nullish coalescing, an arbitrary valid `POST` method case, and a memory-limit case that attempts `new ArrayBuffer(32 * 1024 * 1024)` and returns `ScriptMemory` without terminating the host process.

- [x] **Step 5: Run and commit QuickJS request evaluation**

```powershell
cargo fmt --manifest-path .\sidecar\relay-quota-host\Cargo.toml -- --check
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test request_script --locked
git add sidecar/relay-quota-host/src/script.rs sidecar/relay-quota-host/tests/request_script.rs
git commit -m "feat: evaluate relay request scripts safely"
```

Expected: all request-script tests pass.

## Task 3: Enforce destination trust and bounded host-side HTTP

**Files:**
- Modify: `sidecar/relay-quota-host/src/destination.rs`
- Modify: `sidecar/relay-quota-host/src/http_client.rs`
- Create: `sidecar/relay-quota-host/tests/destination_policy.rs`
- Create: `sidecar/relay-quota-host/tests/http_client.rs`

- [x] **Step 1: Write failing destination-policy tests**

```rust
use relay_quota_host::destination::validate_destination;
use relay_quota_host::protocol::TemplateType;

#[test]
fn built_in_requires_https_and_same_effective_origin() {
    assert!(validate_destination(TemplateType::Wakaka, "https://api.wkkapi.com", "https://api.wkkapi.com/v1/usage", None).is_ok());
    assert!(validate_destination(TemplateType::Wakaka, "https://api.wkkapi.com", "http://api.wkkapi.com/v1/usage", None).is_err());
    assert!(validate_destination(TemplateType::General, "https://a.example", "https://b.example/user/balance", None).is_err());
}

#[test]
fn loopback_http_and_explicit_custom_fingerprint_are_supported() {
    assert!(validate_destination(TemplateType::General, "http://127.0.0.1:18080", "http://127.0.0.1:18080/user/balance", None).is_ok());
    assert!(validate_destination(TemplateType::Custom, "https://a.example", "http://relay.example:8080/usage", Some("http://relay.example:8080")).is_ok());
    assert!(validate_destination(TemplateType::Custom, "https://a.example", "http://other.example/usage", Some("http://relay.example:8080")).is_err());
}
```

- [x] **Step 2: Run and verify failure**

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test destination_policy --locked
```

Expected: FAIL because destination validation is not implemented.

- [x] **Step 3: Implement canonical effective origins**

`destination.rs` must parse with `url::Url`, reject embedded credentials, derive lowercase `scheme://host:effective-port`, treat only `localhost`, `127.0.0.0/8`, and `::1` as loopback, and return:

```rust
pub struct ValidatedDestination {
    pub url: url::Url,
    pub host: String,
    pub fingerprint: String,
}

pub fn validate_destination(
    template_type: TemplateType,
    base_url: &str,
    request_url: &str,
    trusted_destination: Option<&str>,
) -> Result<ValidatedDestination, HostError>;
```

Built-ins require HTTPS except loopback and exact effective-origin equality. Custom requires the computed fingerprint to equal `trusted_destination` byte-for-byte. When Custom has no matching fingerprint, return `DestinationTrustRequired` with only canonical `destinationHost` and `destinationFingerprint`; do not create an HTTP client or send a request in that path.

- [x] **Step 4: Write the failing local HTTP integration test**

Use `std::net::TcpListener` on `127.0.0.1:0` to return a JSON body and assert that `execute_request` sends the method/header/body, reports status, enforces timeout, rejects a response over 1 MiB, and maps non-2xx to `HttpStatus` with parsed integer `Retry-After`.

- [x] **Step 5: Implement the bounded reqwest client**

Use one per-command blocking client:

```rust
let client = reqwest::blocking::Client::builder()
    .connect_timeout(Duration::from_millis(timeout_ms))
    .timeout(Duration::from_millis(timeout_ms))
    .redirect(reqwest::redirect::Policy::none())
    .build()?;
```

Parse `method` through `reqwest::Method::from_bytes`, add only validated string headers, send an optional string body, read at most `1_048_577` bytes, reject redirects rather than silently crossing origins, require 2xx, and deserialize JSON only after the size/status checks.

- [x] **Step 6: Run and commit destination plus HTTP**

```powershell
cargo fmt --manifest-path .\sidecar\relay-quota-host\Cargo.toml -- --check
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test destination_policy --test http_client --locked
git add sidecar/relay-quota-host/src/destination.rs sidecar/relay-quota-host/src/http_client.rs sidecar/relay-quota-host/tests/destination_policy.rs sidecar/relay-quota-host/tests/http_client.rs
git commit -m "feat: enforce relay destination and http limits"
```

Expected: both integration test binaries pass.

## Task 4: Run extractors and normalize single or multi-plan results

**Files:**
- Modify: `sidecar/relay-quota-host/src/script.rs`
- Create: `sidecar/relay-quota-host/tests/extractor_contract.rs`
- Create: `sidecar/relay-quota-host/tests/fixtures/wakaka-wallet.json`
- Create: `sidecar/relay-quota-host/tests/fixtures/wakaka-subscription.json`

- [x] **Step 1: Write failing extractor tests**

```rust
use relay_quota_host::script::evaluate_extractor;

#[test]
fn accepts_one_result_and_preserves_explicit_zero() {
    let results = evaluate_extractor(
        "({request:{url:'https://example.com'},extractor:r=>({isValid:true,remaining:r.balance,unit:'USD'})})",
        &serde_json::json!({"balance": 0.0}),
    ).unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].remaining, Some(0.0));
}

#[test]
fn accepts_nonempty_arrays_and_rejects_coercive_fields() {
    let results = evaluate_extractor(
        "({request:{url:'https://example.com'},extractor:r=>r.plans.map(p=>({isValid:true,planName:p.name,remaining:p.remaining,total:p.total,unit:p.unit}))})",
        &serde_json::json!({"plans":[{"name":"Weekly","remaining":50,"total":100,"unit":"requests"}]}),
    ).unwrap();
    assert_eq!(results[0].plan_name.as_deref(), Some("Weekly"));
    assert!(evaluate_extractor("({extractor:r=>({isValid:'true',remaining:'5'})})", &serde_json::json!({})).is_err());
    assert!(evaluate_extractor("({extractor:r=>([])})", &serde_json::json!({})).is_err());
}
```

- [x] **Step 2: Run and verify failure**

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test extractor_contract --locked
```

Expected: FAIL because `evaluate_extractor` is missing.

- [x] **Step 3: Implement fresh-runtime extractor execution**

`evaluate_extractor(script, response)` must create a second fresh QuickJS runtime with the same limits, inject the response only through a JSON literal produced by `serde_json`, extract the `extractor` function, and invoke it detached with `response` as its only argument, matching CC Switch's `Function::call((response_js,))` behavior rather than binding `this` to the script object. It must enforce a 256 KiB serialized-result limit, accept one object or a nonempty array, and validate exact field types. It must reject non-finite numeric fields after conversion and cap each string field at 4096 UTF-8 bytes.

Use this canonical defaulting rule:

```rust
let is_valid = raw.is_valid.unwrap_or(true);
let result = UsageResult {
    is_valid,
    invalid_message: raw.invalid_message,
    remaining: finite(raw.remaining)?,
    unit: bounded(raw.unit)?,
    plan_name: bounded(raw.plan_name)?,
    total: finite(raw.total)?,
    used: finite(raw.used)?,
    extra: bounded(raw.extra)?,
};
```

- [x] **Step 4: Add Wakaka wallet and subscription fixtures**

The wallet fixture contains an explicit `balance` and the subscription fixture contains two quota plans. Tests load the fixtures, use the committed Wakaka preset script string, and assert normalized USD wallet and named percentage-bearing plan records. Add synthetic General `/user/balance` and New API `/api/user/self` extractor cases in the same test file. Fixture values are synthetic and contain no credential or captured production response.

- [x] **Step 5: Run and commit extractor compatibility**

```powershell
cargo fmt --manifest-path .\sidecar\relay-quota-host\Cargo.toml -- --check
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test extractor_contract --locked
git add sidecar/relay-quota-host/src/script.rs sidecar/relay-quota-host/tests/extractor_contract.rs sidecar/relay-quota-host/tests/fixtures
git commit -m "feat: normalize relay usage extractor results"
```

Expected: wallet, subscription, explicit-zero, multi-result, invalid-type, and empty-array cases pass.

## Task 5: Compose the stateless JSONL executable and sanitized failures

**Files:**
- Create: `sidecar/relay-quota-host/src/main.rs`
- Create: `sidecar/relay-quota-host/tests/jsonl_process.rs`

- [x] **Step 1: Write a failing process-level round-trip test**

Use `env!("CARGO_BIN_EXE_relay-quota-host")`, spawn with redirected stdin/stdout/stderr, write one command plus LF, close stdin, and assert one parseable response line with matching ID and no output on stderr. Add a malformed-input command and assert `Protocol` without echoing input.

- [x] **Step 2: Run and verify failure**

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --test jsonl_process --locked
```

Expected: FAIL because the binary entry point does not exist.

- [x] **Step 3: Implement the one-line command loop**

`main.rs` must implement the offline self-test and command loop:

```rust
use std::io::{BufRead, Write};

fn main() {
    if std::env::args().nth(1).as_deref() == Some("--self-test") {
        println!("relay-quota-host: ok");
        return;
    }
    let stdin = std::io::stdin();
    let mut stdout = std::io::BufWriter::new(std::io::stdout().lock());
    for line in stdin.lock().lines() {
        let response = relay_quota_host::handle_line(&line.unwrap_or_default());
        serde_json::to_writer(&mut stdout, &response).expect("stdout JSON serialization");
        stdout.write_all(b"\n").expect("stdout newline");
        stdout.flush().expect("stdout flush");
    }
}
```

`handle_line` rejects input over 512 KiB before deserialization, clamps `timeoutMs` to 2000-30000, measures duration, runs request evaluation → destination validation → HTTP → fresh extractor evaluation, and maps every internal error to one of these sanitized categories: `Protocol`, `ScriptSyntax`, `ScriptTimeout`, `ScriptMemory`, `RequestValidation`, `RequestTooLarge`, `DestinationValidation`, `DestinationTrustRequired`, `Dns`, `Connectivity`, `Tls`, `Timeout`, `HttpStatus`, `ResponseTooLarge`, `InvalidJson`, `ExtractorExecution`, `ResultValidation`, or `SidecarLifecycle`. Panic details and raw errors never cross stdout/stderr.

- [x] **Step 4: Add lifecycle and redaction tests**

Test two sequential commands to prove no shared JavaScript globals; close stdin to prove clean exit; send secret sentinels through script, headers, response, invalid JSON, and HTTP errors; assert the sentinel is absent from stdout and stderr. Test a QuickJS infinite loop and assert `ScriptTimeout` inside the 30-second host ceiling.

- [x] **Step 5: Run the complete sidecar suite**

```powershell
cargo fmt --manifest-path .\sidecar\relay-quota-host\Cargo.toml -- --check
cargo clippy --manifest-path .\sidecar\relay-quota-host\Cargo.toml --all-targets --locked -- -D warnings
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --locked
```

Expected: formatting, clippy, and every Rust test pass.

- [x] **Step 6: Commit the executable composition**

```powershell
git add sidecar/relay-quota-host/src/main.rs sidecar/relay-quota-host/tests/jsonl_process.rs sidecar/relay-quota-host/src/lib.rs
git commit -m "feat: compose relay quota host process"
git status --short
```

Expected: commit succeeds and status is empty.

## Task 6: Record standalone host verification

**Files:**
- Modify: `docs/superpowers/plans/2026-08-01-relay-script-host.md`

- [x] **Step 1: Build the release binary without packaging it yet**

```powershell
cargo build --manifest-path .\sidecar\relay-quota-host\Cargo.toml --release --locked
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = (Resolve-Path '.\sidecar\relay-quota-host\target\release\relay-quota-host.exe').Path
$start.ArgumentList.Add('--self-test')
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.CreateNoWindow = $true
$process = [Diagnostics.Process]::Start($start)
$output = $process.StandardOutput.ReadToEnd()
$process.WaitForExit()
```

Expected: release build succeeds, the redirected GUI-subsystem process exits 0, and `--self-test` emits one line `relay-quota-host: ok` without network access. Explicit redirection is required because PowerShell does not attach a pipeline to a Windows GUI-subsystem executable when it is invoked with the call operator.

- [x] **Step 2: Mark completed checkboxes and commit the plan record**

After recording the exact Rust test counts and release binary SHA-256 under this task, run:

```powershell
git add docs/superpowers/plans/2026-08-01-relay-script-host.md
git commit -m "docs: record relay host verification"
```

Expected: the standalone sidecar is committed as source plus lockfile, independently testable, and ready for the PowerShell adapter plan.

### Verification record

- Verified commit before this documentation update: `7478d45112a818294abb904bfa01e16137ad0a44`.
- `cargo fmt -- --check`: passed.
- `cargo clippy --all-targets --locked -- -D warnings`: passed.
- `cargo test --locked`: 129 passed, 0 failed, 0 ignored across 19 library, 7 destination, 24 extractor, 13 HTTP, 20 JSONL process, 5 protocol, 1 proxy, and 40 request-script tests.
- Release self-test: exit code 0, stdout exactly `relay-quota-host: ok\n`, stderr empty.
- Release binary size: 4,861,952 bytes.
- Release binary SHA-256: `1C2BAF844C63B69ACD770389FDC1724B0BB75E082F12E5A25EBE29FA8DA89A30`.
- Worker request and extractor responses use per-command AES-256-GCM authenticated IPC, so direct worker stdout never contains substituted credentials or normalized response fields.
- Credential matching at the public JSONL boundary applies to command-derived strings. Stable protocol keys, categories, and constant messages are not treated as credential echoes.
