# Relay Quota Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Windows quota companion with CC Switch-compatible relay balance monitoring, three display modes, two transparent themes, and installable Windows x64 packaging without a user-side Node.js or Rust dependency.

**Architecture:** Execute the work as four ordered, independently testable sub-projects. A Rust/QuickJS sidecar owns untrusted usage-script evaluation and HTTP; PowerShell owns encrypted provider persistence, scheduling, state, and presentation; WPF owns theme-independent full/compact/orb views; packaging joins the verified components without changing the seven-command management surface.

**Tech Stack:** PowerShell 7.4+, WPF, Windows Forms NotifyIcon, Pester 5.7.1, Rust stable MSVC, rquickjs 0.8.1, reqwest 0.12.28 with rustls, serde 1.0.228, serde_json 1.0.149, url 2.5.8, Windows DPAPI, JSONL stdio.

---

## Baseline and branch boundary

- Work only in `D:\Codex\codex-quota-monitor\relay-quota-monitor` on `feature/relay-quota-monitor`.
- The branch contains the approved design at `docs/superpowers/specs/2026-08-01-relay-quota-monitor-design.md`.
- Commit `db20d71` synchronizes the independent branch with `main` after the CRLF contract fix.
- Baseline command:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All -CI
```

Expected baseline: `Tests Passed: 355, Failed: 0`.

Do not edit the original `feature/codex-quota-monitor` worktree. Merge this extension into `main` only after all four plans pass their checkpoints.

## Locked file structure

```text
sidecar/relay-quota-host/                 Rust workspace for the QuickJS/HTTP host
  Cargo.toml                              Exact dependency and binary definition
  Cargo.lock                              Reproducible dependency resolution
  src/protocol.rs                         JSONL command and response types
  src/script.rs                           Placeholder, request, extractor, result logic
  src/destination.rs                      Built-in/custom URL trust policy
  src/http_client.rs                      Bounded host-side HTTP
  src/main.rs                             Stateless one-command-at-a-time JSONL loop
  tests/                                  Protocol, compatibility, HTTP, and sandbox tests

companion/Private/
  RelayCredentials.ps1                   Current-user DPAPI boundary
  RelayProviderStore.ps1                 Canonical provider definitions and presets
  RelayCache.ps1                         Last-good normalized result cache
  RelayState.ps1                         Per-provider state transitions
  RelayScriptClient.ps1                  Sidecar process and JSONL transport
  RelayScheduler.ps1                     Due-time, concurrency, deduplication, backoff
  RelayPresentation.ps1                  Mixed-source rows, focus, severity, tooltip
  Theme.ps1                              Light/dark resources and DWM fallback
  CompactBarView.ps1                     Compact horizontal window adapter
  QuotaOrbView.ps1                       Circular quota window adapter
  RelayManagerView.ps1                   Provider editor and test dialog adapter
  DisplayModeController.ps1              Full/compact/orb/hidden orchestration

companion/UI/
  MainWindow.xaml                         Full Overview/Tabs window
  CompactBar.xaml                         Horizontal compact bar
  QuotaOrb.xaml                           Circular display
  RelayManager.xaml                       Provider management and script testing

companion/Bin/
  relay-quota-host.exe                    Packaged Windows x64 sidecar
  relay-quota-host.sha256                 Repair integrity manifest

companion/Presets/relay-usage.json         Wakaka, General, and New API templates
companion/ThirdPartyNotices.txt             Shipped dependency notices
```

Existing files keep their current responsibilities. `CodexQuotaMonitor.psm1` remains the composition root, `Settings.ps1` remains the only general-settings schema owner, `Installation.ps1` remains the staged install/repair/uninstall owner, and the seven exported management commands do not change.

## Ordered sub-plans

1. [Relay Script Host](2026-08-01-relay-script-host.md) — produces a standalone, tested Windows x64 JSONL executable.
2. [Relay Data Runtime](2026-08-01-relay-data-runtime.md) — produces headless multi-provider monitoring through a fake or real sidecar.
3. [Multi-Mode Quota UI](2026-08-01-multi-mode-quota-ui.md) — produces full/compact/orb displays, dual themes, tray controls, and provider management.
4. [Packaging and Acceptance](2026-08-01-relay-packaging-acceptance.md) — produces the installable plugin, docs, integrity checks, full automated suite, visual matrix, and credential-safe live smoke test.

Each sub-plan must finish with a clean working tree and its own focused commit series. Later plans depend only on committed interfaces from earlier plans.

## Cross-plan contracts

The sidecar accepts exactly one compact JSON object per input line:

```json
{"id":"query-1","operation":"query","script":"({request:{url:'{{baseUrl}}/v1/usage',method:'GET',headers:{Authorization:'Bearer {{apiKey}}'}},extractor:r=>({isValid:true,remaining:r.balance,unit:'USD'})})","templateType":"Wakaka","baseUrl":"https://api.wkkapi.com","secrets":{"apiKey":"secret","accessToken":"","userId":""},"timeoutMs":10000,"trustedDestination":null}
```

It returns exactly one compact response line with the same `id`:

```json
{"id":"query-1","ok":true,"results":[{"isValid":true,"invalidMessage":null,"remaining":18.42,"unit":"USD","planName":null,"total":null,"used":null,"extra":null}],"meta":{"httpStatus":200,"destinationHost":"api.wkkapi.com","durationMs":84}}
```

Errors never contain raw response text, scripts, URLs with query strings, or secrets:

```json
{"id":"query-1","ok":false,"error":{"category":"HttpStatus","message":"Relay request returned HTTP 401.","httpStatus":401,"retryAfterSeconds":null}}
```

When a Custom script has no matching saved trust fingerprint, request evaluation stops before HTTP and returns `DestinationTrustRequired` with only `destinationHost` and canonical `destinationFingerprint`. The UI asks for trust and retries only after acceptance; it never discovers a custom destination by sending credentials first.

PowerShell presentation rows shared by all three displays use this exact ordered shape:

```powershell
[pscustomobject][ordered]@{
    Key = 'relay:wkk:wallet'
    SourceKind = 'Relay'
    SourceId = 'wkk'
    GroupLabel = '中转站额度'
    Label = 'Wakaka'
    ValueText = '$18.42 USD'
    SecondaryText = ''
    ProgressValue = $null
    Countdown = ''
    ResetTime = ''
    IsStale = $false
    UpdatedAt = [DateTimeOffset]'2026-08-01T08:00:00Z'
    State = 'Live'
}
```

These names and scalar types must remain identical across the runtime, view adapters, tests, health projection, and live smoke verification.

## Spec coverage review

| Approved design section | Implementing plan/task | Verification boundary |
|---|---|---|
| CC Switch contract, four replacements, single/array results | Script Host Tasks 1, 2, 4 | Rust protocol/request/extractor tests |
| Built-in HTTPS/same-origin and Custom explicit trust | Script Host Task 3; UI Task 6 | Destination tests plus no-HTTP trust warning test |
| Fresh QuickJS runtimes, capability denial, limits | Script Host Tasks 2, 4, 5 | Sandbox, timeout, size, redaction tests |
| DPAPI providers, presets, cache | Data Runtime Tasks 1, 2 | Pester canonicalization and plaintext-sentinel tests |
| All-provider scheduler, concurrency two, backoff | Data Runtime Task 4 | Injected-clock scheduler table tests |
| Official/relay state isolation and health | Data Runtime Task 6 | Fake App Server plus fake sidecar integration |
| Mixed units, stale values, explicit zero, compact focus | Data Runtime Tasks 2, 5 | Presentation/state table tests |
| Full Overview/Tabs, compact bar, orb | UI Tasks 2, 3, 4 | WPF composition and 16-image matrix |
| Complete Light/Dark transparency and continuous bars | UI Tasks 2, 7 | Theme contract plus visual inspection |
| Close-to-tray, tray Exit, mode/theme/layout menus | UI Task 5 | Controller and tray callback tests |
| Provider management and safe Test Script | UI Task 6 | CRUD, trust, and sanitized preview tests |
| Build, install, repair, uninstall, preserve data | Packaging Tasks 1, 2 | Hash and lifecycle integration tests |
| Fake end-to-end and live Wakaka acceptance | Packaging Tasks 4, 5 | Local fake API plus UI-entered live credential smoke |

Coverage review result: every approved design section maps to an implementation task and an explicit test or bounded manual verification; no uncovered requirement remains.

## Completion gate

The extension is ready to merge only when all commands below succeed from a clean worktree:

```powershell
cargo test --manifest-path .\sidecar\relay-quota-host\Cargo.toml --locked
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All -CI
pwsh -NoLogo -NoProfile -NonInteractive -File .\build\Verify-PackagedRelayHost.ps1
git diff --check
git status --short
```

Expected: Rust tests pass, every Pester test passes, the packaged executable hash and self-test pass, `git diff --check` emits nothing, and `git status --short` emits nothing.
