# Relay Packaging and Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the verified relay sidecar and UI into the existing staged installer, document the feature, and pass automated, visual, security, and credential-safe live acceptance checks before merging.

**Architecture:** Build the Rust source reproducibly into a committed Windows x64 runtime with a SHA-256 manifest, then let the existing PowerShell staged publisher copy and repair it as one managed app file. Acceptance uses local fake APIs for deterministic automation and reserves the real Wakaka request for one explicit UI-driven test after the user enters credentials.

**Tech Stack:** PowerShell 7.4+, Cargo locked release build, SHA-256, existing install/repair rollback, Pester 5.7.1, local fake HTTP API, WPF visual capture, Git.

---

## Task 1: Build and verify the packaged sidecar

**Files:**
- Modify: `.gitignore`
- Create: `build/Build-RelayQuotaHost.ps1`
- Create: `build/Verify-PackagedRelayHost.ps1`
- Create: `companion/Bin/relay-quota-host.exe`
- Create: `companion/Bin/relay-quota-host.sha256`
- Create: `companion/ThirdPartyNotices.txt`
- Create: `tests/Integration/PackagedRelayHost.Tests.ps1`

- [ ] **Step 1: Write the failing packaged-host test**

```powershell
It 'ships a hash-matched self-testing Windows x64 host' {
    $exe = Join-Path $CompanionRoot 'Bin\relay-quota-host.exe'
    $manifest = Join-Path $CompanionRoot 'Bin\relay-quota-host.sha256'
    Test-Path -LiteralPath $exe -PathType Leaf | Should -BeTrue
    (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash | Should -BeExactly ([IO.File]::ReadAllText($manifest).Trim())
    $output = & $exe --self-test
    $LASTEXITCODE | Should -Be 0
    $output | Should -BeExactly 'relay-quota-host: ok'
}
```

Also assert `ThirdPartyNotices.txt` names QuickJS/rquickjs, reqwest, serde, rustls, and url with their repository/license references.

- [ ] **Step 2: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\PackagedRelayHost.Tests.ps1"
```

Expected: FAIL because the binary, hash, and notices are absent.

- [ ] **Step 3: Add the locked release build script**

`Build-RelayQuotaHost.ps1` must run:

```powershell
$manifest = Join-Path $PSScriptRoot '..\sidecar\relay-quota-host\Cargo.toml'
$target = Join-Path $PSScriptRoot '..\sidecar\relay-quota-host\target'
$destination = Join-Path $PSScriptRoot '..\companion\Bin'
& cargo build --manifest-path $manifest --release --locked
if ($LASTEXITCODE -ne 0) { throw 'Relay host release build failed.' }
[IO.Directory]::CreateDirectory($destination) | Out-Null
Copy-Item -LiteralPath (Join-Path $target 'release\relay-quota-host.exe') -Destination (Join-Path $destination 'relay-quota-host.exe') -Force
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $destination 'relay-quota-host.exe')).Hash
[IO.File]::WriteAllText((Join-Path $destination 'relay-quota-host.sha256'), "$hash`n", [Text.UTF8Encoding]::new($false))
```

It accepts no URL or credential parameters and never downloads at plugin-install time.

- [ ] **Step 4: Add the verification script and ignore only build outputs**

Append `/sidecar/relay-quota-host/target/` to `.gitignore`; do not ignore `companion/Bin`. `Verify-PackagedRelayHost.ps1` checks file existence, exact uppercase hash, PE architecture x64, `--self-test`, and no unexpected files in `companion/Bin`.

- [ ] **Step 5: Build, test, and commit runtime artifacts**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\build\Build-RelayQuotaHost.ps1
pwsh -NoLogo -NoProfile -NonInteractive -File .\build\Verify-PackagedRelayHost.ps1
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\PackagedRelayHost.Tests.ps1"
git add .gitignore build/Build-RelayQuotaHost.ps1 build/Verify-PackagedRelayHost.ps1 companion/Bin companion/ThirdPartyNotices.txt tests/Integration/PackagedRelayHost.Tests.ps1
git commit -m "build: package relay quota host"
```

Expected: build, hash/self-test, and Pester verification pass; the committed `.exe` hash equals the manifest.

## Task 2: Extend install, repair, status, health, and uninstall

**Files:**
- Modify: `companion/Private/Installation.ps1`
- Modify: `tests/Integration/Installation.Tests.ps1`
- Modify: `scripts/Get-CodexQuotaMonitorStatus.ps1`
- Modify: `scripts/Test-CodexQuotaMonitorHealth.ps1`

- [ ] **Step 1: Write failing staged-layout and integrity tests**

Extend installation tests to require `Bin\relay-quota-host.exe`, its hash, `Presets\relay-usage.json`, and `ThirdPartyNotices.txt` in `app.new` and installed `app`. Corrupt the installed executable, run Repair, and assert the source bytes/hash are restored while settings, providers, cache, and logs remain byte-identical.

- [ ] **Step 2: Write failing preserve/remove tests**

Create synthetic `relay-providers.json`, `relay-cache.json`, and logs. Default uninstall must remove the full root; `-PreserveData` must retain `data` and `logs` only, including encrypted providers/cache, and remove app/bin/startup shortcut. Assert returned result still exposes no secret contents.

- [ ] **Step 3: Write failing health schema-2 projection tests**

Feed `Read-MonitorHealthSnapshot` schema 1 and schema 2 fixtures. Schema 1 remains readable with relay counts defaulted to zero; schema 2 exposes only:

```text
SchemaVersion, Status, PlanType, QuotaWindowCount, LastSuccessAt,
LastErrorCategory, LastErrorMessage, ProcessId, UpdatedAt,
RelayProviderCount, RelayLiveCount, RelayStaleCount, RelayInvalidCount,
RelayHostState, DisplayMode, Theme
```

Unknown fields and sensitive key names are discarded.

- [ ] **Step 4: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\Installation.Tests.ps1"
```

Expected: FAIL because layout/integrity/schema 2 are unsupported.

- [ ] **Step 5: Add staged integrity enforcement**

`Assert-MonitorSourceLayout` and `Publish-MonitorApplication` require the four runtime artifacts. Add `Test-PackagedRelayHostIntegrity` that compares the executable to the sibling hash before publishing and after staging; mismatch throws a constant sanitized `InvalidDataException`. Keep existing rollback behavior unchanged.

- [ ] **Step 6: Extend installed layout and public projections**

`Test-MonitorInstalledLayout` requires the sidecar and hash. `Read-MonitorHealthSnapshot` accepts schema versions 1-2, canonicalizes the new non-secret fields, and keeps the original fields identical. Thin status/health scripts remain parameter pass-throughs and the module still exports exactly seven commands.

- [ ] **Step 7: Run and commit lifecycle changes**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\Installation.Tests.ps1"
git add companion/Private/Installation.ps1 tests/Integration/Installation.Tests.ps1 scripts/Get-CodexQuotaMonitorStatus.ps1 scripts/Test-CodexQuotaMonitorHealth.ps1
git commit -m "feat: install and repair relay monitoring"
```

Expected: install/repair/rollback/uninstall/schema compatibility tests pass.

## Task 3: Update the user guide and management skill contract

**Files:**
- Modify: `README.md`
- Modify: `skills/codex-quota-monitor/SKILL.md`
- Modify: `tests/Unit/SkillContract.Tests.ps1`

- [ ] **Step 1: Write failing documentation contract tests**

Require Chinese README sections for adding a relay, Wakaka/General/New API/Custom templates, API key DPAPI storage, destination warning, Test Script, 10-minute default, three display modes, two themes, close-to-tray versus Exit, stale versus explicit zero, Repair hash behavior, and `-PreserveData` handling.

Require the skill to route relay setup/diagnosis through the installed UI and sanitized health/status commands; it must explicitly forbid printing relay API keys, decrypted provider JSON, raw responses, sidecar stdin/stdout, or full logs.

- [ ] **Step 2: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\SkillContract.Tests.ps1"
```

Expected: FAIL because relay documentation is absent.

- [ ] **Step 3: Write the Chinese user workflow**

Document this exact flow:

```text
托盘 → 管理中转站 → 添加 → 选择模板或粘贴 CC Switch 查询脚本
→ 输入 Base URL 和凭据 → 测试脚本 → 保存并启用
```

Explain that built-ins enforce HTTPS/same-origin, Custom requires explicit destination trust, failure keeps a timestamped stale last-good value, only a successful extractor result can display zero, and USD/CNY/counts are not aggregated.

- [ ] **Step 4: Extend the operational skill safely**

Keep the existing eight intent rows and seven thin scripts unchanged. Add relay-specific privacy, schema-2 public health fields, UI setup, and the rule that Wakaka live verification occurs only after the user enters credentials in the UI; no command copies credentials from CC Switch.

- [ ] **Step 5: Run and commit docs**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\SkillContract.Tests.ps1"
git add README.md skills/codex-quota-monitor/SKILL.md tests/Unit/SkillContract.Tests.ps1
git commit -m "docs: explain relay quota monitoring"
```

Expected: documentation contract passes and contains no authoring markers.

## Task 4: Add deterministic end-to-end fake relay acceptance

**Files:**
- Create: `tests/Fixtures/FakeRelayApi.ps1`
- Create: `tests/Integration/RelayEndToEnd.Tests.ps1`
- Modify: `build/Test.ps1`

- [ ] **Step 1: Write the fake HTTP API fixture**

Listen on loopback with an ephemeral port and support exact paths:

```text
/v1/usage        Wakaka wallet or multi-subscription JSON
/user/balance    General balance JSON
/api/user/self   New API JSON requiring access token and user ID
/rate-limit      429 with Retry-After: 120
/auth            401
/invalid-json     200 text/plain malformed JSON
/slow             response after injected delay
```

The fixture records method/path and Boolean presence of expected headers only; it never stores header values or bodies.

- [ ] **Step 2: Write failing end-to-end tests**

Install into `$TestDrive`, start fake App Server, real packaged sidecar, and fake relay API, save providers through the real encrypted store, run the headless runtime, and assert official plus Wakaka/General/New API results, multi-plan display, cache persistence, concurrency cap two, 429 backoff, stale preservation, explicit zero, sanitized health, and clean shutdown.

- [ ] **Step 3: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\RelayEndToEnd.Tests.ps1"
```

Expected: FAIL until every packaged/runtime boundary is correctly connected.

- [ ] **Step 4: Make only integration corrections proven by the failing cases**

Correct composition or packaging boundaries one at a time without changing the locked protocol or presentation types. After each correction, rerun the single failing `It` block by full name, then the full end-to-end file.

- [ ] **Step 5: Add Rust verification to the repository test entry point**

`build/Test.ps1 -Suite All` first runs packaged-host verification and, when Cargo is available, `cargo test --locked`; CI treats a Rust-test failure as fatal. Normal installed runtime and end users still require neither Cargo nor Rust.

- [ ] **Step 6: Run and commit end-to-end acceptance**

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --locked
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\RelayEndToEnd.Tests.ps1"
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All -CI
git add tests/Fixtures/FakeRelayApi.ps1 tests/Integration/RelayEndToEnd.Tests.ps1 build/Test.ps1
git commit -m "test: verify relay quota monitoring end to end"
```

Expected: Rust, end-to-end, and complete Pester suites pass.

## Task 5: Perform visual, security, and live Wakaka verification

**Files:**
- Create: `docs/verification/2026-08-01-relay-quota-monitor.md`
- Modify: `docs/superpowers/plans/2026-08-01-relay-packaging-acceptance.md`

- [ ] **Step 1: Install the candidate from the independent branch**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Install-CodexQuotaMonitor.ps1
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Test-CodexQuotaMonitorHealth.ps1
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Get-CodexQuotaMonitorStatus.ps1
```

Expected: installed/running health is valid, relay host state is available, and official quota remains live where ChatGPT authentication supports it.

- [ ] **Step 2: Verify the six visual appearances and both full layouts**

Open Full Overview, Full Tabs, CompactBar, and Orb under Light and Dark. Record screenshots and pass/fail for transparency, header/body consistency, no white border/segmentation, readable contrast, close button, DPI, mode/layout/theme persistence, and close-to-tray. Verify switches cause no visible data refresh.

- [ ] **Step 3: Verify provider management with synthetic credentials**

Add Wakaka, General, New API, and Custom loopback providers against the fake API through the UI. Test duplicate/delete/disable, trust decline/accept, invalid script, 401, 429, timeout, stale last-good, and explicit zero. Search installed data/log/health for the unique synthetic secret sentinel; expected matches: zero.

- [ ] **Step 4: Run one user-authorized live Wakaka query**

The user enters the real API key only into the plugin's password field. In `管理中转站`, select Wakaka, set Base URL `https://api.wkkapi.com`, click `测试脚本`, and then Save/Enable. Record only normalized plan/value/unit, HTTP success category, and timestamp. Do not record the key, raw response, request headers, sidecar JSONL, or screenshots containing secrets.

- [ ] **Step 5: Confirm live official/relay isolation**

While Wakaka is live, verify official Codex quota is still live. Temporarily disable the relay or simulate network failure and confirm official rows remain unchanged while relay values become stale; restore connectivity and confirm the relay returns to live without restarting Codex App Server.

- [ ] **Step 6: Write the bounded verification record**

Record exact commit, binary SHA-256, Rust/Pester counts, appearance matrix result, install/repair/uninstall result, sanitized live result summary, and any remaining limitations in `docs/verification/2026-08-01-relay-quota-monitor.md`.

- [ ] **Step 7: Commit acceptance evidence**

```powershell
git add docs/verification/2026-08-01-relay-quota-monitor.md docs/superpowers/plans/2026-08-01-relay-packaging-acceptance.md
git commit -m "docs: record relay quota monitor acceptance"
```

Expected: no credential-bearing artifact is staged.

## Task 6: Final verification and branch handoff

**Files:**
- Verify: all tracked feature files

- [ ] **Step 1: Run every release gate from a clean process**

```powershell
cargo fmt --manifest-path .\sidecar\relay-quota-host\Cargo.toml -- --check
cargo clippy --manifest-path .\sidecar\relay-quota-host\Cargo.toml --all-targets --locked -- -D warnings
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --locked
pwsh -NoLogo -NoProfile -NonInteractive -File .\build\Verify-PackagedRelayHost.ps1
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All -CI
git diff --check
git status --short
```

Expected: every command succeeds and status is empty.

- [ ] **Step 2: Review the branch against the approved design**

Check every acceptance criterion in `docs/superpowers/specs/2026-08-01-relay-quota-monitor-design.md` against a test or verification record. Confirm no task changed the seven-command module export surface and no unit aggregation was introduced.

- [ ] **Step 3: Use the branch-finishing workflow**

Invoke `superpowers:finishing-a-development-branch`, present the verified commit range and merge options, and merge into `main` only after explicit user selection. Do not delete the worktree until the merged `main` suite passes.

- [ ] **Step 4: Verify merged main when merge is selected**

From the main worktree:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All -CI
pwsh -NoLogo -NoProfile -NonInteractive -File .\build\Verify-PackagedRelayHost.ps1
git status --short
```

Expected: merged main passes and remains clean before retiring the feature worktree.
