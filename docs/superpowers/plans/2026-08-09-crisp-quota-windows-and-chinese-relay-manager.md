# Crisp Quota Windows and Chinese Relay Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove DWM blur from the three transparent quota windows, restore a concentric quota-orb ring, and localize the relay manager's fixed user-facing interface text into Chinese.

**Architecture:** Keep the existing WPF views, controller callbacks, provider schema, and internal tags intact. Remove only the blur dependency and `SourceInitialized` registration from the three view adapters, align the orb track mathematically with the runtime arc's `(35, 35)` center and radius `35`, and translate only display strings and accessibility names.

**Tech Stack:** PowerShell 7.6, WPF/XAML, Pester 5.7.1, existing installer and health scripts.

---

### Task 1: Remove DWM blur from all transparent quota windows

**Files:**
- Create: `tests/Integration/CrispWindowComposition.Tests.ps1`
- Modify: `companion/Private/WpfView.ps1`
- Modify: `companion/Private/CompactBarView.ps1`
- Modify: `companion/Private/QuotaOrbView.ps1`

- [ ] **Step 1: Write the failing source-contract test**

Create a Pester test that scans each view adapter and rejects every blur dependency or handler:

```powershell
BeforeAll {
    $script:ViewPaths = @(
        'WpfView.ps1', 'CompactBarView.ps1', 'QuotaOrbView.ps1'
    ) | ForEach-Object { Join-Path $PSScriptRoot "..\..\companion\Private\$_" }
}

Describe 'crisp transparent quota windows' {
    It 'keeps <File> free of DWM blur setup' -TestCases @(
        @{ File = 'WpfView.ps1' }
        @{ File = 'CompactBarView.ps1' }
        @{ File = 'QuotaOrbView.ps1' }
    ) {
        param($File)
        $path = Join-Path $PSScriptRoot "..\..\companion\Private\$File"
        $source = Get-Content -LiteralPath $path -Raw
        $source | Should -Not -Match 'Enable-MonitorWindowBlur|EnableBlur|SourceInitialized'
    }
}
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```powershell
$pester = 'C:\Users\335\.codex\plugins\cache\personal\codex-quota-monitor\0.1.0+codex.20260801051004\.tools\Modules\Pester\5.7.1\Pester.psd1'
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "Import-Module '$pester' -Force; Invoke-Pester -Path '.\tests\Integration\CrispWindowComposition.Tests.ps1' -Output Detailed"
```

Expected: three failures because every adapter still stores `EnableBlur`, registers `SourceInitialized`, and calls `Enable-MonitorWindowBlur`.

- [ ] **Step 3: Remove the blur-only state and event wiring**

In each adapter:

1. Stop checking `Enable-MonitorWindowBlur` in the top-level theme import guard.
2. Remove the `EnableBlur` state property.
3. Remove the `SourceInitialized` delegate construction.
4. Remove `Add_SourceInitialized` and `Remove_SourceInitialized` calls.
5. Remove the dispose-time `EnableBlur = $null` assignment.

Keep `Theme.ps1` and `Enable-MonitorWindowBlur` itself unchanged so the standalone compatibility function remains available.

- [ ] **Step 4: Run the crisp-window test and related WPF tests**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "Import-Module '$pester' -Force; Invoke-Pester -Path @('.\tests\Integration\CrispWindowComposition.Tests.ps1','.\tests\Integration\WpfComposition.Tests.ps1','.\tests\Integration\CompactBarComposition.Tests.ps1','.\tests\Integration\QuotaOrbComposition.Tests.ps1','.\tests\Integration\ThemeComposition.Tests.ps1') -Output Detailed"
```

Expected: all selected tests pass, including the standalone blur compatibility tests in `ThemeComposition.Tests.ps1`.

- [ ] **Step 5: Commit the focused change**

```powershell
git add tests/Integration/CrispWindowComposition.Tests.ps1 companion/Private/WpfView.ps1 companion/Private/CompactBarView.ps1 companion/Private/QuotaOrbView.ps1
git commit -m "fix: remove blur from quota windows"
```

### Task 2: Make the quota-orb track and progress arc concentric

**Files:**
- Modify: `tests/Integration/QuotaOrbComposition.Tests.ps1`
- Modify: `companion/UI/QuotaOrb.xaml`

- [ ] **Step 1: Add failing ring-metrics and boundary-progress tests**

Extend the fixed circular visual test with:

```powershell
$OrbView.Controls.RingTrack.Width | Should -Be 76
$OrbView.Controls.RingTrack.Height | Should -Be 76
$OrbView.Controls.RingTrack.StrokeThickness | Should -Be $OrbView.Controls.RingValue.StrokeThickness
(($OrbView.Controls.RingTrack.Width - $OrbView.Controls.RingTrack.StrokeThickness) / 2) |
    Should -Be 35
$OrbView.Controls.RingValue.Width | Should -Be 70
$OrbView.Controls.RingValue.Height | Should -Be 70
$OrbView.Controls.RingValue.StrokeStartLineCap | Should -Be ([Windows.Media.PenLineCap]::Round)
$OrbView.Controls.RingValue.StrokeEndLineCap | Should -Be ([Windows.Media.PenLineCap]::Round)
```

Add test cases for 0 and 100 percent. Render each value, assert the arc is present, the start point is `(35, 0)`, the segment radius is `(35, 35)`, and for 100 percent assert the end point is close to but not exactly equal to the start point. Retain the existing 74-percent and null-progress tests.

- [ ] **Step 2: Run the orb test and verify RED**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "Import-Module '$pester' -Force; Invoke-Pester -Path '.\tests\Integration\QuotaOrbComposition.Tests.ps1' -Output Detailed"
```

Expected: the track metrics fail because the current 70-pixel ellipse has a 32-pixel centerline radius.

- [ ] **Step 3: Align the track to the existing arc constants**

Change only `RingTrack` in `QuotaOrb.xaml`:

```xml
<Ellipse x:Name="RingTrack"
         Width="76"
         Height="76"
         Stroke="#664D566A"
         StrokeThickness="6"
         IsHitTestVisible="False" />
```

The 76-pixel ellipse with a 6-pixel stroke has centerline radius `(76 - 6) / 2 = 35`, matching the path geometry centered at `(35, 35)` with radius `35`. Keep the existing `359.999` cap for 100 percent.

- [ ] **Step 4: Run the orb test and verify GREEN**

Run the same targeted Pester command. Expected: all quota-orb composition tests pass for 0, 74, 100, and null progress.

- [ ] **Step 5: Commit the focused change**

```powershell
git add tests/Integration/QuotaOrbComposition.Tests.ps1 companion/UI/QuotaOrb.xaml
git commit -m "fix: align quota orb ring geometry"
```

### Task 3: Localize the relay manager's fixed interface text

**Files:**
- Modify: `tests/Integration/RelayManagerComposition.Tests.ps1`
- Modify: `companion/UI/RelayManager.xaml`
- Modify: `companion/Private/RelayManagerView.ps1`
- Modify: `companion/Private/InteractionController.ps1`
- Modify: `companion/CodexQuotaMonitor.psm1`

- [ ] **Step 1: Add failing localization and compatibility tests**

Add tests that:

1. Parse `RelayManager.xaml` and assert the Chinese window title, list heading, action buttons, field labels, advanced request heading, test/preview/save/cancel labels, and Chinese automation names.
2. Reject the known fixed English UI phrases (`Providers`, `Add`, `Edit`, `Duplicate`, `Delete`, `Enabled`, `Provider kind`, `Advanced request`, `Extractor function`, `Test provider`, `Save`, `Cancel`) in display attributes.
3. Assert combo-box `Tag` values remain exactly `Generic`, `Custom`, `GET`, `POST`, and `PUT`.
4. Instantiate the view, call `SetProviders` with a disabled provider, and expect `名称（已禁用）`.
5. Call `SetPreview` with a result lacking `PlanName` and expect the default label `结果`.
6. Scan `RelayManagerView.ps1` for the Chinese trust prompt/title and reject the old English prompt, `(disabled)`, and `Result` fallback.
7. Exercise controller test states so local validation, credentials, testing, success/failure, save failure, and unavailable-host defaults are Chinese.
8. Scan the runtime composition for a Chinese delete confirmation prompt.

- [ ] **Step 2: Run the relay manager test and verify RED**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "Import-Module '$pester' -Force; Invoke-Pester -Path '.\tests\Integration\RelayManagerComposition.Tests.ps1' -Output Detailed"
```

Expected: localization assertions fail while the existing provider security and controller behavior tests continue to run.

- [ ] **Step 3: Translate XAML display strings without changing names or tags**

Use these fixed translations:

```text
Relay quota providers -> 中转站额度管理
Providers -> 中转站列表
Add/Edit/Duplicate/Delete -> 新增/编辑/复制/删除
Enabled/Name/Provider kind -> 启用/名称/类型
Generic/Custom (Content only) -> 通用配置/自定义脚本
Base URL -> 基础地址
Advanced request -> 高级请求
Method/Path -> 请求方法/请求路径
Query JSON object -> 查询参数 JSON
Headers JSON object -> 请求头 JSON
Body (optional string) -> 请求体（可选字符串）
Extractor function -> 提取函数
API key/Access token/User ID -> API 密钥/访问令牌/用户 ID
Timeout/Interval -> 超时（秒）/查询间隔（分钟，0 为手动）
Test provider -> 测试中转站
Sanitized test preview -> 脱敏测试预览
Save/Cancel -> 保存/取消
```

Translate every related `AutomationProperties.Name` consistently. Do not rename controls or change `Tag` values.

- [ ] **Step 4: Translate local runtime defaults**

In `RelayManagerView.ps1`, use:

```powershell
"允许此中转站访问 $Destination 吗？"
'信任中转站目标'
"$name（已禁用）"
'结果'
```

In `InteractionController.ps1`, translate only the fixed user-facing defaults:

```text
Provider settings are invalid. -> 中转站设置无效。
Unable to save the relay provider. -> 无法保存中转站。
Relay credentials must be entered again. -> 请重新输入中转站凭据。
Testing... -> 正在测试…
Test succeeded. -> 测试成功。
Test failed. -> 测试失败。
Relay script host is unavailable. -> 中转站脚本主机不可用。
```

In `CodexQuotaMonitor.psm1`, translate the relay-provider delete confirmation to `确定删除中转站「$name」吗？` and its title to `Codex 额度监视器`.

- [ ] **Step 5: Run relay manager and interaction tests**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "Import-Module '$pester' -Force; Invoke-Pester -Path @('.\tests\Integration\RelayManagerComposition.Tests.ps1','.\tests\Unit\InteractionController.Tests.ps1') -Output Detailed"
```

Expected: all selected tests pass; existing security, credentials, trust fingerprint, and provider schema tests remain green.

- [ ] **Step 6: Commit the focused change**

```powershell
git add tests/Integration/RelayManagerComposition.Tests.ps1 companion/UI/RelayManager.xaml companion/Private/RelayManagerView.ps1 companion/Private/InteractionController.ps1 companion/CodexQuotaMonitor.psm1 docs/superpowers/plans/2026-08-09-crisp-quota-windows-and-chinese-relay-manager.md
git commit -m "feat: localize relay manager in Chinese"
```

### Task 4: Run full verification and deploy the updated local monitor

**Files:**
- Verify only: `tests/**`, `scripts/**`, installed `%LOCALAPPDATA%\CodexQuotaMonitor`
- Generate ignored artifacts: `outputs/visual/*.png`

- [ ] **Step 1: Run the complete PowerShell test suite**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "Import-Module '$pester' -Force; Invoke-Pester -Path '.\tests' -Output Normal"
```

Expected: all discovered tests pass with zero failures.

- [ ] **Step 2: Capture and inspect the deterministic visual matrix**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\tests\Visual\Capture-QuotaMonitorMatrix.ps1
```

Expected: 16 PNG files under `outputs/visual`. Inspect the orb images for a concentric ring and all window images for clean WPF edges without an extra blur halo.

- [ ] **Step 3: Reinstall from the modified repository**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Install-CodexQuotaMonitor.ps1
```

Expected: installation copies the modified source into `%LOCALAPPDATA%\CodexQuotaMonitor\app`, starts the monitor, and reports a healthy running instance.

- [ ] **Step 4: Run ordinary health and status checks**

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Test-CodexQuotaMonitorHealth.ps1
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Get-CodexQuotaMonitorStatus.ps1
```

Expected: ordinary health is valid, installed/running state is true, and only sanitized public status fields are reported.

- [ ] **Step 5: Confirm installed files contain the new contracts**

Read the installed view adapters and relay manager XAML from the status-reported install directory. Confirm there is no blur setup in the three adapters, `RingTrack` is 76 by 76, and the installed relay manager title/buttons are Chinese.

- [ ] **Step 6: Review the final diff and status**

```powershell
git diff HEAD~3 --check
git status --short
git log -4 --oneline
```

Expected: no whitespace errors; only the ignored pre-existing `.superpowers/` directory remains untracked, and the three implementation commits are present.
