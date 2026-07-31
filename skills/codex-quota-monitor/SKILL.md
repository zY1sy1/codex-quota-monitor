---
name: codex-quota-monitor
description: Use when a Windows user asks to install, show, start, stop, repair, diagnose, check, or remove the Codex quota monitor, desktop floating window, tray icon, quota display, or reset countdown.
---

# Codex Quota Monitor

## Overview

Operate the monitor through its bundled thin scripts from the plugin root. Locate that root two directories above this `SKILL.md`, and verify that both `scripts` and `companion` exist before running anything. Do not recreate their process, installation, or App Server logic manually.

## Route the request

Run with PowerShell 7.4 or later:

| User intent | Command |
|---|---|
| install | `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Install-CodexQuotaMonitor.ps1` |
| show or start | `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Start-CodexQuotaMonitor.ps1` |
| status | `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Get-CodexQuotaMonitorStatus.ps1` |
| health or diagnose | `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Test-CodexQuotaMonitorHealth.ps1` |
| verify ChatGPT quota is live | `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Test-CodexQuotaMonitorHealth.ps1 -Live` |
| repair | `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Repair-CodexQuotaMonitor.ps1` |
| stop | `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Stop-CodexQuotaMonitor.ps1` |
| uninstall | `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Uninstall-CodexQuotaMonitor.ps1` |

Installation already starts the monitor and waits for health; do not add a redundant Start command. Start is the route for showing or activating an installed instance.

Use `-PreserveData` with `scripts/Uninstall-CodexQuotaMonitor.ps1` only when the user explicitly asks to retain monitor data, settings, or logs. It retains only `data` (including `settings.json`) and `logs`; without that request, do not add the switch.

## Verify mutations

After install, repair, or start, run the ordinary health command. After every mutation, run the status command. Claim installation or process success when ordinary health is valid and the installed/running state matches the request.

When the user expects ChatGPT subscription quota and the account uses supported ChatGPT authentication, additionally run the `-Live` command before claiming quota-read success. Do not require `-Live` for signed-out, API-key-only, Bedrock, or valid zero-window states; report process health separately from quota availability and do not Repair solely because an expected `AuthRequired` or `Unavailable` state cannot pass `-Live`.

Report the health state and sanitized `LastErrorCategory`; keep the explanation bounded to the returned public health fields: `SchemaVersion`, `Status`, `PlanType`, `QuotaWindowCount`, `LastSuccessAt`, `LastErrorCategory`, `LastErrorMessage`, `ProcessId`, and `UpdatedAt`. If a required health check fails, run status once, report the safe category, and recommend or perform Repair only when fixing is in scope. Do not create an unbounded retry loop.

## Privacy and account boundaries

- Never print credentials, tokens, environment secrets, `auth.json`, provider headers, raw App Server messages, raw JSON-RPC traffic, or full logs.
- Do not echo raw exceptions or `InnerException`. Use the sanitized health/status projection and `LastErrorCategory`.
- ChatGPT sign-in is required for subscription quota. API-key-only and Bedrock authentication do not expose ChatGPT quota; an empty quota display in those modes is not fabricated into a value.
- Closing the floating window (`Close`) hides it to the system tray. Choosing `Exit` from the tray stops monitoring.

## Common mistakes

| Mistake | Correct action |
|---|---|
| Starting again immediately after Install | Trust Install's startup; verify the process with ordinary health, then use `-Live` only when ChatGPT quota is expected. |
| Using `-Live` as the installation test for every account | Use ordinary health for the process; add `-Live` only for supported ChatGPT quota. |
| Repairing an expected auth/provider state | Report `AuthRequired` or `Unavailable`; Repair is not an authentication fix. |
| Dumping logs or protocol payloads after failure | Report only sanitized public fields and `LastErrorCategory`. |
| Adding `-PreserveData` by default | Add it only for an explicit retention request. |
