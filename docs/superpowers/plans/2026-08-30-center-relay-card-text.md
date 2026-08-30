# Center Relay Card Text Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Vertically center the five text elements inside relay quota cards while leaving official cards and all horizontal layout unchanged.

**Architecture:** Keep the shared programmatic WPF card builder and add one source-specific presentation branch inside `New-WpfQuotaCard`. The branch reads the existing `SourceKind` field and changes only `VerticalAlignment` on the five known relay `TextBlock` instances. A focused Pester composition test renders official and relay cards together so the relay behavior and official-card regression guard are verified in one view.

**Tech Stack:** PowerShell 7, WPF, Pester 5.7.1, existing deterministic visual-capture and installation scripts.

---

## File Map And Working-Tree Guard

- Modify `tests/Integration/WpfComposition.Tests.ps1:283-330`: render multiline relay content and assert the five relay text alignments, horizontal alignment invariants, and official-card behavior.
- Modify `companion/Private/WpfView.ps1:95-97`: detect relay presentation rows once per card.
- Modify `companion/Private/WpfView.ps1:306-310`: set `VerticalAlignment.Center` only on the five relay text blocks.
- Generate only ignored `outputs/visual/*.png` files during visual verification.
- Deploy only through `scripts/Install-CodexQuotaMonitor.ps1`; never edit `C:\Users\335\AppData\Local\Programs\CodexQuotaMonitor\app` directly.

The two source/test modifications already exist as a user-owned draft in the working tree. Preserve them while establishing the RED evidence against the committed baseline in a disposable temporary copy. Do not reset, stash, clean, or reverse-apply the working tree. Preserve the concurrent provider-specific design commit and do not modify `docs/superpowers/specs/2026-08-30-provider-specific-relay-query-interval-design.md`.

### Task 1: Lock The Relay-Only Alignment Contract And Prove RED

**Files:**
- Modify: `tests/Integration/WpfComposition.Tests.ps1:283-330`
- Verify baseline: committed `companion/Private/WpfView.ps1`

- [ ] **Step 1: Keep the focused relay/official composition test**

Ensure `WpfComposition.Tests.ps1` contains this test immediately after `renders the shared relay presentation contract without legacy field aliases`:

```powershell
It 'vertically centers relay card text without changing the official card' {
    $script:View = New-QuotaWindowView -XamlPath $XamlPath
    $lineBreak = [string][char]10
    $official = [pscustomobject][ordered]@{
        Key = 'official:five-hour'
        SourceKind = 'Official'
        Label = '5 小时额度'
        RemainingText = '74%'
        SecondaryText = '单位：USD'
        ProgressValue = 74
        CountdownText = '04:59:59'
        ResetTimeText = '重置时间：今天 18:00'
    }
    $relay = [pscustomobject][ordered]@{
        Key = 'relay:wkk:wallet'
        SourceKind = 'Relay'
        Label = '账户余额'
        RemainingText = '¥18.42 / ¥100'
        SecondaryText = ('单位：CNY' + $lineBreak + '最近查询成功')
        ProgressValue = $null
        CountdownText = '—'
        ResetTimeText = ('更新时间：12:00' + $lineBreak + '下次刷新：12:10')
    }

    & $View.RenderGroups -OfficialRows @($official) -RelayRows @($relay)

    $relayTexts = @(Get-TestDescendant -Root $View.Controls.RelayRows -Type ([Windows.Controls.TextBlock]))
    foreach ($tag in @('QuotaLabel', 'QuotaRemaining', 'QuotaSecondary', 'QuotaCountdown', 'QuotaResetTime')) {
        $text = @($relayTexts | Where-Object { [string]$_.Tag -eq $tag })[0]
        $text | Should -Not -BeNullOrEmpty
        $text.VerticalAlignment | Should -Be ([Windows.VerticalAlignment]::Center)
    }
    $relayLabel = @($relayTexts | Where-Object { [string]$_.Tag -eq 'QuotaLabel' })[0]
    $relayRemaining = @($relayTexts | Where-Object { [string]$_.Tag -eq 'QuotaRemaining' })[0]
    $relayReset = @($relayTexts | Where-Object { [string]$_.Tag -eq 'QuotaResetTime' })[0]
    $relayLabel.TextAlignment | Should -Be ([Windows.TextAlignment]::Left)
    $relayRemaining.TextAlignment | Should -Be ([Windows.TextAlignment]::Left)
    $relayReset.TextAlignment | Should -Be ([Windows.TextAlignment]::Right)

    $officialTexts = @(Get-TestDescendant -Root $View.Controls.OfficialRows -Type ([Windows.Controls.TextBlock]))
    $officialLabel = @($officialTexts | Where-Object { [string]$_.Tag -eq 'QuotaLabel' })[0]
    $officialRemaining = @($officialTexts | Where-Object { [string]$_.Tag -eq 'QuotaRemaining' })[0]
    $officialReset = @($officialTexts | Where-Object { [string]$_.Tag -eq 'QuotaResetTime' })[0]
    $officialLabel.VerticalAlignment | Should -Be ([Windows.VerticalAlignment]::Center)
    $officialRemaining.VerticalAlignment | Should -Be ([Windows.VerticalAlignment]::Center)
    $officialReset.VerticalAlignment | Should -Be ([Windows.VerticalAlignment]::Stretch)
}
```

- [ ] **Step 2: Run the draft test against the committed implementation and verify RED**

Run the following from `D:\Codex\codex-quota-monitor\z`. It exports `HEAD` to a uniquely named temporary directory, overlays only the draft test file, runs Pester there, verifies that the named test fails, and deletes only that validated temporary directory. It does not modify the canonical working tree.

```powershell
$repoPath = (Resolve-Path -LiteralPath '.').Path
$tempRootPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratchPath = Join-Path $tempRootPath ('CodexQuotaMonitor-RelayCenter-' + [guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $scratchPath 'baseline.zip'
$baselinePath = Join-Path $scratchPath 'baseline'

[IO.Directory]::CreateDirectory($scratchPath) | Out-Null
try {
    git archive --format=zip --output=$archivePath HEAD
    if ($LASTEXITCODE -ne 0) { throw 'git archive failed.' }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $baselinePath
    Copy-Item -LiteralPath (Join-Path $repoPath 'tests\Integration\WpfComposition.Tests.ps1') `
        -Destination (Join-Path $baselinePath 'tests\Integration\WpfComposition.Tests.ps1')

    $env:PSModulePath = ((Join-Path $repoPath '.tools\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath)
    Import-Module Pester -RequiredVersion 5.7.1 -Force
    $redResult = Invoke-Pester `
        -Path (Join-Path $baselinePath 'tests\Integration\WpfComposition.Tests.ps1') `
        -Output Detailed -PassThru
    $expectedFailure = @($redResult.Tests | Where-Object {
        $_.Name -eq 'vertically centers relay card text without changing the official card' -and
        $_.Result -eq 'Failed'
    })
    if ($expectedFailure.Count -ne 1) {
        throw 'The relay-centering test did not produce the expected RED result against HEAD.'
    }
}
finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratchPath)
    if (-not $resolvedScratch.StartsWith($tempRootPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected scratch path: $resolvedScratch"
    }
    if ([IO.Directory]::Exists($resolvedScratch)) {
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
}
```

Expected: the named test fails with `Expected Center, but got Stretch` for a relay text block; all unrelated composition tests pass. The canonical `git status --short` output remains unchanged.

### Task 2: Adopt The Minimal Relay-Only Implementation And Verify GREEN

**Files:**
- Modify: `companion/Private/WpfView.ps1:95-97`
- Modify: `companion/Private/WpfView.ps1:306-310`
- Test: `tests/Integration/WpfComposition.Tests.ps1`

- [ ] **Step 1: Keep the source-kind discriminator beside the existing card key**

Ensure `New-WpfQuotaCard` reads `SourceKind` once without changing the selected-card logic:

```powershell
$key = [string](Get-WpfPresentationField -PresentationRow $PresentationRow -Name 'Key')
$isRelay = [string](Get-WpfPresentationField -PresentationRow $PresentationRow -Name 'SourceKind') -eq 'Relay'
$selected = -not [string]::IsNullOrEmpty($SelectedKey) -and $SelectedKey -eq $key
```

- [ ] **Step 2: Keep the minimal alignment branch after all five text blocks exist**

Place this block after the timing grid is added and before assigning `$card.Child`:

```powershell
if ($isRelay) {
    foreach ($text in @($label, $remaining, $secondary, $countdown, $resetTime)) {
        $text.VerticalAlignment = [Windows.VerticalAlignment]::Center
    }
}
```

Do not set a card-level implicit style and do not change `TextAlignment`, margins, wrapping, row definitions, card dimensions, or official-card properties.

- [ ] **Step 3: Run the focused WPF composition file and verify GREEN**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -Command "& .\build\Restore-TestDependencies.ps1; Invoke-Pester .\tests\Integration\WpfComposition.Tests.ps1 -Output Detailed"
```

Expected: the complete file passes with zero failed tests, including `vertically centers relay card text without changing the official card`.

- [ ] **Step 4: Run the complete PowerShell suite**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\build\Test.ps1 -Suite All
```

Expected: all unit and integration containers pass with zero failed tests.

- [ ] **Step 5: Commit exactly the feature source and regression test**

Run:

```powershell
git add -- companion/Private/WpfView.ps1 tests/Integration/WpfComposition.Tests.ps1
git diff --cached --check
git diff --cached --name-only
git diff --cached -- companion/Private/WpfView.ps1 tests/Integration/WpfComposition.Tests.ps1
git commit -m "fix: center relay card text vertically"
```

Expected: the cached name list contains exactly the two files above; the diff contains only the `$isRelay` discriminator, five-text alignment loop, and focused composition test. The already committed provider-specific design file remains unchanged.

### Task 3: Verify The Visual Result And Update The Installed App

**Files:**
- Verify: `tests/Integration/WpfComposition.Tests.ps1`
- Generate: `outputs/visual/*.png`
- Deploy through: `scripts/Install-CodexQuotaMonitor.ps1`
- Read installed status through: `scripts/Test-CodexQuotaMonitorHealth.ps1`, `scripts/Get-CodexQuotaMonitorStatus.ps1`

- [ ] **Step 1: Regenerate the deterministic visual matrix**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\tests\Visual\Capture-QuotaMonitorMatrix.ps1
Get-ChildItem .\outputs\visual\*-full-overview.png | Sort-Object Name | Select-Object Name, Length
```

Expected: the capture command reports 44 images and lists the four full-overview images for light/dark themes at 100%/150% scaling.

- [ ] **Step 2: Inspect the four full-window overview captures**

Open these files with the local image viewer:

```text
outputs/visual/light-100-full-overview.png
outputs/visual/light-150-full-overview.png
outputs/visual/dark-100-full-overview.png
outputs/visual/dark-150-full-overview.png
```

Confirm that official and relay cards retain their size, horizontal alignment, spacing, and selection controls; text is not clipped or overlapping at either scale. Use the automated multiline relay fixture from Task 1 as the exact row-centering assertion.

- [ ] **Step 3: Install through the repository script**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Install-CodexQuotaMonitor.ps1
```

Expected: the repository installer updates the deployment output and restarts the monitor without directly editing installed files.

- [ ] **Step 4: Run installed health and status checks**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Test-CodexQuotaMonitorHealth.ps1
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\scripts\Get-CodexQuotaMonitorStatus.ps1
```

Expected: health is valid, installed and running are true, and status output contains only sanitized public fields.

- [ ] **Step 5: Review final repository state**

Run:

```powershell
git log -3 --oneline --decorate
git status --short
git diff --check
```

Expected: the relay-centering design, plan, and feature commits are present alongside the concurrent provider-specific design commit. Generated visuals and deployment output are not staged.
