# Relay Quota Monitor Extension Design

Date: 2026-08-01
Status: Conversation design approved; awaiting written-spec review

## 1. Goal

Extend the existing Windows `codex-quota-monitor` companion so it can monitor two independent data sources at the same time:

1. official Codex quota windows from the local Codex App Server; and
2. balance or subscription quota returned by one or more third-party relay APIs.

The extension must accept CC Switch 3.17-compatible usage-query scripts, including the user's existing Wakaka script, without requiring Node.js at runtime. It must preserve the current official-quota behavior when every relay is unavailable or misconfigured.

The desktop presentation has three switchable display modes:

- full window;
- horizontal compact bar;
- quota orb.

Every mode supports both light-transparent and dark-transparent themes.

## 2. Compatibility boundary

### 2.1 Supported CC Switch script contract

The compatibility target is the documented CC Switch 3.17 usage-query contract, not undocumented browser globals or internal application functions. A compatible script evaluates to an object with:

```javascript
({
  request: {
    url: "{{baseUrl}}/user/balance",
    method: "GET",
    headers: {
      Authorization: "Bearer {{apiKey}}"
    },
    body: undefined
  },
  extractor: function (response) {
    return {
      isValid: true,
      remaining: response.balance,
      unit: "USD"
    };
  }
})
```

The runtime supports:

- `{{apiKey}}`, `{{baseUrl}}`, `{{accessToken}}`, and `{{userId}}` placeholder replacement;
- arbitrary valid HTTP method strings accepted by the HTTP client;
- string request bodies and string-valued request headers;
- JSON responses passed to `extractor(response)`;
- a single result object or a non-empty array of result objects;
- optional result fields `isValid`, `invalidMessage`, `remaining`, `unit`, `planName`, `total`, `used`, and `extra`;
- ES2020-or-later syntax supported by the bundled QuickJS runtime;
- query timeouts clamped to 2-30 seconds;
- automatic query intervals from 0-1440 minutes, where 0 disables scheduled queries.

Result fields use the same types as CC Switch: booleans for `isValid`, numbers for `remaining`, `total`, and `used`, and strings for the remaining fields. Unknown result fields are ignored. Invalid field types fail the query rather than being silently coerced.

### 2.2 Presets and custom scripts

The first release includes these templates:

- Wakaka: `{{baseUrl}}/v1/usage` with bearer authentication and extraction of wallet or subscription results;
- General: `{{baseUrl}}/user/balance`;
- New API: `{{baseUrl}}/api/user/self` with access token and user ID;
- Custom: a pasted CC Switch-compatible script.

The template registry is data-driven so later presets do not require changes to the scheduler or presentation layer. Script-level compatibility does not include importing CC Switch's SQLite database or copying credentials from CC Switch.

### 2.3 URL behavior

Built-in templates require HTTPS except for loopback hosts and require the request URL to match the configured Base URL host and effective port.

To match CC Switch custom-template behavior, a custom script may use an explicit HTTP URL or a different host. The first enable or every material destination change requires a warning that names the destination host and explains that the query credentials and response will be sent there. The user must explicitly trust the script before it can run automatically.

## 3. Architecture

### 3.1 Existing companion remains the composition root

The current PowerShell 7/WPF process remains responsible for:

- the single-instance lifecycle;
- official Codex App Server communication;
- the WPF windows and system tray;
- settings, health state, logs, startup registration, repair, and uninstall;
- combining official and relay presentation records.

Official quota state and relay state are independent. A relay failure never restarts the Codex App Server, clears official rows, or changes official authentication state.

### 3.2 Relay quota subsystem

The PowerShell module gains focused components with single responsibilities:

- `RelayProviderStore`: validates and atomically persists provider definitions;
- `CredentialProtection`: encrypts and decrypts current-user secrets with Windows DPAPI;
- `RelayScriptClient`: communicates with the script host over JSONL standard input/output;
- `RelayScheduler`: schedules all enabled providers with bounded concurrency and per-provider backoff;
- `RelayState`: retains current, stale, invalid, and unsupported states per provider;
- `RelayPresentation`: converts validated script results into theme-independent display records;
- `DisplayModeController`: switches full, compact-bar, orb, hidden, theme, and full-layout state without refreshing data.

### 3.3 QuickJS script host

A small Windows x64 Rust sidecar named `relay-quota-host.exe` is built from source in the repository and shipped with the installed companion. Rust is a build-time dependency only; users do not install Rust, Node.js, or a browser runtime.

The sidecar uses QuickJS through `rquickjs` and follows the CC Switch execution sequence:

1. receive a query command and secrets over standard input;
2. replace the four supported placeholders;
3. evaluate the script in a fresh QuickJS runtime and serialize only `request`;
4. validate the destination according to the selected template type;
5. perform the HTTP request outside JavaScript;
6. parse a successful response as JSON;
7. evaluate the script again in a new QuickJS runtime;
8. call `extractor(response)`;
9. serialize, type-check, and return the normalized result over standard output.

The JavaScript context exposes no filesystem, environment, process, shell, module loader, timer, or networking API. Each command has wall-clock, memory, request-size, and response-size limits. The sidecar is stateless between commands and emits no credential-bearing diagnostic output.

PowerShell passes secrets through the sidecar's standard input, never through command-line arguments or environment variables. The sidecar response contains normalized result data and sanitized error metadata only.

## 4. Data and settings

### 4.1 General settings schema

`settings.json` moves from schema 1 to schema 2 through a deterministic migration. Existing window position, topmost, visibility, and startup preferences are preserved. New fields are:

```text
Appearance.Theme            Light | Dark
Appearance.DisplayMode      Full | CompactBar | Orb
Appearance.FullLayout       Overview | Tabs
Appearance.RememberLastMode boolean
Window.Full                 position and size
Window.CompactBar           position
Window.Orb                  position
Compact.FocusMetric         Auto | explicit result identifier
```

Corrupt or unsupported settings retain the existing timestamped recovery behavior. The default is dark theme, full display mode, overview layout, and remember-last-mode enabled.

### 4.2 Relay provider store

`%LOCALAPPDATA%\CodexQuotaMonitor\data\relay-providers.json` stores:

- stable provider ID and display name;
- enabled state;
- Base URL and template type;
- script text;
- timeout and auto-query interval;
- the trusted custom-script destination fingerprint;
- DPAPI-encrypted blobs for API key, access token, and user ID.

Plaintext secrets never appear in JSON, health state, logs, crash messages, command lines, or environment variables. Atomic writes and a named mutex follow the existing settings persistence pattern.

`relay-cache.json` persists only the last successful normalized results, update timestamps, and provider IDs. It never stores raw HTTP responses, scripts after placeholder replacement, request headers, or secrets. Cache is used only as clearly marked stale data after restart.

## 5. Query scheduling and state

All enabled relay providers are monitored, not only the provider currently selected in Codex or CC Switch.

- Default interval: 10 minutes.
- Global relay concurrency: 2.
- Manual refresh: refresh official Codex quota and all enabled relays, while deduplicating an already-running provider request.
- `429` or explicit rate-limit errors: provider-local exponential interval extension up to 60 minutes, respecting `Retry-After` when valid.
- Network and 5xx errors: keep the last good result and retry with bounded backoff.
- Authentication or account-invalid result: mark only that provider invalid and stop rapid retries.
- Script/configuration errors: do not auto-retry until configuration changes or the user selects Test/Refresh.

Each provider has one of these states:

- `Starting`;
- `Live`;
- `Stale`;
- `AuthRequired`;
- `InvalidScript`;
- `Unavailable`;
- `Disabled`.

A failed query never becomes a numeric zero. Zero is shown only when a successful extractor explicitly returns zero.

## 6. User interface

### 6.1 Full window

The full window supports two layouts selected independently from theme:

- `Overview`: summary metrics plus collapsible `Codex 官方额度` and `中转站额度` groups;
- `Tabs`: separate `Codex 官方` and `中转站` tabs for a smaller fixed window.

The title area contains theme, display-mode, layout, minimize/hide, and close buttons. The close button and Alt+F4 hide all visible monitor windows while monitoring continues in the tray. Full exit remains explicit in the tray menu.

### 6.2 Compact bar

The horizontal compact bar shows one focus metric with:

- label;
- percentage or formatted absolute balance;
- a continuous progress bar when a valid percentage exists;
- reset countdown and reset time when returned or derivable;
- mode and close buttons.

Clicking the body opens the full window. The focus metric defaults to the lowest comparable remaining percentage and can be pinned to an explicit official or relay result.

### 6.3 Quota orb

The orb uses a circular ring for the focus metric. It shows a percentage when `total > 0` permits a meaningful ratio. Absolute balances in different units are never compared numerically. If no percentage-bearing result exists, the orb shows the pinned result's compact amount; if nothing is pinned, it shows an em dash. Hover text identifies the source, value, freshness, and reset time. Clicking opens the full window.

### 6.4 Dual themes

All three modes use one visual component model with theme variables, not separate layouts.

- Light: translucent warm neutral background, dark text, teal accent, soft shadow, no opaque white header or hard white border.
- Dark: translucent blue-black background, light text, teal accent, low-contrast separators, and matching dark title area.

Both themes use continuous progress bars. Decorative white segmentation marks are prohibited. Blur uses the Windows DWM capability when available; an alpha-only fallback preserves contrast when blur is unavailable. Text and controls must remain legible over both light and dark desktop backgrounds.

### 6.5 Tray and settings

The tray menu adds:

- `显示模式 → 完整窗口 / 迷你条 / 额度球`;
- `主题 → 浅色透明 / 深色透明`;
- `完整窗口布局 → 总览折叠 / 标签切换`;
- `管理中转站`.

The existing show/hide, topmost, refresh, startup, official usage page, logs, and exit actions remain. Tooltip space is bounded and summarizes the official focus metric plus at most two relay results.

The relay-management dialog supports add, edit, duplicate, delete, enable/disable, template selection, CC Switch script paste, credential entry, timeout, refresh interval, Test Script, and sanitized result/error preview. Saving an untested configuration is allowed but it begins in `Unavailable` until its first successful query.

## 7. Presentation and aggregation rules

Official and relay records retain their own units and labels. USD, CNY, request counts, token counts, and percentages are never summed or compared across incompatible units.

For each relay result:

- use `planName` when present, otherwise the provider name;
- show `remaining` with `unit` when present;
- derive percentage only when finite `total > 0` and finite `remaining` or `used` are available;
- clamp presentation percentages to 0-100 without changing the underlying displayed amounts;
- display `extra` as secondary text with a bounded length;
- mark cached or failed data as stale with its last successful update time.

The tray severity uses the worst valid percentage among official and relay percentage-bearing results. A stale provider adds a warning indicator to its row but does not make the entire tray gray while other live data exists. Gray is reserved for the absence of any usable live or stale data.

## 8. Error handling and diagnostics

Errors are categorized as destination validation, DNS/connectivity, TLS, timeout, HTTP status, response size, JSON parsing, script syntax, extractor execution, result validation, authentication, rate limit, or sidecar lifecycle.

- Last successful normalized values remain visible as stale.
- HTTP response previews in Test Script are capped, decoded as text only, and redact keys matching `token|authorization|cookie|secret|password|api.?key`.
- Production logs contain event names, provider IDs, state changes, durations, HTTP status, and sanitized error categories only.
- Sidecar crash restarts the sidecar without restarting the official Codex session.
- Three consecutive sidecar startup failures mark relay monitoring unavailable while leaving official monitoring live.
- Invalid stored DPAPI data requires re-entering only that provider's secret.

Health JSON extends the current schema with non-secret fields for relay provider count, live/stale/invalid counts, sidecar state, display mode, and theme. Existing health consumers remain compatible with the original official-quota fields.

## 9. Installation, update, and removal

The normal installer copies the PowerShell/WPF files, the sidecar executable, presets, and required notices into `%LOCALAPPDATA%\CodexQuotaMonitor\app` using the existing staged replacement process. It preserves general settings, relay provider definitions, encrypted credentials, normalized cache, and logs.

Repair validates the sidecar hash and replaces missing or mismatched runtime files without clearing data. Uninstall removes runtime files, settings, encrypted relay credentials, cache, logs, and startup shortcut unless `-PreserveData` is explicitly requested.

The sidecar source and third-party license notices are included in the repository and packaged plugin. No network download or toolchain installation occurs during normal plugin installation.

## 10. Verification strategy

### 10.1 Sidecar tests

- CC Switch General and New API examples;
- Wakaka `/v1/usage` wallet and subscription fixtures;
- placeholder replacement and string request body;
- single and multi-plan results;
- type validation and empty-array rejection;
- ES2020 syntax used in compatible extractor scripts;
- built-in HTTPS/same-origin enforcement;
- trusted custom cross-origin behavior;
- absence of file, process, environment, module, timer, and direct-network globals;
- wall-clock, memory, request-size, and response-size limits;
- non-2xx, invalid JSON, and malformed script diagnostics.

### 10.2 PowerShell unit and integration tests

- schema-1 to schema-2 settings migration;
- DPAPI adapter through an injectable deterministic test protector;
- atomic relay-provider and cache persistence;
- scheduler concurrency, deduplication, backoff, and `Retry-After` handling;
- official and relay state isolation;
- mixed-unit presentation rules and compact focus selection;
- stale data preservation and zero-value correctness;
- sidecar JSONL lifecycle and crash recovery;
- install, repair, preserve-data, and uninstall behavior.

### 10.3 UI and visual verification

- full Overview and Tabs layouts;
- compact bar and orb;
- light and dark themes in all three modes;
- no opaque white header or decorative progress segmentation;
- close-to-tray, full exit, mode switching, theme switching, and position persistence;
- readable contrast over representative light and dark desktop backgrounds;
- DPI scaling and off-screen recovery for every window mode.

### 10.4 Live smoke test

After the user enters credentials through the plugin UI, perform one explicit live Wakaka test that reaches `/v1/usage`, returns at least one normalized result, and shows the same value in the Test dialog and monitor. The test must not print or export the API key or raw response. Official Codex quota must remain live during the relay test.

## 11. Acceptance criteria

The extension is accepted when:

- existing CC Switch-compatible Wakaka usage script text can be pasted and executed without modification;
- all enabled relays refresh independently with at most two concurrent queries;
- official quota remains functional when relay monitoring fails;
- failed queries never become a false zero;
- a successful explicit zero is displayed as zero;
- single and multi-plan relay results retain their units and labels;
- full, compact-bar, and orb modes switch without a data refresh;
- Overview and Tabs layouts are both available in the full window;
- light and dark themes are complete in all display modes;
- close hides to tray and tray Exit terminates the process;
- secrets are DPAPI-encrypted at rest and absent from logs, environment, command lines, and health files;
- deterministic sidecar, PowerShell, installation, and UI tests pass;
- live Wakaka and official Codex smoke checks pass without exposing credentials;
- work is completed in `feature/relay-quota-monitor` and merged only after the original plugin branch and this extension both pass their verification suites.

## 12. Sources

- Existing plugin design: `docs/superpowers/specs/2026-07-12-codex-quota-monitor-design.md`
- CC Switch usage-query contract: <https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/zh/2-providers/2.5-usage-query.md>
- CC Switch open-source implementation reference: <https://github.com/farion1231/cc-switch/blob/main/src-tauri/src/usage_script.rs>
- Wakaka public usage endpoint used by its web client: `https://api.wkkapi.com/v1/usage`
