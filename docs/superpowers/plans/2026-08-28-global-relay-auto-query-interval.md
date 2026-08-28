# 全局中转站自动查询间隔 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persisted global relay auto-query interval in Settings and make the relay scheduler use it for every enabled provider.

**Architecture:** Store `Relay.AutoQueryIntervalMinutes` in schema 3, migrating schema 1/2 values to the new default. Pass the effective global interval into scheduler state creation and rebuild scheduler state when the setting changes. Extend the existing WPF settings view/controller with one validated text input and a callback; preserve provider-level interval data for compatibility.

**Tech Stack:** PowerShell 7, WPF/XAML, Pester, existing relay scheduler and settings persistence helpers.

---

## File Map

- Modify `companion/Private/Settings.ps1`: schema 3 default, validation, canonical migration and serialization for `Relay.AutoQueryIntervalMinutes`.
- Modify `companion/Private/RelayScheduler.ps1`: accept a global interval and apply it to every scheduler entry.
- Modify `companion/Private/SettingsView.ps1` and `companion/UI/Settings.xaml`: add the input control, display it, validate/apply callback, and dispose handlers.
- Modify `companion/Private/SettingsController.ps1`: render the value and route valid/invalid interval changes.
- Modify `companion/CodexQuotaMonitor.psm1`: wire setting changes to persistence and rebuild scheduler state; pass the global value at startup.
- Modify `tests/Unit/Settings.Tests.ps1`, `tests/Unit/RelayScheduler.Tests.ps1`, `tests/Unit/SettingsController.Tests.ps1`, and `tests/Integration/SettingsComposition.Tests.ps1`: regression coverage.

### Task 1: Settings schema and migration

**Files:** `tests/Unit/Settings.Tests.ps1`, `companion/Private/Settings.ps1`

- [ ] **Step 1: Write failing tests** for a schema-3 default (`Relay.AutoQueryIntervalMinutes` equals `10`), schema-2 migration to schema 3 with default `10`, valid `0..1440` round-trip, and rejection of negative, >1440, boolean, decimal, string, and array values.
- [ ] **Step 2: Run the focused tests** with `pwsh -NoProfile -File build/Test.ps1 -Suite Unit`; confirm failures are caused by the missing Relay field/schema handling.
- [ ] **Step 3: Implement minimal schema support**: add `Relay` to `New-DefaultSettings`; accept schema versions 1, 2, and 3; migrate v1/v2 through fresh defaults; require a Relay object for v3; validate an integer in `0..1440`; emit only canonical schema-3 fields.
- [ ] **Step 4: Re-run `tests/Unit/Settings.Tests.ps1`** and confirm all focused tests pass.
- [ ] **Step 5: Commit** with `git add companion/Private/Settings.ps1 tests/Unit/Settings.Tests.ps1; git commit -m "feat: persist global relay query interval"`.

### Task 2: Scheduler global override

**Files:** `tests/Unit/RelayScheduler.Tests.ps1`, `companion/Private/RelayScheduler.ps1`

- [ ] **Step 1: Write failing tests** that construct providers with different `IntervalMinutes` values and call `New-RelaySchedulerState -AutoQueryIntervalMinutes 7`; assert every entry is `7`, `0` produces `MaxValue`, and manual refresh still creates actions when the global interval is `0`.
- [ ] **Step 2: Run `pwsh -NoProfile -File build/Test.ps1 -Suite Unit`; confirm the new parameter is missing/fails.
- [ ] **Step 3: Add `AutoQueryIntervalMinutes` with range validation** to `New-RelaySchedulerState`, validate `0..1440`, and use it instead of provider intervals when creating entries. Keep all action, backoff, pause, and manual-refresh code unchanged.
- [ ] **Step 4: Re-run the focused scheduler tests** and confirm they pass alongside the existing scheduler cases.
- [ ] **Step 5: Commit** with `git add companion/Private/RelayScheduler.ps1 tests/Unit/RelayScheduler.Tests.ps1; git commit -m "feat: apply global relay scheduler interval"`.

### Task 3: Settings view and controller

**Files:** `tests/Unit/SettingsController.Tests.ps1`, `tests/Integration/SettingsComposition.Tests.ps1`, `companion/UI/Settings.xaml`, `companion/Private/SettingsView.ps1`, `companion/Private/SettingsController.ps1`

- [ ] **Step 1: Write failing tests** requiring a named `AutoQueryIntervalTextBox` with automation name `中转站自动查询间隔分钟数`, snapshot rendering of its value, callback dispatch with parsed integers, invalid-input status, and callback cleanup on dispose.
- [ ] **Step 2: Run `pwsh -NoProfile -File build/Test.ps1 -Suite Integration` plus the controller unit tests; confirm the control and callback contract failures.
- [ ] **Step 3: Add the XAML input** in the existing settings stack with a numeric-friendly `TextBox`, a `TextBlock` unit label, and the required automation property; add it to `SettingsView` control discovery.
- [ ] **Step 4: Implement view behavior**: `SetSnapshot` accepts `RelayAutoQueryIntervalMinutes`; `LostFocus` and Enter invoke `OnSetRelayAutoQueryInterval` with the text; callback returns success/error and updates status; dispose removes both handlers and clears the callback.
- [ ] **Step 5: Extend `SettingsController`** with `SetRelayAutoQueryInterval`, render the snapshot value, and show `自动查询间隔必须是 0 到 1440 之间的整数。` on invalid input while retaining the previous displayed value.
- [ ] **Step 6: Run the focused tests** and confirm view/controller behavior passes.
- [ ] **Step 7: Commit** with `git add companion/UI/Settings.xaml companion/Private/SettingsView.ps1 companion/Private/SettingsController.ps1 tests/Unit/SettingsController.Tests.ps1 tests/Integration/SettingsComposition.Tests.ps1; git commit -m "feat: add relay interval setting control"`.

### Task 4: Runtime wiring and immediate application

**Files:** `tests/Integration/RelayRuntime.Tests.ps1`, `companion/CodexQuotaMonitor.psm1`

- [ ] **Step 1: Write failing integration coverage** that starts the runtime with two providers and schema-3 settings, verifies both scheduler entries use the global value, invokes the settings callback, verifies the settings file and scheduler update, and verifies `0` disables automatic actions while manual refresh remains available.
- [ ] **Step 2: Run `pwsh -NoProfile -File build/Test.ps1 -Suite Integration`; confirm runtime wiring failures.
- [ ] **Step 3: Pass the setting into initial scheduler creation** and add a runtime callback that validates, mutates `runtime.Settings.Relay.AutoQueryIntervalMinutes`, persists settings, and rebuilds scheduler state using the current provider list and UTC now.
- [ ] **Step 4: Pass the callback and value through `SettingsController` construction and snapshot generation**; ensure official quota refresh code and provider files are untouched.
- [ ] **Step 5: Re-run the integration suite** and then the complete suite via `pwsh -NoProfile -File build/Test.ps1 -Suite All`; resolve any regressions before proceeding.
- [ ] **Step 6: Commit** with `git add companion/CodexQuotaMonitor.psm1 tests/Integration/RelayRuntime.Tests.ps1; git commit -m "feat: wire global relay interval into runtime"`.

### Task 5: Final verification

**Files:** existing test suite only

- [ ] **Step 1: Run `pwsh -NoProfile -File build/Test.ps1 -Suite All`** from `z` and require all unit/integration tests to pass with no new warnings.
- [ ] **Step 2: Run `git diff HEAD~4..HEAD --check`** and inspect changed files for accidental provider-file or official-quota behavior changes.
- [ ] **Step 3: Update `README.md`** only if the repository's settings documentation test requires documenting the new option; include default `10`, range `0..1440`, and `0` manual-only semantics.
- [ ] **Step 4: Commit any documentation/test-only adjustment** with `git add README.md tests; git commit -m "docs: describe global relay query interval"`.
