# CC Switch Usage Script Import Design

## Summary

Add a read-only import workflow that discovers CC Switch providers with a configured balance/usage script, converts safe scripts into this monitor's existing Generic provider model, and offers an explicit Custom fallback when the request cannot be safely decomposed. The workflow never reads, copies, or imports CC Switch credentials. Users must enter credentials again, approve the destination origin, pass a live test, and explicitly save before an imported provider becomes active.

This feature gives the monitor the same practical extensibility that makes CC Switch appear broadly compatible with relay balances: known or user-supplied request scripts describe the provider-specific balance API. It does not claim that OpenAI-compatible model endpoints expose a universal balance protocol.

## Goals

- Import non-secret CC Switch balance-query rules from the local CC Switch database.
- Reuse the monitor's Generic request definition whenever the script can be fully and safely understood.
- Preserve a safe but non-decomposable script as an explicit Custom draft instead of losing behavior.
- Require new credential entry and destination trust inside the monitor.
- Support repeat imports, rule updates, and independent operation after CC Switch is closed or the source provider is deleted.
- Replace the broad "script or configuration invalid" experience with actionable import and runtime error categories.

## Non-goals

- Importing API keys, access tokens, user IDs, cookies, account identifiers, request history, or cached balances from CC Switch.
- Writing to, migrating, repairing, locking, or copying the CC Switch database.
- Automatically probing guessed balance endpoints with user credentials.
- Guaranteeing balance support for a provider that exposes no balance API or usable query script.
- Keeping an imported provider continuously synchronized with CC Switch.
- Executing an untrusted script before the user reviews the import result and approves the destination.

## User experience

### Entry point

Add a **从 CC Switch 导入** button to the relay manager. Selecting it opens a modal import view without changing the current relay draft.

### Discovery list

The dialog lists only CC Switch providers that have an enabled `usage_script` with JavaScript code. Each row shows:

- provider name;
- source application (`codex`, `claude`, or another supported CC Switch app type);
- public Base URL when it is available from `provider_endpoints`;
- template type;
- query path when static analysis can determine it;
- source refresh interval;
- conversion status: **可转换为 Generic**, **需要 Custom**, or **禁止导入**.

No credential value, header value after substitution, raw response, cached balance, or request history appears in the dialog.

### Import flow

1. The user selects one or more source rows.
2. The importer performs credential detection and script analysis without making an HTTP request.
3. A safely decomposed script becomes a Generic draft with a structured method, relative path, query map, header map, body, and extractor function.
4. A safe script that cannot be completely decomposed is offered as a Custom draft with a fixed review warning. Custom fallback is never silently enabled.
5. A script suspected of containing literal credentials is blocked and cannot be previewed or saved through this workflow.
6. The user confirms or enters the Base URL, enters credentials again in the monitor, and reviews the request path.
7. The existing destination-trust dialog shows only the canonical `scheme://host:port` before the first request.
8. A live test must return at least one valid normalized result before **保存并启用** is available.

For the confirmed local Wakaka case, the expected imported request is `GET /v1/usage` with `Authorization: Bearer {{apiKey}}`, followed by extraction of `balance` or `remaining` into one USD balance row.

### Repeat imports

When a source is already linked to a monitor provider, the dialog offers:

- **更新查询规则**: replace only the request definition or script and its source fingerprint;
- **创建副本**: create an unrelated new draft.

Updating rules preserves the monitor provider ID, display name, encrypted monitor credentials, interval, trusted origin when unchanged, cache association, and last-good balance. A changed origin clears destination trust and requires a new live test. If the source provider disappears, the imported monitor provider continues to work independently.

## Architecture

### Components

1. **CC Switch database inspector (Rust sidecar mode)**
   - Opens the database read-only.
   - Executes a fixed query with an explicit field whitelist.
   - Scans script code for suspected literal credentials inside the isolated process.
   - Returns sanitized source descriptors and script code only when the credential scan passes.
   - Does not share process state with live relay-query execution.

2. **Import analyzer (PowerShell)**
   - Validates source descriptors.
   - Reuses the existing legacy request/extractor analysis to build a Generic draft.
   - Produces an explicit Custom candidate when safe conversion is incomplete.

3. **Import link store (PowerShell)**
   - Stores non-secret source linkage separately from relay providers.
   - Detects repeat imports and source rule changes.
   - Does not change the current schema-2 relay provider document.

4. **Import dialog and relay manager integration (WPF)**
   - Displays discoverable sources and conversion outcomes.
   - Passes the selected draft into the existing editor.
   - Reuses existing credential entry, trust confirmation, test, and save behavior.

### Why the existing sidecar is extended

PowerShell does not have a guaranteed SQLite provider on supported Windows installations. The existing signed/hashed Rust sidecar is already packaged and verified with the monitor. A separate sidecar command mode can use a bundled SQLite implementation without loading third-party assemblies into the desktop process. Database inspection and network-query modes remain separate invocations so database parsing cannot retain relay credentials or live HTTP state.

## CC Switch database access

### Location and opening mode

The default database path is `%USERPROFILE%\.cc-switch\cc-switch.db`. A future path override may be added only as an explicit advanced setting; the initial feature uses the default path.

Open SQLite with read-only and URI flags and a short busy timeout. Do not use immutable mode because a running CC Switch instance can have committed data in its WAL. Do not create journals, backups, temporary database copies, or schema objects. A busy or incompatible database produces a sanitized error and leaves the current relay configuration unchanged.

### Query whitelist

The inspector may query only:

- `providers.id`;
- `providers.app_type`;
- `providers.name`;
- selected JSON paths under `providers.meta.usage_script`:
  - `enabled`;
  - `language`;
  - `code`;
  - `timeout`;
  - `templateType`;
  - `autoQueryInterval`;
- `provider_endpoints.provider_id`;
- `provider_endpoints.app_type`;
- `provider_endpoints.url`.

The inspector must use SQLite JSON extraction to select only approved `usage_script` properties. It must not select or deserialize the complete `meta` value. It must not query `providers.settings_config`, `usage_script.apiKey`, authentication tables or files, proxy request logs, stream-check logs, usage rollups, cached balances, or session logs. If the installed SQLite build cannot perform the required JSON extraction, discovery fails closed instead of reading the whole JSON value.

Multiple endpoint rows are returned as public endpoint candidates. If no endpoint exists, the import draft leaves Base URL empty and requires user input.

## Sanitized discovery protocol

For an allowed source, the sidecar discovery response contains a bounded array with these fields:

```text
sourceProviderId
sourceAppType
name
endpointCandidates[]
language
code
timeoutSeconds
templateType
autoQueryIntervalMinutes
importStatus
```

For a source blocked by credential detection, `code` is null and `importStatus` is `CredentialDetected`; no matching text crosses the sidecar boundary. Bounds apply before data reaches PowerShell: maximum provider count, string lengths, script bytes, endpoint count, and response bytes. Unknown fields, invalid UTF-8, unsupported database types, malformed JSON extraction results, and unexpected schema changes fail closed. Sidecar stderr and public errors never contain SQL rows, script text, database paths beyond the known default, or exception details.

## Credential detection

Credential detection occurs in the isolated Rust inspector before script text is returned to PowerShell, displayed, or saved. It rejects at least:

- literal `Authorization: Bearer <value>` content when `<value>` is not an approved placeholder or variable expression;
- known API-key prefixes followed by a high-confidence token body;
- non-empty literal assignments to `apiKey`, `accessToken`, `token`, `secret`, or equivalent credential fields;
- URLs containing user information or credential-like query parameters;
- script data that exceeds existing script limits or contains forbidden control characters.

The detector reports only `CredentialDetected`; it clears the script buffer after classification and never echoes the matching substring. Placeholder forms such as `{{apiKey}}`, `{{accessToken}}`, and runtime variables are allowed. Detection is a prevention layer, not a claim that arbitrary JavaScript can be proven secret-free.

## Conversion rules

### Generic conversion

The importer reuses the monitor's existing safe legacy-script analysis and canonicalization. Generic conversion succeeds only when the whole request is consumed:

- method is supported by the existing Generic contract (`GET`, `POST`, or `PUT`);
- target is Base URL plus a relative path;
- query, headers, and optional body can be represented without executing code;
- credential use maps only to approved placeholders;
- extractor is a bounded function expression compatible with the existing QuickJS contract;
- no unconsumed dynamic request behavior remains.

The resulting provider is passed through the same canonical provider validation as a manually created Generic provider.

### Custom fallback

If credential detection passes but complete Generic conversion is impossible, the importer creates an unsaved Custom candidate containing the original usage script and a fixed warning. The user must explicitly choose **以 Custom 导入**, inspect the destination, enter credentials, accept destination trust, and pass a live test. Unsupported language, unsafe target construction, unsupported side effects, or an incompatible CC Switch script contract blocks even Custom import.

Dynamic authorization retrieval, runtime-generated destinations, `eval`, filesystem/process access attempts, or other behavior outside the existing Custom sandbox never becomes an enabled provider merely because CC Switch stored it.

## Source linkage

Keep relay providers at schema 2. Store import provenance in a separate file:

```json
{
  "SchemaVersion": 1,
  "Links": [
    {
      "RelayProviderId": "monitor-provider-guid",
      "SourceKind": "CcSwitchUsageScript",
      "SourceProviderId": "cc-switch-provider-id",
      "SourceAppType": "codex",
      "ScriptFingerprint": "lowercase-sha256"
    }
  ]
}
```

The file contains no Base URL, script, credential, balance, or source database path. It uses the same canonical JSON, atomic replacement, corruption quarantine, and restrictive local-file behavior as other monitor data. A missing or corrupt link file disables update matching but does not invalidate relay providers.

Fingerprinting uses SHA-256 over a canonical tuple of language, code, timeout, template type, auto-query interval, and sorted public endpoint candidates. It is used only to identify changed rules.

## State changes and rollback

Discovery, analysis, and preview are side-effect free. Importing creates only an in-memory relay draft. Existing provider and link files are written only after a successful live test and an explicit save.

Saving a new import performs one logical transaction:

1. validate the canonical relay provider document and link document;
2. stage both files in their target directories;
3. atomically replace the provider file;
4. atomically replace the link file;
5. if the second replacement fails, restore the provider file from its immediately staged backup;
6. apply the provider set to the runtime only after both writes succeed.

Update and batch-import operations are per-provider. One failed source does not discard other successful drafts. Partial persistence is never presented as success.

## Error model

Import errors are distinct from relay runtime errors:

| Category | User-facing meaning |
|---|---|
| `CcSwitchNotFound` | CC Switch 数据库不存在。 |
| `CcSwitchDatabaseBusy` | CC Switch 数据库暂时忙，请稍后重试。 |
| `CcSwitchSchemaUnsupported` | 当前 CC Switch 数据结构暂不受支持。 |
| `NoUsageScript` | 该 provider 没有可导入的余额查询脚本。 |
| `CredentialDetected` | 脚本疑似包含明文凭据，已阻止导入。 |
| `UnsupportedLanguage` | 仅支持兼容的 JavaScript 查询规则。 |
| `UnsupportedScript` | 无法安全转换；仅在 Custom 沙箱兼容时允许手动继续。 |
| `ImportLinkInvalid` | 导入来源记录损坏；provider 本身仍可独立使用。 |

Live testing continues to use specific sanitized runtime categories:

- `DestinationTrustRequired` for first-use origin approval;
- `Authentication` for HTTP 401/403 or all-invalid authentication results;
- `EndpointNotFound` for HTTP 404;
- `RateLimit` for HTTP 429;
- `InvalidJson` for HTML or malformed JSON responses;
- `ExtractorExecution` for extractor failure;
- `ResultValidation` for an invalid normalized result;
- `Unavailable` for DNS, connectivity, TLS, timeout, sidecar, or server failures.

The relay presentation layer must not collapse these categories into a single "脚本或配置无效" message when a more precise public category is available. Last-good data remains visible and marked stale for retryable failures; only a successful normalized result can display a new balance or explicit zero.

## Security and privacy properties

- CC Switch remains the authority for its own database; the monitor never writes to it.
- The importer never selects `settings_config` or explicit usage-script credential fields. Script code is necessarily inspected inside the isolated sidecar; code suspected of containing a literal credential is blocked and never returned to the desktop process.
- Script text is not logged, written to health state, added to diagnostics, or included in errors.
- A detected credential is not shown in a preview and is never persisted.
- Monitor credentials continue to use DPAPI and are entered through monitor password fields.
- No HTTP request occurs during discovery or conversion.
- First network use requires canonical origin trust and a user-triggered test.
- Remote plain HTTP remains rejected under the existing destination policy.
- Imported scripts remain subject to existing time, memory, response-size, result-count, and output allowlist limits.

## Testing strategy

### Rust unit tests

- Open fixture databases read-only and prove no file or WAL mutation.
- List only providers with an enabled JavaScript usage script.
- Verify the fixed SQL never selects `settings_config`, complete `meta`, credential JSON paths, logs, rollups, or cached balances.
- Detect literal bearer tokens, known key shapes, literal credential assignments, URL credentials, control characters, and oversized scripts without returning or echoing matches.
- Permit approved placeholders and runtime variables.
- Handle multiple endpoints, missing endpoints, duplicate names, multiple app types, busy databases, malformed JSON, missing tables, incompatible schemas, and size limits.
- Confirm sanitized errors and bounded protocol output.

### PowerShell unit tests

- Reject a sidecar descriptor whose `importStatus` is not allowed or whose blocked `code` field is unexpectedly non-null.
- Convert Wakaka `GET /v1/usage`, General, and New API fixtures to canonical Generic providers.
- Fall back to Custom only when the original script is safe and sandbox-compatible.
- Preserve uncertain scripts byte-for-byte in an unsaved Custom draft.
- Validate canonical link documents, fingerprints, duplicate detection, update-versus-copy behavior, and corruption isolation.

### Integration tests

- Drive discovery through the packaged sidecar against temporary SQLite fixtures.
- Import Codex and Claude providers with the same display name but different source IDs.
- Prove the importer does not request HTTP during discovery or conversion.
- Test trust decline/accept and successful save.
- Verify updates preserve monitor credentials and cached balance while origin changes clear trust.
- Simulate failure between provider and link writes and verify rollback.
- Verify source deletion leaves the monitor provider operational.

### Runtime and UI tests

- Verify distinct messages for 401, 403, 404, 429, HTML, invalid JSON, timeout, extractor failure, and invalid results.
- Verify blocked scripts cannot reveal matched credential text through the UI, logs, health file, or sidecar diagnostics.
- Verify batch import isolates failures by row.
- Verify keyboard navigation, focus, disabled-state explanations, scaling, and light/dark theme rendering of the import dialog.

### Full acceptance

- Run all existing PowerShell and Rust suites plus new importer coverage.
- Run formatting and `git diff --check`.
- Build the sidecar and installer, install through the normal staged replacement path, and verify ordinary monitor health.
- Complete a synthetic end-to-end import from a temporary CC Switch database.
- With explicit user authorization, perform a live Wakaka acceptance showing one valid `/v1/usage` result without exposing the API key.
- Search installed data, cache, health, logs, test output, and staged artifacts for unique synthetic credential sentinels; expected matches are zero outside dedicated test fixtures.

## Acceptance criteria

1. A user can import a CC Switch Wakaka usage rule and obtain a valid balance after re-entering the API key and trusting the destination.
2. No explicit CC Switch credential field or cached balance is selected. Script code suspected of embedding a credential is confined to the isolated detector and is never returned, logged, or persisted.
3. Safely understood scripts become canonical Generic providers; uncertain safe scripts are offered as explicit Custom drafts without data loss.
4. Suspected literal credentials and incompatible scripts fail closed.
5. Repeat import can update rules or create a copy, and imported providers remain independent of CC Switch afterward.
6. Failure at any discovery, conversion, test, or persistence step leaves existing providers unchanged.
7. Users receive a specific, sanitized error category instead of a generic invalid-script label whenever the cause is known.
