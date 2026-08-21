# Relay Currency Display Precision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show USD and CNY relay amounts and ratios with exactly two decimal places without changing underlying quota data or non-currency formatting.

**Architecture:** Keep precision policy in the existing shared presentation formatter. Select fixed or compact invariant formatting from the unit, so every view consumes the same display text while stored numeric data remains untouched.

**Tech Stack:** PowerShell 7, Pester 5, existing monitor installation and health scripts.

---

### Task 1: Add the failing currency regression

**Files:**
- Modify: `tests/Unit/RelayPresentation.Tests.ps1`

- [x] Add expectations for `50 CNY -> ¥50.00 CNY`, `0 USD -> $0.00 USD`, and `18.426 USD -> $18.43 USD`.
- [x] Keep `120 requests -> 120 requests` to protect non-currency formatting.
- [x] Add a currency ratio expectation for `$150.00 / $100.00 USD`.
- [x] Assert the source `Remaining` value remains `18.426`.
- [x] Run the focused Pester file and confirm the old formatter fails the new assertions.

### Task 2: Implement unit-aware presentation precision

**Files:**
- Modify: `companion/Private/RelayPresentation.ps1`

- [x] Add `Unit` to `Format-RelayPresentationNumber`.
- [x] Use `0.00` for USD/CNY and `0.########` for other units.
- [x] Pass the unit from both amount and ratio formatting paths.
- [x] Run the focused Pester file and confirm all assertions pass.

### Task 3: Verify and publish the current version

**Files:**
- Verify all files in the current controllable compact quota, refresh, collapse, and currency-formatting change set.

- [ ] Run `pwsh -NoLogo -NoProfile -NonInteractive -File build/Test.ps1 -Suite All -CI`.
- [ ] Run `pwsh -NoLogo -NoProfile -NonInteractive -Sta -File scripts/Install-CodexQuotaMonitor.ps1`.
- [ ] Run ordinary and `-Live` health checks plus the status command.
- [ ] Confirm the installed presentation formatter and refresh-button XAML match the working tree.
- [ ] Run `git diff --check`, review the final file list, commit, push, and create the PR to `main`.
