# Relay Amount Display Precision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show relay amounts and ratios with exactly two decimal places without changing underlying quota data.

**Architecture:** Change the existing shared presentation number formatter only. Add focused unit assertions around the helper's consumers, then rebuild and install the packaged app.

**Tech Stack:** PowerShell 7, Pester 5, existing packaging scripts.

---

### Task 1: Add the failing presentation regression

**Files:**
- Modify: `tests/Unit/RelayPresentation.Tests.ps1`

- [ ] Add assertions for `$18.426 USD -> $18.43 USD`, `$50 USD -> $50.00 USD`, `$0 USD -> $0.00 USD`, and `$150 / $100 USD -> $150.00 / $100.00 USD`.
- [ ] Assert the normalized row still exposes numeric `Remaining` and `Total` values unchanged.
- [ ] Run the focused test and confirm it fails on the old variable-precision output.

### Task 2: Implement the fixed two-decimal formatter

**Files:**
- Modify: `companion/Private/RelayPresentation.ps1`

- [ ] Change only `Format-RelayPresentationNumber` to call `ToString('0.00', InvariantCulture)`.
- [ ] Run the focused test and confirm it passes.

### Task 3: Verify and package

**Files:**
- Modify (generated): `companion/Bin/relay-quota-host.exe` only if packaging changes it; otherwise no binary change is expected for this PowerShell-only display fix.

- [ ] Run `pwsh -NoProfile -File build/Test.ps1 -Suite All -CI`.
- [ ] Run `pwsh -NoProfile -File scripts/Install-CodexQuotaMonitor.ps1` with `windir` set, then normal and `-Live` health checks.
- [ ] Confirm the installed app contains the updated `RelayPresentation.ps1` and the monitor is healthy/live.
- [ ] Review `git diff --check` and the final changed-file list.
