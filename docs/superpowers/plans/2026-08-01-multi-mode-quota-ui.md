# Multi-Mode Quota UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver full Overview/Tabs, horizontal compact bar, and quota orb displays with complete light/dark transparent themes, close-to-tray behavior, tray switching, and relay-provider management.

**Architecture:** Keep one theme-independent presentation row model and one display-mode controller. Each WPF window is a thin adapter with injected callbacks; shared theme resources are applied at runtime, and switching mode/layout/theme reuses the existing data snapshot without causing an API refresh.

**Tech Stack:** PowerShell 7.4+, loose WPF XAML, Windows Forms NotifyIcon, DWM composition APIs with alpha fallback, Pester 5.7.1, UI Automation properties.

---

## Task 1: Migrate general settings to schema 2

**Files:**
- Modify: `companion/Private/Settings.ps1`
- Modify: `tests/Unit/Settings.Tests.ps1`
- Modify: `companion/Private/WindowPlacement.ps1`
- Modify: `tests/Unit/WindowPlacement.Tests.ps1`

- [ ] **Step 1: Write failing defaults and migration tests**

```powershell
It 'returns fresh schema-2 appearance and per-mode positions' {
    $settings = New-DefaultSettings
    $settings.SchemaVersion | Should -Be 2
    $settings.Appearance.Theme | Should -BeExactly 'Dark'
    $settings.Appearance.DisplayMode | Should -BeExactly 'Full'
    $settings.Appearance.FullLayout | Should -BeExactly 'Overview'
    $settings.Appearance.RememberLastMode | Should -BeTrue
    $settings.Window.Full.Topmost | Should -BeTrue
    $settings.Window.Full.Visible | Should -BeTrue
    $settings.Window.CompactBar.Left | Should -BeNullOrEmpty
    $settings.Window.Orb.Top | Should -BeNullOrEmpty
    $settings.Compact.FocusMetric | Should -BeExactly 'Auto'
}

It 'migrates schema 1 without losing the existing window preference' {
    [IO.File]::WriteAllText($path, '{"SchemaVersion":1,"Window":{"Left":12.5,"Top":-8,"Topmost":false,"Visible":false},"Startup":false}')
    $settings = Read-MonitorSettings -Path $path
    $settings.SchemaVersion | Should -Be 2
    $settings.Window.Full.Left | Should -Be 12.5
    $settings.Window.Full.Top | Should -Be -8
    $settings.Window.Full.Topmost | Should -BeFalse
    $settings.Window.Full.Visible | Should -BeFalse
    $settings.Startup | Should -BeFalse
}
```

- [ ] **Step 2: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\Settings.Tests.ps1, .\tests\Unit\WindowPlacement.Tests.ps1"
```

Expected: FAIL because schema 2 is unsupported.

- [ ] **Step 3: Implement deterministic schema-1 migration and schema-2 canonicalization**

Use this exact graph:

```powershell
[ordered]@{
    SchemaVersion = 2
    Appearance = [ordered]@{ Theme='Dark'; DisplayMode='Full'; FullLayout='Overview'; RememberLastMode=$true }
    Window = [ordered]@{
        Full = [ordered]@{ Left=$null; Top=$null; Width=[double]420; Height=[double]560; Topmost=$true; Visible=$true }
        CompactBar = [ordered]@{ Left=$null; Top=$null }
        Orb = [ordered]@{ Left=$null; Top=$null }
    }
    Compact = [ordered]@{ FocusMetric='Auto' }
    Startup = $true
}
```

Accept only `Light|Dark`, `Full|CompactBar|Orb`, `Overview|Tabs`, Boolean flags, finite coordinates/sizes, and `Auto` or a bounded nonempty result key. Valid schema 1 is migrated and rewritten once; malformed schema 1/2 retains the existing quarantine behavior.

- [ ] **Step 4: Generalize placement by mode**

Add `Resolve-MonitorModePlacement -Mode Full|CompactBar|Orb` that selects the saved node and mode dimensions, then delegates to the existing visibility/clamping logic. Preserve `Resolve-WindowPlacement` for existing callers and tests.

- [ ] **Step 5: Run and commit settings migration**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\Settings.Tests.ps1, .\tests\Unit\WindowPlacement.Tests.ps1"
git add companion/Private/Settings.ps1 companion/Private/WindowPlacement.ps1 tests/Unit/Settings.Tests.ps1 tests/Unit/WindowPlacement.Tests.ps1
git commit -m "feat: add multi-mode appearance settings"
```

Expected: old settings migrate exactly once and every mode recovers on-screen.

## Task 2: Build shared theme resources and the complete full window

**Files:**
- Create: `companion/Private/Theme.ps1`
- Modify: `companion/UI/MainWindow.xaml`
- Modify: `companion/Private/WpfView.ps1`
- Modify: `tests/Integration/WpfComposition.Tests.ps1`
- Create: `tests/Integration/ThemeComposition.Tests.ps1`

- [ ] **Step 1: Write failing theme-contract tests**

Assert `Get-MonitorThemePalette -Theme Light|Dark` returns the same ordered keys:

```powershell
@('Surface','SurfaceStrong','TextPrimary','TextSecondary','Accent','Track','Separator','Shadow','Warning','Danger')
```

Assert light surface alpha is below `FF`, dark title/body share the same palette family, neither palette uses an opaque white surface/border, and progress foreground contains no segmented overlay resource.

- [ ] **Step 2: Write failing full-window XAML contract tests**

Load `MainWindow.xaml` and require named controls `RootBorder`, `HeaderDragArea`, `ThemeButton`, `ModeButton`, `LayoutButton`, `HideButton`, `CloseButton`, `OverviewPanel`, `TabsPanel`, `OfficialRows`, `RelayRows`, `OfficialTabRows`, `RelayTabRows`, and `FreshnessText`. Assert there is no literal `#FFFFFFFF` background/border and no decorative progress separator element.

- [ ] **Step 3: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\ThemeComposition.Tests.ps1, .\tests\Integration\WpfComposition.Tests.ps1"
```

Expected: FAIL because theme resources and the new named contract are missing.

- [ ] **Step 4: Implement palette and blur fallback**

`Theme.ps1` exposes:

```powershell
function Get-MonitorThemePalette { param([ValidateSet('Light','Dark')][string]$Theme) }
function Set-MonitorWindowTheme { param([object]$Window,[object]$Controls,[ValidateSet('Light','Dark')][string]$Theme) }
function Enable-MonitorWindowBlur { param([IntPtr]$WindowHandle,[scriptblock]$ApplyDwm = $null) }
```

Use light colors `#E6F4EFEA`, `#D9EEE7E1`, `#FF201F1D`, `#FF6F6B67`, teal `#FF4DADB3`; dark colors `#E6323A4C`, `#D93A4358`, `#FFF4F3F1`, `#FFAFB8CB`, teal `#FF58C2C7`. DWM failure returns `$false` and leaves the alpha surface intact; it never prevents window creation.

- [ ] **Step 5: Replace the full window with one transparent component tree**

Keep `WindowStyle=None`, `AllowsTransparency=True`, and `Background=Transparent`. Use a single rounded root border and one header within it, not a separate white card. Overview contains collapsible `Codex 官方额度` and `中转站额度` groups; Tabs contains two tab buttons and matching panels. Use a continuous `ProgressBar` template with no tick/segment children.

- [ ] **Step 6: Extend `New-QuotaWindowView`**

The view accepts `-Theme`, `-FullLayout`, `-OnThemeRequested`, `-OnModeRequested`, `-OnLayoutRequested`, and `-OnFocusRequested`. Expose `SetTheme`, `SetLayout`, and `RenderGroups`:

```powershell
& $view.RenderGroups -OfficialRows $officialRows -RelayRows $relayRows -State $connectionState
& $view.SetTheme 'Light'
& $view.SetLayout 'Tabs'
```

`RenderGroups` fills both Overview and Tabs containers from the same input snapshot and never invokes refresh. Each result card has an accessible pin/unpin focus button that calls `OnFocusRequested($row.Key)`; the selected key is visibly marked and is shared by CompactBar and Orb. `Close` and Alt+F4 continue to cancel closing and call only `OnCloseRequested`.

- [ ] **Step 7: Run and commit the full window/theme**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\ThemeComposition.Tests.ps1, .\tests\Integration\WpfComposition.Tests.ps1"
git add companion/Private/Theme.ps1 companion/UI/MainWindow.xaml companion/Private/WpfView.ps1 tests/Integration/ThemeComposition.Tests.ps1 tests/Integration/WpfComposition.Tests.ps1
git commit -m "feat: add dual-theme full quota window"
```

Expected: both layouts render identical data under both themes and existing close-to-tray tests pass.

## Task 3: Add the horizontal compact bar

**Files:**
- Create: `companion/UI/CompactBar.xaml`
- Create: `companion/Private/CompactBarView.ps1`
- Create: `tests/Integration/CompactBarComposition.Tests.ps1`

- [ ] **Step 1: Write failing compact-bar composition tests**

Require named controls `RootBorder`, `HeaderDragArea`, `MetricLabel`, `MetricValue`, `ProgressTrack`, `ProgressFill`, `CountdownText`, `ResetTimeText`, `ModeButton`, and `CloseButton`. Render a percentage row and assert label/value/progress/countdown/reset; render an absolute wallet row and assert the progress track is hidden rather than fabricated.

- [ ] **Step 2: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\CompactBarComposition.Tests.ps1"
```

Expected: FAIL because the compact view is absent.

- [ ] **Step 3: Implement compact XAML and adapter**

Use an approximately `280 × 64` borderless rounded window matching the supplied horizontal reference. The continuous bar uses a clipped fill rectangle whose width is `track.ActualWidth * ProgressValue / 100`; it contains no vertical white separators. The adapter exposes `Show`, `Hide`, `Activate`, `RenderFocus`, `SetTheme`, `SetTopmost`, `GetPlacement`, `SetCallbacks`, and `Dispose`.

`RenderFocus($null)` displays `暂无可比较额度` and an em dash. Body click calls `OnOpenFull`; close calls `OnCloseRequested` and hides all monitor windows through the controller, never exits.

- [ ] **Step 4: Test both themes and callbacks**

Apply `Light` and `Dark` palettes, assert the root background changes but named structure does not, drag reports finite coordinates, body click and mode/close buttons each call their injected callback once, and ordinary closing is cancelled.

- [ ] **Step 5: Run and commit compact bar**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\CompactBarComposition.Tests.ps1"
git add companion/UI/CompactBar.xaml companion/Private/CompactBarView.ps1 tests/Integration/CompactBarComposition.Tests.ps1
git commit -m "feat: add compact quota bar"
```

Expected: compact composition tests pass.

## Task 4: Add the circular quota orb

**Files:**
- Create: `companion/UI/QuotaOrb.xaml`
- Create: `companion/Private/QuotaOrbView.ps1`
- Create: `tests/Integration/QuotaOrbComposition.Tests.ps1`

- [ ] **Step 1: Write failing orb tests**

Require `RootBorder`, `RingTrack`, `RingValue`, `MetricText`, `SourceText`, `ModeButton`, and `CloseButton`. Test 74% arc geometry, pinned absolute `$18.42`, unpinned absolute em dash, hover tooltip source/value/freshness/reset, both themes, body click, drag, close-to-tray, and disposal.

- [ ] **Step 2: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\QuotaOrbComposition.Tests.ps1"
```

Expected: FAIL because the orb view is absent.

- [ ] **Step 3: Implement deterministic ring geometry**

Add a pure helper:

```powershell
function Get-QuotaOrbArcGeometry {
    param([ValidateRange(0,100)][double]$Percent,[double]$Radius=35)
    $angle = [Math]::Min(359.999, 360 * $Percent / 100)
    $radians = ($angle - 90) * [Math]::PI / 180
    [pscustomobject][ordered]@{
        EndX = $Radius + ($Radius * [Math]::Cos($radians))
        EndY = $Radius + ($Radius * [Math]::Sin($radians))
        IsLargeArc = $angle -gt 180
    }
}
```

The view uses the geometry for percentage rows. For an absolute pinned row it hides `RingValue` and renders compact `ValueText`; without a pinned compatible row it renders `—`.

- [ ] **Step 4: Run and commit the orb**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\QuotaOrbComposition.Tests.ps1"
git add companion/UI/QuotaOrb.xaml companion/Private/QuotaOrbView.ps1 tests/Integration/QuotaOrbComposition.Tests.ps1
git commit -m "feat: add quota orb display"
```

Expected: arc, fallback, theme, and lifecycle tests pass.

## Task 5: Orchestrate modes, themes, layouts, tray, and close behavior

**Files:**
- Create: `companion/Private/DisplayModeController.ps1`
- Modify: `companion/Private/InteractionController.ps1`
- Modify: `companion/Private/TrayView.ps1`
- Modify: `companion/CodexQuotaMonitor.psm1`
- Create: `tests/Unit/DisplayModeController.Tests.ps1`
- Modify: `tests/Unit/InteractionController.Tests.ps1`
- Modify: `tests/Integration/TrayComposition.Tests.ps1`
- Modify: `tests/Integration/MonitorRuntime.Tests.ps1`

- [ ] **Step 1: Write failing display-controller tests**

Use fake views and assert:

```powershell
& $controller.SetSnapshot $rows
& $controller.SetMode 'CompactBar'
$full.HideCalls | Should -Be 1
$compact.ShowCalls | Should -Be 1
$refreshCalls | Should -Be 0
& $controller.SetTheme 'Light'
$full.Theme | Should -BeExactly 'Light'
$compact.Theme | Should -BeExactly 'Light'
$orb.Theme | Should -BeExactly 'Light'
```

Test Full/CompactBar/Orb, open-full click, hidden state, topmost, per-mode placement, Overview/Tabs, pinned focus, remember-last-mode, and rollback when settings persistence fails.

- [ ] **Step 2: Write failing tray menu contract tests**

Require ordered menu groups:

```text
显示/隐藏
显示模式 > 完整窗口, 迷你条, 额度球
主题 > 浅色透明, 深色透明
完整窗口布局 > 总览折叠, 标签切换
管理中转站
始终置顶
立即刷新
开机启动
打开官方额度页面
查看日志
退出
```

Assert submenu check marks update without invoking callbacks and double-click opens the current display/full window according to controller state.

- [ ] **Step 3: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\DisplayModeController.Tests.ps1, .\tests\Unit\InteractionController.Tests.ps1, .\tests\Integration\TrayComposition.Tests.ps1"
```

Expected: FAIL because controller/menu functions are missing.

- [ ] **Step 4: Implement the display controller**

State shape:

```powershell
[pscustomobject][ordered]@{
    Mode = 'Full'
    Theme = 'Dark'
    FullLayout = 'Overview'
    Visible = $true
    Topmost = $true
    Snapshot = [object[]]@()
    FocusKey = 'Auto'
    Disposed = $false
}
```

`SetSnapshot` renders all views while hidden but shows only the selected mode. `SetMode`, `SetTheme`, `SetFullLayout`, and `SetFocusKey` persist settings and rerender from `Snapshot` without `RequestRefresh`. `HideAll` hides three windows. `OpenFull` selects/shows/activates Full. `Dispose` clears callbacks before disposing views.

- [ ] **Step 5: Extend tray and interaction callbacks**

Add callbacks `OnSetDisplayMode`, `OnSetTheme`, `OnSetFullLayout`, and `OnManageRelays`. Keep `OnExit` as the only action that signals the exit event. Every window `Close` and Alt+F4 routes to `HideAll`; tray `Exit` terminates.

- [ ] **Step 6: Compose all views in runtime**

Add `Theme.ps1`, `CompactBarView.ps1`, `QuotaOrbView.ps1`, and `DisplayModeController.ps1` to module load order. Create all three views once, apply recovered placement before showing, pass the merged presentation snapshot to the controller, and keep relay/official refresh logic unchanged during UI-only switches.

- [ ] **Step 7: Run and commit orchestration**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Unit\DisplayModeController.Tests.ps1, .\tests\Unit\InteractionController.Tests.ps1, .\tests\Integration\TrayComposition.Tests.ps1, .\tests\Integration\MonitorRuntime.Tests.ps1"
git add companion/Private/DisplayModeController.ps1 companion/Private/InteractionController.ps1 companion/Private/TrayView.ps1 companion/CodexQuotaMonitor.psm1 tests/Unit/DisplayModeController.Tests.ps1 tests/Unit/InteractionController.Tests.ps1 tests/Integration/TrayComposition.Tests.ps1 tests/Integration/MonitorRuntime.Tests.ps1
git commit -m "feat: orchestrate quota display modes"
```

Expected: switches reuse data, all close paths hide, and only tray Exit stops runtime.

## Task 6: Add relay-provider management and safe test preview

**Files:**
- Create: `companion/UI/RelayManager.xaml`
- Create: `companion/Private/RelayManagerView.ps1`
- Create: `tests/Integration/RelayManagerComposition.Tests.ps1`
- Modify: `companion/Private/InteractionController.ps1`
- Modify: `companion/CodexQuotaMonitor.psm1`

- [ ] **Step 1: Write failing manager contract tests**

Require controls for provider list, add/edit/duplicate/delete, enabled, name, Base URL, template, script, API key/access token/user ID password boxes, timeout, interval, Test Script, Save, Cancel, and sanitized preview. Assert opening an existing provider never exposes encrypted or plaintext secrets through normal text properties.

- [ ] **Step 2: Write failing trust-warning tests**

For built-ins, Test is disabled when URL violates HTTPS/same-origin. For Custom, the first sidecar call with no matching fingerprint must return `DestinationTrustRequired` before HTTP. The dialog shows only the returned `scheme://host:port`; declining leaves `TrustedDestination` unchanged and sends no HTTP request, while accepting stores that exact fingerprint and explicitly retries. A material destination change requires trust again.

- [ ] **Step 3: Run and verify failure**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\RelayManagerComposition.Tests.ps1"
```

Expected: FAIL because the manager is absent.

- [ ] **Step 4: Implement the manager adapter**

Expose `ShowDialog`, `SetProviders`, `ReadDraft`, `SetDraft`, `SetTestState`, `SetPreview`, `ConfirmDestinationTrust`, `SetCallbacks`, and `Dispose`. `ReadDraft` returns plaintext secrets only to the controller in memory. Preview receives normalized result rows or sanitized `{Category,Message,HttpStatus}`; it never receives raw response text or request headers.

- [ ] **Step 5: Wire provider CRUD and Test Script**

The controller canonicalizes a draft, encrypts secrets, atomically saves the store, updates scheduler definitions, and closes only on success. Duplicate creates a new GUID and blank encrypted secrets. Delete requires confirmation and removes matching cache/state. Test decrypts only that draft's secrets, invokes one explicit sidecar query, displays normalized output, and does not enable scheduling unless Save succeeds. A saved configuration that has not passed Test begins in `Unavailable` until its first successful scheduled or manual query.

- [ ] **Step 6: Run and commit manager UI**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\RelayManagerComposition.Tests.ps1, .\tests\Unit\InteractionController.Tests.ps1, .\tests\Integration\MonitorRuntime.Tests.ps1"
git add companion/UI/RelayManager.xaml companion/Private/RelayManagerView.ps1 companion/Private/InteractionController.ps1 companion/CodexQuotaMonitor.psm1 tests/Integration/RelayManagerComposition.Tests.ps1 tests/Unit/InteractionController.Tests.ps1 tests/Integration/MonitorRuntime.Tests.ps1
git commit -m "feat: manage relay quota providers"
```

Expected: CRUD, trust, test preview, and redaction tests pass.

## Task 7: Run the complete 16-image UI matrix

**Files:**
- Create: `tests/Visual/Capture-QuotaMonitorMatrix.ps1`
- Create: `tests/Visual/README.md`
- Modify: `docs/superpowers/plans/2026-08-01-multi-mode-quota-ui.md`

- [ ] **Step 1: Add a deterministic capture harness**

The harness launches fake official and relay data, renders `Full Overview/Full Tabs/CompactBar/Orb × Light/Dark` at 100% and 150% DPI, captures PNGs under ignored `outputs/visual`, and exits through the tray callback. It uses synthetic rows only.

- [ ] **Step 2: Run automated UI and full Pester suites**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All -CI
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\tests\Visual\Capture-QuotaMonitorMatrix.ps1
```

Expected: all Pester tests pass and sixteen labeled PNGs are created.

- [ ] **Step 3: Inspect the matrix against locked visual rules**

For every PNG confirm: no opaque white header, no hard white root border, no decorative white progress segmentation, dark mode styles title and body together, light mode remains transparent, text is readable, close button is present, and metric content is not clipped. Record pass/fail per image in the plan.

- [ ] **Step 4: Commit the capture harness and verification record**

```powershell
git add tests/Visual/Capture-QuotaMonitorMatrix.ps1 tests/Visual/README.md docs/superpowers/plans/2026-08-01-multi-mode-quota-ui.md
git commit -m "test: verify quota display appearance matrix"
git status --short
```

Expected: code/docs status is clean; ignored screenshots remain available for review but are not committed.
