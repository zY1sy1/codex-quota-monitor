# Codex Quota Monitor Design

Date: 2026-07-12  
Status: Conversation design approved; awaiting written-spec review

## 1. Goal

Create a personal Codex plugin named `codex-quota-monitor` that installs and manages a Windows companion monitor. The companion must show the authenticated user's current Codex quota in both a desktop floating window and a system-tray icon.

The monitor displays:

- the five-hour quota window when returned by Codex;
- weekly and other quota windows returned by Codex;
- remaining percentage for each window;
- a live countdown to the next reset;
- connection freshness and recovery state.

The floating window starts with always-on-top enabled, and the user can toggle that behavior from either the window or the tray menu. The companion starts automatically when the current user signs in to Windows.

## 2. Non-goals

- Do not estimate quota from prompt counts, local token logs, or model prices.
- Do not scrape the ChatGPT website.
- Do not read, export, log, or store ChatGPT access tokens.
- Do not consume earned rate-limit reset credits.
- Do not send model prompts or create Codex threads merely to refresh quota.
- Do not require administrator privileges or a machine-wide service.
- Do not provide cross-platform support in the first version.

## 3. User decisions

- Target OS: the current Windows 11 user account.
- Presentation: desktop floating window plus system tray.
- Startup: launch automatically at Windows sign-in.
- Window level: always-on-top is enabled by default and can be toggled.
- Data shown: five-hour, weekly, and other quota windows plus reset countdowns.
- Implementation: PowerShell/WPF companion to avoid adding a new runtime or SDK.

## 4. System architecture

### 4.1 Personal Codex plugin

The personal plugin is named `codex-quota-monitor` and is registered in the default personal marketplace. It contains:

- `.codex-plugin/plugin.json` with the normalized plugin name and validated metadata;
- `skills/codex-quota-monitor/SKILL.md` for install, start, stop, status, repair, and uninstall workflows;
- `scripts/` for installation, health checks, startup registration, companion launch, and removal;
- `assets/` for tray and plugin icons;
- user documentation describing operation and recovery.

The plugin does not need an MCP server. Its live data source is the official local Codex App Server protocol.

### 4.2 Windows companion

The companion is a PowerShell/WPF process launched without a visible console. It owns:

- the floating quota window;
- the system-tray icon and menu;
- App Server process management and JSONL communication;
- quota normalization and countdown calculation;
- local preferences, logs, and reconnect behavior.

The installer copies the runtime files from the plugin into `%LOCALAPPDATA%\CodexQuotaMonitor\app`. Mutable state is stored separately under `%LOCALAPPDATA%\CodexQuotaMonitor\data`, and logs are stored under `%LOCALAPPDATA%\CodexQuotaMonitor\logs`. This prevents marketplace refreshes from overwriting preferences and keeps the Windows startup entry stable.

### 4.3 Windows startup

The installer creates a shortcut for the current user in:

`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Codex Quota Monitor.lnk`

The shortcut uses the absolute `pwsh.exe` path resolved during installation, starts it in STA mode with a hidden console, and launches the installed companion script. No registry edit, scheduled task, service, elevation, or machine-wide setting is required.

### 4.4 Single-instance behavior

The companion uses a current-user named mutex plus a current-user named event. A second launch sets the event so the existing process activates its window, then exits without opening another App Server process.

## 5. Official data flow

1. Discover `codex.exe` through the executable lookup available to the current user, with the installed Codex app package path as a fallback.
2. Start `codex app-server` using the default `stdio` transport.
3. Send one `initialize` request with client metadata identifying `codex_quota_monitor`.
4. Send the `initialized` notification after the initialization response succeeds.
5. Call `account/read` to distinguish ChatGPT authentication from API-key-only or signed-out states.
6. Call `account/rateLimits/read` and render the full response.
7. Continue reading JSONL notifications. When `account/rateLimits/updated` arrives, request a fresh full `account/rateLimits/read` response rather than assuming the notification is complete.
8. Perform a defensive full refresh every 60 seconds and immediately after system resume or a reset timestamp is reached.
9. If App Server exits or the pipe fails, keep the last successful values, mark them stale, and reconnect with bounded backoff.

The stable protocol surface is sufficient; the companion does not enable experimental App Server capabilities.

Official protocol references:

- https://learn.chatgpt.com/docs/app-server
- https://learn.chatgpt.com/docs/pricing

## 6. Quota normalization

Prefer `rateLimitsByLimitId` when present. Fall back to the backward-compatible `rateLimits` object when the multi-bucket map is absent.

For every returned bucket:

- create a display row for each non-null `primary` or `secondary` window;
- calculate remaining percentage as `clamp(100 - usedPercent, 0, 100)`;
- treat `resetsAt` as Unix seconds and convert it to a local-time countdown;
- preserve an official `limitName` when it is useful and non-empty;
- retain unknown buckets instead of discarding them.

Friendly labels are derived from window duration:

- 270-330 minutes: `5 小时额度`;
- 9,000-11,000 minutes: `周额度`;
- all other durations: the official name when available, otherwise `其他额度 · <duration>`.

When both the compatibility view and multi-bucket view describe the same bucket, only the multi-bucket view is rendered. Repeated rows are deduplicated by limit identifier, window kind, duration, and reset timestamp.

The countdown updates locally once per second. When it reaches zero, the row displays `正在刷新` until a new server response arrives.

## 7. Floating-window design

The initial window is approximately 300 by 180 logical pixels and expands vertically when additional quota rows exist. It uses a compact dark, semi-transparent WPF surface with rounded visual treatment and Windows DPI scaling.

The window contains:

- a header with `Codex 额度`, connection indicator, pin toggle, hide button, and close-to-tray behavior;
- one card or row per normalized quota window;
- a prominent remaining percentage;
- a progress bar whose filled amount represents remaining quota;
- a reset countdown and reset time;
- a footer with the last successful synchronization time when the data is stale.

The user can drag the window. Position, topmost state, and visibility are persisted. If a saved position falls outside the current monitor layout, the window returns to the nearest visible work area.

Closing or hiding the floating window does not stop monitoring. Explicit exit is available from the tray menu.

## 8. System-tray design

The tray icon reflects the lowest remaining percentage across all currently returned windows:

- green above 40 percent;
- yellow from 15 through 40 percent;
- red below 15 percent;
- gray while starting, offline, signed out, or reconnecting.

The tooltip provides a compact summary such as `5h 62% | 周 81%`. The tray context menu contains:

- 显示/隐藏;
- 始终置顶;
- 立即刷新;
- 开机启动;
- 打开官方额度页面;
- 查看日志;
- 退出.

The official dashboard action opens `https://chatgpt.com/codex/settings/usage` in the default browser.

## 9. Runtime states and error handling

The companion exposes five user-facing states:

- `Starting`: discovering and initializing Codex App Server;
- `Live`: authenticated and synchronized;
- `Stale`: showing the last successful data while reconnecting;
- `AuthRequired`: Codex is signed out or the authentication mode cannot provide ChatGPT quota;
- `Unavailable`: Codex cannot be found or App Server cannot be started.

Reconnect delays are 2, 5, 15, 30, and then 60 seconds. A manual refresh, Windows resume, or detected Codex sign-in change resets the delay and retries immediately.

Specific behavior:

- Missing Codex executable: show a gray tray icon and a concise installation/restart message.
- Signed-out account: ask the user to sign in through Codex; do not implement a separate login flow.
- API-key-only account: explain that ChatGPT quota is unavailable in this mode.
- Empty quota response: display `当前账户未返回额度窗口` without fabricating a percentage.
- Unknown or additional fields: ignore safely while retaining recognized windows.
- App Server crash or malformed JSONL line: log the failure, preserve last good data, and restart the connection.
- Network interruption: mark values stale and show their last successful update time.
- System sleep/resume: perform an immediate full reconnect or refresh.

## 10. Security and privacy

- Reuse the authentication state managed by Codex App Server.
- Never open or parse Codex credential files directly.
- Never log complete App Server messages because future payloads may contain account details.
- Log only timestamps, state transitions, method names, response identifiers, and sanitized error summaries.
- Keep all files within the plugin directory, the current user's local application-data directory, and the current user's startup folder.
- Bind no network listener; use only local child-process standard input/output.
- Perform no privileged action.

Logs rotate at approximately 1 MB per file with five retained files.

## 11. Preferences

Preferences are stored as JSON under `%LOCALAPPDATA%\CodexQuotaMonitor\data\settings.json` and include:

- floating-window position;
- always-on-top state;
- visible/hidden state;
- Windows-startup preference.

Corrupt preferences are renamed with a timestamp and replaced with defaults. Credentials and account identifiers are not stored.

## 12. Installation, repair, and uninstall

Installation is idempotent:

1. Validate that PowerShell 7 and Windows Desktop runtime support are available.
2. Copy the companion runtime to the local application-data directory.
3. Create or update the current-user startup shortcut.
4. Start the companion if it is not already running.
5. Run a local health check and report the resulting state.

Repair repeats the copy and startup-registration steps without removing user preferences.

Uninstall stops the companion, removes the startup shortcut, removes installed runtime files, and leaves logs/preferences only when the user explicitly requests preservation. Removing the personal marketplace entry is a separate plugin-management action so companion cleanup can still run first.

## 13. Verification strategy

### 13.1 Parser and calculation tests

Use fixture-driven PowerShell tests for:

- one compatibility bucket;
- primary plus secondary windows;
- multiple `rateLimitsByLimitId` buckets;
- missing secondary window;
- unknown window duration and name;
- duplicate compatibility and multi-bucket data;
- zero, fractional, over-100, and negative `usedPercent` inputs;
- missing or expired reset timestamps;
- malformed JSON and App Server error responses.

### 13.2 Protocol tests

Use a deterministic mock App Server process to verify:

- required initialize/initialized ordering;
- initial account and quota reads;
- refresh after `account/rateLimits/updated`;
- periodic refresh;
- child-process termination and reconnect;
- stale-data preservation;
- signed-out and API-key-only states.

### 13.3 UI and lifecycle tests

Verify:

- DPI-aware window layout and dynamic height;
- dragging and position persistence;
- recovery from an off-screen saved position;
- always-on-top switching;
- close-to-tray and tray restore;
- tray color thresholds and tooltip text;
- single-instance enforcement;
- startup shortcut creation and removal;
- repeated install, repair, and uninstall operations.

### 13.4 Live smoke test

When the execution environment permits launching the installed Codex executable, run a read-only live test that reaches `Live` state and receives at least one valid `account/rateLimits/read` response.

If the Codex agent sandbox blocks direct execution of the packaged `codex.exe`, complete all deterministic tests there, then launch the installed companion in the normal desktop user session. The first-run health check must clearly report whether App Server started, whether ChatGPT authentication is active, and whether quota windows were returned.

## 14. Acceptance criteria

The feature is accepted when:

- the personal plugin validates and appears in the personal marketplace;
- installation completes without administrator privileges;
- one companion instance starts at Windows sign-in;
- the floating window and tray icon can both show current official quota data;
- five-hour, weekly, and other returned windows are not silently dropped;
- remaining percentages and reset countdowns update correctly;
- an App Server update notification triggers a full refresh;
- topmost mode can be toggled and persists;
- offline data is clearly marked stale and automatically recovers;
- no token or credential content is written to disk or logs;
- install, repair, and uninstall behavior is deterministic and documented;
- automated tests and the available live health check pass.
