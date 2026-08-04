# Quota Orb Round Ring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the quota orb's 6 px gray track and rounded progress arc share the same 35 px centerline radius at every percentage and supported display scale.

**Architecture:** Preserve the existing radius-35 `ArcSegment` geometry and expand the WPF `Ellipse` track from 70×70 to 76×76. Its 6 px stroke will then have a 35 px centerline radius, matching the value arc; lock the dimensions with a composition-level regression test, then verify the full visual matrix and complete Pester suite.

**Tech Stack:** PowerShell 7.4+, loose WPF XAML, Pester 5.7.1, WPF `RenderTargetBitmap` visual capture.

---

## File structure

- `tests/Integration/QuotaOrbComposition.Tests.ps1` — owns composition-level assertions for the loaded orb XAML and its rendering contract.
- `companion/UI/QuotaOrb.xaml` — defines the quota orb's 112×112 surface, circular track, and progress-path rendering properties.
- `outputs/visual/*.png` — ignored generated evidence for light/dark themes at 100% and 150% scale; these files are inspected but not committed.

### Task 1: Lock and fix the circular rendering contract

**Files:**
- Modify: `tests/Integration/QuotaOrbComposition.Tests.ps1:75-91`
- Modify: `companion/UI/QuotaOrb.xaml:51-60`

- [ ] **Step 1: Write the failing regression assertion**

In the existing `It 'loads the fixed circular visual contract'` test, add the following assertions after the root-border assertions:

```powershell
$OrbView.Controls.RingTrack.Width | Should -Be 76 `
    -Because 'a 76 px box with a 6 px stroke produces the selected 35 px centerline radius'
$OrbView.Controls.RingTrack.Height | Should -Be 76
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\QuotaOrbComposition.Tests.ps1"
```

Expected: the suite fails only at the new width assertion because `RingTrack.Width` is `70` rather than `76`.

- [ ] **Step 3: Apply the minimal XAML fix**

Change only the `RingTrack` dimensions from 70×70 to 76×76 without changing its stroke, color, or the cyan value arc:

```xml
<Ellipse x:Name="RingTrack"
         Width="76"
         Height="76"
         Stroke="#664D566A"
         StrokeThickness="6"
         IsHitTestVisible="False" />
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\QuotaOrbComposition.Tests.ps1"
```

Expected: every quota-orb composition test passes with `FailedCount` equal to `0`.

- [ ] **Step 5: Inspect the focused diff**

Run:

```powershell
git diff -- tests/Integration/QuotaOrbComposition.Tests.ps1 companion/UI/QuotaOrb.xaml
git diff --check
```

Expected: two regression assertions, two XAML dimension changes, and no whitespace errors.

- [ ] **Step 6: Commit the regression fix**

Run:

```powershell
git add -- tests/Integration/QuotaOrbComposition.Tests.ps1 companion/UI/QuotaOrb.xaml
git commit -m "fix: align quota orb track with progress arc"
```

Expected: one commit containing only the test and XAML change.

### Task 2: Verify visual smoothness and regression safety

**Files:**
- Regenerate, do not commit: `outputs/visual/dark-100-orb.png`
- Regenerate, do not commit: `outputs/visual/dark-150-orb.png`
- Regenerate, do not commit: `outputs/visual/light-100-orb.png`
- Regenerate, do not commit: `outputs/visual/light-150-orb.png`

- [ ] **Step 1: Regenerate the complete visual matrix**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\tests\Visual\Capture-QuotaMonitorMatrix.ps1
```

Expected: `Captured 16 deterministic quota-monitor images` and exit code `0`.

- [ ] **Step 2: Inspect the four orb captures**

Open the following files at original resolution:

```text
outputs/visual/dark-100-orb.png
outputs/visual/dark-150-orb.png
outputs/visual/light-100-orb.png
outputs/visual/light-150-orb.png
```

Verify all of the following:

- the 74% cyan arc is concentric with the gray track;
- curvature is constant from the top endpoint through the left and lower sections;
- both endpoints are visibly rounded and unclipped;
- the arc is centered at both 100% and 150% scale;
- text and corner controls remain unchanged and uncut.

- [ ] **Step 3: Run the complete Pester suite**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests"
```

Expected: `FailedCount` is `0` and the command exits successfully.

- [ ] **Step 4: Run final repository checks**

Run:

```powershell
git diff --check
git status --short
git log -3 --oneline --decorate
```

Expected: no whitespace errors; only `.superpowers/` may remain untracked from the approved visual-companion session; the latest implementation commit is `fix: align quota orb track with progress arc`.
