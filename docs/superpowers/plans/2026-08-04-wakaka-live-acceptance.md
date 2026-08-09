# Wakaka User-Authorized Live Acceptance Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the only remaining packaging-acceptance item: one user-authorized live Wakaka quota query and a bounded, redacted evidence record.

**Architecture:** Reuse the shipped Windows UI, DPAPI-backed provider store, packaged `relay-quota-host.exe`, and existing health/status projections. The user enters the real credential only into the UI password field; no command, environment variable, log, screenshot, health file, commit, or chat message receives the credential or raw HTTP data.

**Tech Stack:** PowerShell 7.4+, WPF companion UI, packaged Rust sidecar, Pester 5.7.1, HTTPS endpoint `https://api.wkkapi.com`.

---

## Current status and boundary

The repository implementation is complete and the current automated gates pass: Pester `542/542`, visual matrix generation, Rust tests/format/lint, and packaged-host verification. The unauthenticated Wakaka preflight reached the endpoint and returned HTTP `401`, but the authenticated query has not been run because it requires the user's real credential.

This plan is intentionally an acceptance procedure, not a feature redesign. Do not copy credentials from CC Switch, shell history, process arguments, environment variables, or files. Do not store raw response bodies, provider headers, sidecar JSONL, or complete logs.

## File and evidence map

- Inspect: `scripts/Install-CodexQuotaMonitor.ps1` — installs the candidate and starts the companion.
- Inspect: `scripts/Test-CodexQuotaMonitorHealth.ps1` — verifies process health; use `-Live` only for the user-authorized quota check.
- Inspect: `scripts/Get-CodexQuotaMonitorStatus.ps1` — emits the sanitized public status projection.
- Inspect: `scripts/Uninstall-CodexQuotaMonitor.ps1` — removes the candidate after acceptance unless retention is explicitly requested.
- Inspect: `companion/UI/RelayManager.xaml` — contains the Base URL, password fields, Test Script, and Save and enable controls.
- Modify: `docs/verification-stage5.md` — append only normalized result fields, category, timestamp, and pass/fail conclusions.
- Do not commit: generated files under `outputs/visual` or local `.superpowers/` session artifacts.

### Task 1: Prepare an isolated acceptance session

**Files:**
- Inspect: `D:\Codex\codex-quota-monitor\relay-quota-monitor\build\Verify-PackagedRelayHost.ps1`
- Inspect: `D:\Codex\codex-quota-monitor\relay-quota-monitor\scripts\Get-CodexQuotaMonitorStatus.ps1`

- [ ] **Step 1: Confirm branch and clean tracked state**

Run from the repository root:

```powershell
git branch --show-current
git status --short
```

Expected: branch is `feature/relay-quota-monitor`; no tracked modifications are present. Existing untracked `.superpowers/` session artifacts remain outside this acceptance record and must not be staged.

- [ ] **Step 2: Verify the packaged host before opening the UI**

Run:

```powershell
& .\build\Verify-PackagedRelayHost.ps1
```

Expected output: `Packaged relay host: verified.`

- [ ] **Step 3: Install the candidate through the bundled script**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Install-CodexQuotaMonitor.ps1
```

Then run the ordinary public checks:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Test-CodexQuotaMonitorHealth.ps1
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Get-CodexQuotaMonitorStatus.ps1
```

Expected: ordinary health is valid, `Installed=True`, `Running=True`, and the output contains only the documented sanitized public fields.

### Task 2: Run the user-authorized Wakaka query in the UI

**Files:**
- Inspect: `D:\Codex\codex-quota-monitor\relay-quota-monitor\companion\UI\RelayManager.xaml`
- Inspect: `D:\Codex\codex-quota-monitor\relay-quota-monitor\skills\codex-quota-monitor\SKILL.md`

- [ ] **Step 1: Open the relay manager without passing secrets to the shell**

Open the installed monitor's relay-management window from the tray/menu. Keep the credential entirely inside the UI password field.

- [ ] **Step 2: Select the Wakaka preset and set the explicit base URL**

Use the built-in `Wakaka` template and set Base URL to exactly:

```text
https://api.wkkapi.com
```

Do not paste a credential into Base URL, script text, a command argument, or a normal text field.

- [ ] **Step 3: Enter the real credential only in the password field**

The user enters the credential locally in the UI. The operator must not read it aloud, copy it into a terminal, inspect process arguments, or include it in screenshots.

- [ ] **Step 4: Test the script, then save and enable**

Click `Test Script`, confirm only the normalized result or sanitized error category is shown, then click `Save and enable`. Do not inspect or export raw provider responses or headers.

Expected success projection contains only fields such as plan name, remaining value, total/used values when supplied, unit, success category, and timestamp.

### Task 3: Verify live quota and source isolation

**Files:**
- Inspect: `D:\Codex\codex-quota-monitor\relay-quota-monitor\scripts\Test-CodexQuotaMonitorHealth.ps1`
- Inspect: `D:\Codex\codex-quota-monitor\relay-quota-monitor\scripts\Get-CodexQuotaMonitorStatus.ps1`

- [ ] **Step 1: Run the live health check once**

Run only after the user has completed `Test Script` and `Save and enable` in the UI:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Test-CodexQuotaMonitorHealth.ps1 -Live
```

Expected: the process health remains valid and the relay projection reports a normalized live result, or a sanitized category such as `Authentication`, `HttpStatus`, `Timeout`, or `InvalidResponse`.

- [ ] **Step 2: Confirm official and relay state remain isolated**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Get-CodexQuotaMonitorStatus.ps1
```

Check only the public fields `Status`, `PlanType`, `QuotaWindowCount`, `LastSuccessAt`, `LastErrorCategory`, `RelayProviderCount`, `RelayLiveCount`, `RelayStaleCount`, and `RelayInvalidCount`. A relay authentication failure must not overwrite official ChatGPT quota state.

- [ ] **Step 3: Verify one refresh and one bounded failure path**

Use the UI's provider refresh action once. If the endpoint returns a non-success response, record only the stable category and whether the old cache became stale; do not retry in a loop and do not preserve the response body.

### Task 4: Record bounded evidence and remove the candidate

**Files:**
- Modify: `D:\Codex\codex-quota-monitor\relay-quota-monitor\docs\verification-stage5.md`
- Inspect: `D:\Codex\codex-quota-monitor\relay-quota-monitor\scripts\Uninstall-CodexQuotaMonitor.ps1`

- [ ] **Step 1: Append the live acceptance result**

Add a short dated entry to `docs/verification-stage5.md` containing only:

- whether the UI Test Script and Save and enable actions succeeded;
- normalized plan/value/unit fields, if returned;
- sanitized success/error category;
- timestamp and endpoint hostname only;
- confirmation that no credential, token, raw response, request header, sidecar JSONL, or full log was retained.

Never include the actual credential, a bearer value, a user ID, raw JSON, or a copied header line.

- [ ] **Step 2: Uninstall after acceptance unless retention is explicitly requested**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Uninstall-CodexQuotaMonitor.ps1
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Test-CodexQuotaMonitorHealth.ps1
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Get-CodexQuotaMonitorStatus.ps1
```

Expected final state: `Installed=False`, no packaged `relay-quota-host` process remains, and the public health/status projection contains no secret-bearing fields. Use `-PreserveData` only if the user explicitly requests that settings or logs be retained.

- [ ] **Step 3: Run the release regression gates**

Run:

```powershell
& .\build\Test.ps1 -Suite All
& .\tests\Visual\Capture-QuotaMonitorMatrix.ps1
& .\build\Verify-PackagedRelayHost.ps1
```

Expected: Pester `542/542`, 16 deterministic visual images, and `Packaged relay host: verified.`

- [ ] **Step 4: Commit only the bounded evidence update**

Run:

```powershell
git diff --check
git status --short
git add docs/verification-stage5.md
git commit -m "docs: record user-authorized Wakaka acceptance"
```

Expected: the commit contains only the redacted verification record. Do not stage `.superpowers/`, generated images, health files, logs, or any credential-bearing material.

## Acceptance criteria

The remaining work is complete when all of the following are true:

1. A user-authorized UI query reaches `https://api.wkkapi.com` with the credential entered only in the password field.
2. The UI reports a normalized result or a stable sanitized failure category.
3. Official and relay quota state remain isolated.
4. No credential, token, raw response, request header, sidecar JSONL, or full log is stored in files, screenshots, health/status output, or commits.
5. The candidate is uninstalled (unless explicit retention was requested).
6. The final Pester, visual, Rust, and packaged-host gates pass.

## Stop conditions

Stop and record the sanitized category if the endpoint requires a different credential format, returns an unsupported schema, or the UI cannot complete Test Script without exposing sensitive data. Do not weaken destination validation, logging redaction, DPAPI protection, or protocol allowlists to make the live query pass.
