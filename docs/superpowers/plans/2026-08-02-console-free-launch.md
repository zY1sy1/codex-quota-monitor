# Console-Free Launch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task with verification checkpoints.

**Goal:** Launch the installed Codex quota monitor without opening a PowerShell/Windows Terminal console, while keeping the existing WPF/tray runtime unchanged.

**Architecture:** A GUI-subsystem `wscript.exe` shortcut target will invoke a checked-in VBScript launcher. The launcher starts the validated PowerShell 7 entry script with a hidden window and does not wait; the existing PowerShell runtime remains responsible for the monitor UI, single instance, tray, and shutdown behavior. Installation stages the launcher and regenerates the managed Startup shortcut; the current desktop shortcut is migrated as a one-time local deployment step.

**Tech Stack:** PowerShell 7.4+, Windows Script Host (`wscript.exe`), WScript.Shell COM shortcuts, Pester.

---

### Task 1: Add the GUI launcher contract

**Files:**
- Create: `companion/Start-CodexQuotaMonitor.vbs`
- Test: `tests/Integration/StartupShortcut.Tests.ps1`

- [ ] **Step 1: Write the failing launcher test**

Add a test that creates a temporary entry script which writes its PID to a marker and sleeps, invokes `wscript.exe //B //NoLogo` with the new VBS path, PowerShell path, and entry path, waits for the marker, and asserts the launcher process exits while the child remains alive with `MainWindowHandle` equal to zero. The test must put the files under a path containing spaces and Chinese characters.

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```powershell
Invoke-Pester -Path .\tests\Integration\StartupShortcut.Tests.ps1 -Output Detailed
```

Expected: the new launcher test fails because `companion\Start-CodexQuotaMonitor.vbs` does not exist.

- [ ] **Step 3: Implement the minimal VBS launcher**

Create a Windows Script Host file with this behavior:

```vbscript
Option Explicit

Dim shell, pwshPath, entryScript, command
If WScript.Arguments.Count <> 2 Then WScript.Quit 64

pwshPath = WScript.Arguments(0)
entryScript = WScript.Arguments(1)
command = QuoteArgument(pwshPath) & " -NoLogo -NoProfile -NonInteractive -Sta -WindowStyle Hidden -File " & QuoteArgument(entryScript)

Set shell = CreateObject("WScript.Shell")
shell.Run command, 0, False
WScript.Quit 0

Function QuoteArgument(value)
    QuoteArgument = Chr(34) & value & Chr(34)
End Function
```

- [ ] **Step 4: Run the focused test to verify it passes**

Run the same `Invoke-Pester` command and expect the launcher test to pass, including cleanup of the sleeping child process.

- [ ] **Step 5: Commit the launcher**

```powershell
git add companion/Start-CodexQuotaMonitor.vbs tests/Integration/StartupShortcut.Tests.ps1
git commit -m "feat: add console-free monitor launcher"
```

### Task 2: Generate console-free shortcuts

**Files:**
- Modify: `companion/Private/StartupShortcut.ps1`
- Modify: `tests/Integration/StartupShortcut.Tests.ps1`

- [ ] **Step 1: Extend the failing shortcut assertions**

Update the real-shortcut test fixture to create `Start-CodexQuotaMonitor.vbs` beside each temporary entry script. Change its expected target to the absolute `[Environment]::SystemDirectory` `wscript.exe` path and its expected arguments to:

```text
//B //NoLogo "<launcher.vbs>" "<pwsh.exe>" "<entry.ps1>"
```

Add assertions that the returned object exposes `LauncherScript`, `WscriptPath`, and the exact arguments.

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```powershell
Invoke-Pester -Path .\tests\Integration\StartupShortcut.Tests.ps1 -Output Detailed
```

Expected: shortcut assertions fail because `New-MonitorStartupShortcut` still targets `pwsh.exe` and does not expose launcher metadata.

- [ ] **Step 3: Implement validation and shortcut construction**

In `StartupShortcut.ps1`, add a resolver for `[Environment]::SystemDirectory\wscript.exe` that requires an absolute existing file. Add a default launcher path beside `EntryScript`, validate it as an existing `.vbs` file, and set:

```powershell
$shortcut.TargetPath = $fullWscriptPath
$shortcut.Arguments = "//B //NoLogo `"$fullLauncherScript`" `"$fullPwshPath`" `"$fullEntryScript`""
```

Return `WscriptPath`, `LauncherScript`, and the same `Arguments` string. Keep the existing PowerShell 7 probe and working-directory behavior.

- [ ] **Step 4: Run the focused test to verify it passes**

Run the same Pester command and expect all shortcut and launcher tests to pass.

- [ ] **Step 5: Commit shortcut generation**

```powershell
git add companion/Private/StartupShortcut.ps1 tests/Integration/StartupShortcut.Tests.ps1
git commit -m "fix: launch monitor shortcuts through wscript"
```

### Task 3: Stage the launcher during install and repair

**Files:**
- Modify: `companion/Private/Installation.ps1:154-174`
- Modify: `tests/Integration/Installation.Tests.ps1`

- [ ] **Step 1: Add a failing installation payload assertion**

In the idempotent install test, assert that `<app>\Start-CodexQuotaMonitor.vbs` exists. In the source-layout validation test, add a missing-launcher case and assert the operation rejects the incomplete source before changing the installed app.

- [ ] **Step 2: Run the focused installation tests to verify the new assertion fails**

Run:

```powershell
Invoke-Pester -Path .\tests\Integration\Installation.Tests.ps1 -Output Detailed
```

Expected: the payload assertion fails because the staging allowlist does not require or copy the VBS file yet.

- [ ] **Step 3: Update source validation and publish copy rules**

Add `Start-CodexQuotaMonitor.vbs` to `Assert-MonitorSourceLayout` and to the explicit `Copy-Item` file list used by `Publish-MonitorApplication`. The existing call to `Set-MonitorStartupPreference` will then derive the staged launcher path beside the staged entry script.

- [ ] **Step 4: Run installation and shortcut tests**

Run:

```powershell
Invoke-Pester -Path .\tests\Integration\Installation.Tests.ps1, .\tests\Integration\StartupShortcut.Tests.ps1 -Output Detailed
```

Expected: all selected tests pass, including idempotent install, repair rollback, launcher process lifetime, and shortcut metadata.

- [ ] **Step 5: Commit installation staging**

```powershell
git add companion/Private/Installation.ps1 tests/Integration/Installation.Tests.ps1
git commit -m "fix: package launcher with monitor application"
```

### Task 4: Update documentation and migrate the current desktop shortcut

**Files:**
- Modify: `README.md`
- External deployment target: `%USERPROFILE%\Desktop\Codex 余额监视器.lnk`

- [ ] **Step 1: Update the README launch contract**

Replace the Startup shortcut description that says it directly uses `pwsh.exe` with the `wscript.exe` GUI-launcher behavior, and state that closing a terminal is no longer part of the monitor lifecycle.

- [ ] **Step 2: Run documentation and whitespace checks**

Run:

```powershell
git diff --check
```

Expected: no output and exit code 0.

- [ ] **Step 3: Repair the installed copy**

Run the repository's repair script so the current installation receives the VBS payload and managed Startup shortcut:

```powershell
pwsh -NoProfile -File .\scripts\Repair-CodexQuotaMonitor.ps1
```

- [ ] **Step 4: Migrate the existing desktop shortcut without changing presentation metadata**

Read the current desktop shortcut via `WScript.Shell`, preserve its icon, description, and working directory, and set only `TargetPath` plus `Arguments` to the same `wscript.exe`/VBS contract as the repaired Startup shortcut. Verify the resulting `.lnk` target and arguments before launching it.

- [ ] **Step 5: Commit documentation**

```powershell
git add README.md
git commit -m "docs: describe console-free monitor startup"
```

### Task 5: Full verification and manual launch acceptance

**Files:**
- Test: `tests/Unit/*.Tests.ps1`
- Test: `tests/Integration/*.Tests.ps1`

- [ ] **Step 1: Run the complete Pester suite**

Run:

```powershell
Invoke-Pester -Path .\tests -Output Detailed
```

Expected: all tests pass with zero failed or skipped tests attributable to this change.

- [ ] **Step 2: Inspect both managed and desktop shortcuts**

Read both `.lnk` files through `WScript.Shell` and verify `TargetPath` ends in `System32\wscript.exe`, arguments contain `//B //NoLogo`, the VBS path, the validated PowerShell path, and the entry script path, and no argument contains `-NoExit`.

- [ ] **Step 3: Launch the desktop shortcut and verify the user symptom**

Start the desktop shortcut, confirm no Windows Terminal tab or console window appears, confirm the WPF monitor window/tray icon appears, and close the former terminal host if one was already open. Verify the monitor remains alive after any unrelated terminal window is closed; use the tray `退出` command or `Stop-CodexQuotaMonitor.ps1` for final cleanup.

- [ ] **Step 4: Record final status from fresh commands**

Run:

```powershell
git status --short
git log -5 --oneline --decorate
```

Expected: only the pre-existing .superpowers/ untracked directory remains unrelated, and the commits above are present.
