# Bundled Windows Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify a current-user `CodexQuotaMonitor-Setup-<version>-x64.exe` that includes a private PowerShell 7.6.4 x64 runtime and preserves the existing repository/plugin installation route.

**Architecture:** Inno Setup installs a passive source payload and private runtime under `%LOCALAPPDATA%\Programs\CodexQuotaMonitor`. The candidate module then reuses the existing staged publish/rollback lifecycle to place the active application in `ProgramRoot\app`, while settings and logs remain under `%LOCALAPPDATA%\CodexQuotaMonitor`. Inno handles product registration and Start-menu/desktop shortcuts; the module owns startup preference, process health, legacy migration, and data-safe uninstall preparation.

**Tech Stack:** PowerShell 7.4+/Pester 5.7.1, WPF, Inno Setup 6, VBScript/WScript launcher, SHA-256, Rust packaged sidecar, Windows current-user shortcuts.

---

## File map

- Modify `companion/Private/Settings.ps1`: separate program files from mutable data while retaining the legacy default.
- Modify `companion/Private/Installation.ps1`: thread `ProgramRoot` and explicit private runtime through install, status, repair, start, stop, and uninstall; migrate legacy app files only after successful health.
- Modify `companion/CodexQuotaMonitor.psm1`: accept `ProgramRoot` at runtime and create startup shortcuts with the current private runtime.
- Modify `companion/Start-CodexQuotaMonitor.ps1`: forward `ProgramRoot` into the runtime.
- Modify `companion/Private/StartupShortcut.ps1`: support an explicit shortcut icon without changing existing callers.
- Create `installer/runtime-lock.json`: lock PowerShell 7.6.4 x64 and SHA-256 `80832551C52809301E6071C8BAC977BEB5A2F1EC953EB4DB9F94DEB953333793`.
- Create `installer/scripts/Install-Package.ps1`: validate the installed payload/runtime, publish the app, migrate the legacy app directory, and emit sanitized status.
- Create `installer/scripts/Prepare-Uninstall.ps1`: stop the monitor, remove startup state, and optionally remove mutable data while leaving program-file removal to Inno.
- Create `installer/CodexQuotaMonitor.iss`: per-user installer, stable AppId, pre-copy shutdown, shortcuts, post-copy package install, and uninstall data prompt.
- Create `installer/README.md`: build, install, SmartScreen, upgrade, and uninstall behavior.
- Create `build/Acquire-PowerShellRuntime.ps1`: locked download/cache/extract verifier.
- Create `build/New-InstallerPayload.ps1`: allowlisted staging and manifest creation.
- Create `build/Build-WindowsInstaller.ps1`: single build entry point and setup hash generation.
- Create `build/Test-WindowsInstaller.ps1`: static payload/setup checks and optional compiled-artifact checks.
- Modify `build/Test.ps1`: add an `Installer` suite without changing existing suite meanings.
- Modify `README.md`: document Setup.exe distribution alongside repository installation.
- Modify/add tests under `tests/Unit` and `tests/Integration` for paths, lifecycle, runtime forwarding, shortcuts, support scripts, build lock, and Inno contract.

### Task 1: Separate program and data paths

**Files:**
- Modify: `companion/Private/Settings.ps1:1-24`
- Modify: `tests/Unit/Settings.Tests.ps1:1-28`

- [ ] **Step 1: Write failing path tests**

Add a packaged-path test while retaining the existing legacy-default assertions:

```powershell
It 'separates packaged program files from mutable current-user data' {
    $localAppData = Join-Path $TestDrive 'Local App Data'
    $startup = Join-Path $TestDrive 'Startup'
    $programRoot = Join-Path $localAppData 'Programs\CodexQuotaMonitor'

    $paths = Get-MonitorPaths `
        -LocalAppData $localAppData `
        -Startup $startup `
        -ProgramRoot $programRoot

    $paths.Root | Should -BeExactly (Join-Path $localAppData 'CodexQuotaMonitor')
    $paths.ProgramRoot | Should -BeExactly $programRoot
    $paths.App | Should -BeExactly (Join-Path $programRoot 'app')
    $paths.Payload | Should -BeExactly (Join-Path $programRoot 'payload')
    $paths.PrivatePwsh | Should -BeExactly (Join-Path $programRoot 'runtime\pwsh\pwsh.exe')
    $paths.LegacyApp | Should -BeExactly (Join-Path $localAppData 'CodexQuotaMonitor\app')
    $paths.Data | Should -BeExactly (Join-Path $localAppData 'CodexQuotaMonitor\data')
}
```

- [ ] **Step 2: Run the focused test and observe failure**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File build/Test.ps1 -Suite Unit
```

Expected: failure because `Get-MonitorPaths` does not accept `ProgramRoot` and does not return packaged paths.

- [ ] **Step 3: Implement the dual-root path model**

Change `Get-MonitorPaths` to normalize an optional program root and preserve the current layout when omitted:

```powershell
param(
    [string]$LocalAppData = $env:LOCALAPPDATA,
    [string]$Startup = [Environment]::GetFolderPath('Startup'),
    [AllowNull()][string]$ProgramRoot
)

$root = Join-Path $LocalAppData 'CodexQuotaMonitor'
$legacyApp = Join-Path $root 'app'
$resolvedProgramRoot = if ([string]::IsNullOrWhiteSpace($ProgramRoot)) {
    $root
}
else {
    [IO.Path]::GetFullPath($ProgramRoot)
}
$app = if ($resolvedProgramRoot -eq $root) { $legacyApp } else { Join-Path $resolvedProgramRoot 'app' }

[pscustomobject][ordered]@{
    Root = $root
    ProgramRoot = $resolvedProgramRoot
    App = $app
    LegacyApp = $legacyApp
    Payload = Join-Path $resolvedProgramRoot 'payload'
    Runtime = Join-Path $resolvedProgramRoot 'runtime\pwsh'
    PrivatePwsh = Join-Path $resolvedProgramRoot 'runtime\pwsh\pwsh.exe'
    # retain the existing Data/Logs/Settings/Health/Relay/Startup fields
}
```

- [ ] **Step 4: Run unit tests**

Run `pwsh -NoLogo -NoProfile -NonInteractive -File build/Test.ps1 -Suite Unit`.

Expected: all unit tests pass.

- [ ] **Step 5: Commit only Task 1 files**

```powershell
git add companion/Private/Settings.ps1 tests/Unit/Settings.Tests.ps1
git commit -m "feat: separate packaged program and data paths"
```

### Task 2: Thread packaged paths and private runtime through the lifecycle

**Files:**
- Modify: `companion/Private/Installation.ps1`
- Modify: `companion/CodexQuotaMonitor.psm1`
- Modify: `companion/Start-CodexQuotaMonitor.ps1`
- Modify: `tests/Integration/Installation.Tests.ps1`
- Modify: `tests/Integration/MonitorRuntime.Tests.ps1`

- [ ] **Step 1: Add failing packaged lifecycle tests**

Extend `New-InstallationTestContext` with `ProgramRoot`, then add tests that call public management commands with `-ProgramRoot` and explicit `-PwshPath`:

```powershell
It 'publishes packaged app files outside the mutable data root' {
    $context = New-InstallationTestContext -Name 'Packaged Root'
    $programRoot = Join-Path $context.LocalAppData 'Programs\CodexQuotaMonitor'

    $result = Install-CodexQuotaMonitor `
        -SourcePath $CompanionRoot `
        -LocalAppData $context.LocalAppData `
        -Startup $context.Startup `
        -ProgramRoot $programRoot `
        -PwshPath (Get-Process -Id $PID).Path `
        -InstancePrefix $context.Prefix `
        -SkipStart

    $result.AppPath | Should -BeExactly (Join-Path $programRoot 'app')
    Test-Path (Join-Path $programRoot 'app\CodexQuotaMonitor.psd1') | Should -BeTrue
    Test-Path $context.Data | Should -BeTrue
    Test-Path $context.App | Should -BeFalse
}

It 'removes a legacy app only after packaged health succeeds' {
    # Seed LegacyApp, invoke packaged install with a successful ProcessStarter,
    # and assert LegacyApp is removed while Data and Logs are byte-identical.
}
```

Add a runtime composition assertion that `Invoke-CodexQuotaMonitorRuntime -ProgramRoot` passes the same value to `Get-MonitorPaths` and that the startup callback uses `(Join-Path $PSHOME 'pwsh.exe')`.

- [ ] **Step 2: Run integration tests and observe failure**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File build/Test.ps1 -Suite Integration
```

Expected: parameter-binding and packaged-path failures.

- [ ] **Step 3: Add `ProgramRoot` to management and runtime entry points**

Add `[AllowNull()][string]$ProgramRoot` to `Install-CodexQuotaMonitor`, `Repair-CodexQuotaMonitor`, `Start-CodexQuotaMonitor`, `Stop-CodexQuotaMonitor`, `Get-CodexQuotaMonitorStatus`, `Test-CodexQuotaMonitorHealth`, `Uninstall-CodexQuotaMonitor`, `Invoke-CodexQuotaMonitorRuntime`, and `Start-CodexQuotaMonitor.ps1`. Every path lookup must call:

```powershell
$paths = Get-MonitorPaths `
    -LocalAppData $LocalAppData `
    -Startup $Startup `
    -ProgramRoot $ProgramRoot
```

The runtime startup callback must pin the host that is already running the application:

```powershell
& $startupPreferenceFunction `
    -Enabled $Enabled `
    -Paths $paths `
    -RuntimeScriptPath (Join-Path $PSScriptRoot 'Start-CodexQuotaMonitor.ps1') `
    -PwshPath (Join-Path $PSHOME 'pwsh.exe') `
    -LauncherScript (Join-Path $paths.App 'Start-CodexQuotaMonitor.vbs')
```

Pass `-ProgramRoot $paths.ProgramRoot` in `New-MonitorRuntimeStartInfo` so subsequent launches resolve the packaged app and mutable data consistently.

- [ ] **Step 4: Make staging live under the program root**

Change application staging and backup paths from `$Paths.Root` to `$Paths.ProgramRoot`, and validate removals against that exact root:

```powershell
$stagePath = Join-Path $Paths.ProgramRoot 'app.new'
$backupPath = Join-Path $Paths.ProgramRoot 'app.old'
$failedPath = Join-Path $Paths.ProgramRoot 'app.failed'
```

Keep settings, health, logs, and relay state under `$Paths.Root`.

- [ ] **Step 5: Add post-health legacy cleanup**

After successful startup/status creation and before completing the publish, remove `$paths.LegacyApp` only when it differs from `$paths.App` and lies within `$paths.Root`:

```powershell
if (-not $paths.LegacyApp.Equals($paths.App, [StringComparison]::OrdinalIgnoreCase) -and
    (Test-Path -LiteralPath $paths.LegacyApp -PathType Container)) {
    Remove-MonitorManagedItem -Path $paths.LegacyApp -Root $paths.Root
}
```

Do not perform this cleanup on `-SkipStart`; package installation must prove ordinary health first.

- [ ] **Step 6: Run lifecycle and runtime tests**

Run `pwsh -NoLogo -NoProfile -NonInteractive -File build/Test.ps1 -Suite Integration`.

Expected: all integration tests pass.

- [ ] **Step 7: Commit Task 2 files only**

```powershell
git add companion/Private/Installation.ps1 companion/CodexQuotaMonitor.psm1 companion/Start-CodexQuotaMonitor.ps1 tests/Integration/Installation.Tests.ps1 tests/Integration/MonitorRuntime.Tests.ps1
git commit -m "feat: support packaged monitor lifecycle"
```

### Task 3: Add shortcut icon and package support scripts

**Files:**
- Modify: `companion/Private/StartupShortcut.ps1`
- Modify: `tests/Integration/StartupShortcut.Tests.ps1`
- Create: `installer/scripts/Install-Package.ps1`
- Create: `installer/scripts/Prepare-Uninstall.ps1`
- Create: `tests/Integration/InstallerSupportScripts.Tests.ps1`

- [ ] **Step 1: Add failing shortcut and support-script tests**

Add `IconPath` assertions to the real shortcut reader and test:

```powershell
$created = New-MonitorStartupShortcut `
    -ShortcutPath $shortcutPath `
    -EntryScript $firstEntry `
    -PwshPath $pwshPath `
    -IconPath $iconPath

(Read-TestShortcut $shortcutPath).IconLocation |
    Should -BeExactly ([IO.Path]::GetFullPath($iconPath) + ',0')
```

Create integration tests that invoke package scripts against `$TestDrive`, require sanitized JSON output, and verify that no provider JSON, credential field, raw response, or log content is emitted.

- [ ] **Step 2: Run focused integration tests and observe failure**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File build/Test.ps1 -Suite Integration
```

Expected: missing `IconPath` and missing package scripts.

- [ ] **Step 3: Implement `IconPath`**

Add an optional absolute file parameter, validate it, set `$shortcut.IconLocation = "$fullIconPath,0"`, and return `IconPath` in the result. Existing callers without an icon retain current behavior.

- [ ] **Step 4: Implement package installation support**

`Install-Package.ps1` accepts exact roots and invokes the candidate module:

```powershell
param(
    [Parameter(Mandatory)][string]$ProgramRoot,
    [Parameter(Mandatory)][string]$LocalAppData,
    [Parameter(Mandatory)][string]$Startup,
    [Parameter(Mandatory)][string]$PwshPath,
    [switch]$SkipStart
)

$payload = Join-Path $ProgramRoot 'payload'
$manifest = Join-Path $payload 'CodexQuotaMonitor.psd1'
$module = Import-Module $manifest -Force -PassThru
try {
    $result = Install-CodexQuotaMonitor `
        -SourcePath $payload `
        -ProgramRoot $ProgramRoot `
        -LocalAppData $LocalAppData `
        -Startup $Startup `
        -PwshPath $PwshPath `
        -InstancePrefix 'Local\CodexQuotaMonitor' `
        -SkipStart:$SkipStart
    $result | Select-Object Operation,Installed,Running,Status,Reason,AppPath,LastErrorCategory |
        ConvertTo-Json -Compress
}
finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
}
```

The final implementation must exit nonzero on exceptions and print only the sanitized projection.

- [ ] **Step 5: Implement uninstall preparation**

`Prepare-Uninstall.ps1` imports the active installed module, stops the monitor, removes startup state through `Uninstall-CodexQuotaMonitor -PreserveProgramFiles`, and passes `-PreserveData` according to the Inno prompt. Add the hidden public switch so Inno remains responsible for program-file deletion.

- [ ] **Step 6: Run integration tests**

Run `pwsh -NoLogo -NoProfile -NonInteractive -File build/Test.ps1 -Suite Integration`.

Expected: all integration tests pass.

- [ ] **Step 7: Commit Task 3 files only**

```powershell
git add companion/Private/StartupShortcut.ps1 companion/Private/Installation.ps1 tests/Integration/StartupShortcut.Tests.ps1 installer/scripts tests/Integration/InstallerSupportScripts.Tests.ps1
git commit -m "feat: add installer lifecycle support"
```

### Task 4: Lock and acquire the private PowerShell runtime

**Files:**
- Create: `installer/runtime-lock.json`
- Create: `build/Acquire-PowerShellRuntime.ps1`
- Create: `tests/Unit/InstallerRuntime.Tests.ps1`

- [ ] **Step 1: Write failing runtime-lock tests**

Test exact stable fields and reject lowercase/invalid hashes:

```powershell
$lock = Get-Content installer/runtime-lock.json -Raw | ConvertFrom-Json
$lock.Version | Should -BeExactly '7.6.4'
$lock.Architecture | Should -BeExactly 'x64'
$lock.ArchiveSha256 | Should -BeExactly '80832551C52809301E6071C8BAC977BEB5A2F1EC953EB4DB9F94DEB953333793'
$lock.AssetUrl | Should -BeExactly 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.4/PowerShell-7.6.4-win-x64.zip'
```

- [ ] **Step 2: Run unit tests and observe failure**

Run `pwsh -NoLogo -NoProfile -NonInteractive -File build/Test.ps1 -Suite Unit`.

Expected: missing lock/acquisition files.

- [ ] **Step 3: Create the runtime lock**

Use:

```json
{
  "SchemaVersion": 1,
  "Version": "7.6.4",
  "Architecture": "x64",
  "ArchiveName": "PowerShell-7.6.4-win-x64.zip",
  "AssetUrl": "https://github.com/PowerShell/PowerShell/releases/download/v7.6.4/PowerShell-7.6.4-win-x64.zip",
  "ArchiveSha256": "80832551C52809301E6071C8BAC977BEB5A2F1EC953EB4DB9F94DEB953333793",
  "LicenseFile": "LICENSE.txt"
}
```

- [ ] **Step 4: Implement acquisition and verification**

The script accepts `-LockPath`, `-CacheRoot`, and `-Destination`, downloads only when the cache is missing, validates SHA-256 before extraction, recreates the destination, verifies `pwsh.exe`, and asserts its output equals `7.6.4` and process architecture equals `X64`. It returns a single object with `Version`, `ArchivePath`, `RuntimeRoot`, and `PwshPath`.

- [ ] **Step 5: Run runtime tests**

Run the unit suite, then invoke the acquisition script once against `outputs/cache/powershell` and `outputs/staging/runtime/pwsh`.

Expected: exact archive hash and exact `7.6.4` runtime output.

- [ ] **Step 6: Commit Task 4 files only**

```powershell
git add installer/runtime-lock.json build/Acquire-PowerShellRuntime.ps1 tests/Unit/InstallerRuntime.Tests.ps1
git commit -m "build: lock bundled PowerShell runtime"
```

### Task 5: Build an allowlisted installer payload

**Files:**
- Create: `build/New-InstallerPayload.ps1`
- Create: `tests/Integration/InstallerPayload.Tests.ps1`

- [ ] **Step 1: Write failing payload tests**

Require only `companion`, selected icons, package scripts, licenses, and generated metadata. Assert absence of `.git`, `.superpowers`, `tests`, `outputs`, `work`, `settings.json`, `health.json`, `relay-providers.json`, `relay-cache.json`, `*.log`, and absolute build-machine paths.

- [ ] **Step 2: Run integration tests and observe failure**

Run the integration suite. Expected: `New-InstallerPayload.ps1` is missing.

- [ ] **Step 3: Implement allowlisted staging**

The script recreates a caller-supplied staging root and copies:

```text
companion/* -> payload/*
assets/codex-quota-monitor-white-blue.ico -> assets/CodexQuotaMonitor.ico
installer/scripts/* -> installer/*
PowerShell runtime -> runtime/pwsh/*
PowerShell LICENSE.txt -> licenses/PowerShell-LICENSE.txt
```

It verifies the relay host, writes `installer-manifest.json`, scans file names and text files for forbidden state names and the repository absolute path, and returns the staging paths.

- [ ] **Step 4: Run payload tests**

Run the integration suite. Expected: payload allowlist and secret-exclusion assertions pass.

- [ ] **Step 5: Commit Task 5 files only**

```powershell
git add build/New-InstallerPayload.ps1 tests/Integration/InstallerPayload.Tests.ps1
git commit -m "build: stage safe installer payload"
```

### Task 6: Add the Inno Setup product definition

**Files:**
- Create: `installer/CodexQuotaMonitor.iss`
- Create: `tests/Unit/InnoInstallerContract.Tests.ps1`

- [ ] **Step 1: Write failing Inno contract tests**

Require a stable AppId, `PrivilegesRequired=lowest`, x64 architecture, `{localappdata}\Programs\CodexQuotaMonitor`, no admin overrides, explicit WScript shortcuts, pre-copy shutdown, post-install helper execution, and uninstall data prompt.

- [ ] **Step 2: Run unit tests and observe failure**

Run the unit suite. Expected: missing `.iss` file.

- [ ] **Step 3: Implement the Inno definition**

Use preprocessor inputs for source staging root, output directory, app version, numeric version, and output base name. Core setup values are:

```ini
[Setup]
AppId={{7B0B5FCB-62F5-4D3C-AF28-0EE1CA930D47}
AppName=Codex Quota Monitor
DefaultDirName={localappdata}\Programs\CodexQuotaMonitor
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=none
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\assets\CodexQuotaMonitor.ico
Compression=lzma2/ultra64
SolidCompression=yes
```

`PrepareToInstall` stops an existing packaged instance with its existing private runtime before `[Files]` replacement. For a legacy installation it uses a validated system `pwsh.exe` and the legacy stop script. Failure to stop returns a blocking wizard error.

`CurStepChanged(ssPostInstall)` executes the newly installed private runtime and `installer\Install-Package.ps1`; a nonzero exit raises an installation exception so Inno rolls back installed files.

Create Start-menu and optional desktop shortcuts targeting `{sys}\wscript.exe` with `//B //NoLogo`, installed launcher, private runtime, installed entry script, `-ProgramRoot`, and the application icon.

On uninstall, ask whether to retain data, invoke `Prepare-Uninstall.ps1`, and abort file deletion when graceful shutdown fails.

- [ ] **Step 4: Run contract tests**

Run the unit suite. Expected: all Inno contract assertions pass.

- [ ] **Step 5: Commit Task 6 files only**

```powershell
git add installer/CodexQuotaMonitor.iss tests/Unit/InnoInstallerContract.Tests.ps1
git commit -m "feat: define per-user Windows installer"
```

### Task 7: Add the installer build and test entry points

**Files:**
- Create: `build/Build-WindowsInstaller.ps1`
- Create: `build/Test-WindowsInstaller.ps1`
- Modify: `build/Test.ps1`
- Create: `tests/Integration/InstallerBuild.Tests.ps1`

- [ ] **Step 1: Write failing build-contract tests**

Test version normalization from `.codex-plugin/plugin.json`, dirty-worktree manifest labeling, exact output names, setup SHA file format, missing `ISCC.exe` error, and release-mode dirty-tree rejection.

- [ ] **Step 2: Run tests and observe failure**

Run unit and integration suites. Expected: missing build entry points and unsupported `Installer` suite.

- [ ] **Step 3: Implement the build entry point**

`Build-WindowsInstaller.ps1` accepts `-Configuration Development|Release`, optional `-IsccPath`, `-SkipApplicationTests`, and `-SkipRustTests`. It:

1. resolves repository paths;
2. reads and normalizes the plugin version;
3. marks Git commit/dirty state and rejects dirty release builds;
4. acquires PowerShell 7.6.4;
5. runs the full PowerShell suite with the staged private runtime;
6. runs Rust/package verification unless explicitly skipped;
7. creates the allowlisted staging tree;
8. resolves `ISCC.exe` from the explicit path, PATH, and standard per-user/program-files locations;
9. invokes `ISCC.exe` with preprocessor defines;
10. verifies output, writes uppercase SHA-256 plus newline, and writes `manifest.json`.

- [ ] **Step 4: Implement installer validation and suite routing**

Add `Installer` to `build/Test.ps1` and route it to installer-specific Pester files plus `build/Test-WindowsInstaller.ps1`. The latter validates sources without requiring a compiled artifact unless `-SetupPath` is provided.

- [ ] **Step 5: Run installer tests**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File build/Test.ps1 -Suite Installer
```

Expected: installer source/build contract passes.

- [ ] **Step 6: Commit Task 7 files only**

```powershell
git add build/Build-WindowsInstaller.ps1 build/Test-WindowsInstaller.ps1 build/Test.ps1 tests/Integration/InstallerBuild.Tests.ps1
git commit -m "build: add Windows installer pipeline"
```

### Task 8: Document distribution and licenses

**Files:**
- Create: `installer/README.md`
- Modify: `README.md`
- Modify: `tests/Unit/Documentation.Tests.ps1`

- [ ] **Step 1: Add failing documentation assertions**

Require the exact setup naming pattern, Windows 11 x64, private PowerShell 7.6.4, no administrator requirement, SmartScreen warning, Codex prerequisite, upgrade behavior, retained-data uninstall option, build command, and output paths.

- [ ] **Step 2: Run unit tests and observe failure**

Run the unit suite. Expected: missing installer documentation phrases.

- [ ] **Step 3: Write documentation**

Document the user command-free installation flow and the developer build command:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\build\Build-WindowsInstaller.ps1 -Configuration Development
```

Explain that unsigned builds may show `Unknown publisher`, that the installer contains no local credentials, and that live quota depends on the recipient's own Codex sign-in.

- [ ] **Step 4: Run unit tests**

Run the unit suite. Expected: documentation contract passes.

- [ ] **Step 5: Commit Task 8 files only**

```powershell
git add installer/README.md README.md tests/Unit/Documentation.Tests.ps1
git commit -m "docs: explain Windows installer distribution"
```

### Task 9: Compile and verify the real setup artifact

**Files:**
- Generated: `outputs/installer/CodexQuotaMonitor-Setup-<version>-x64.exe`
- Generated: `outputs/installer/CodexQuotaMonitor-Setup-<version>-x64.exe.sha256`
- Generated: `outputs/installer/manifest.json`
- Update if required: implementation and tests from Tasks 1-8

- [ ] **Step 1: Install or locate Inno Setup 6 for the current user**

Resolve `ISCC.exe`; when absent, install the official Inno Setup package with `winget install --id JRSoftware.InnoSetup --scope user --accept-package-agreements --accept-source-agreements`, then resolve `ISCC.exe` again. Do not add Inno Setup to the application payload.

- [ ] **Step 2: Run deterministic gates**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File build/Test.ps1 -Suite All
pwsh -NoLogo -NoProfile -NonInteractive -File build/Test.ps1 -Suite Installer
pwsh -NoLogo -NoProfile -NonInteractive -File build/Verify-PackagedRelayHost.ps1
cargo fmt --manifest-path sidecar/relay-quota-host/Cargo.toml -- --check
cargo clippy --manifest-path sidecar/relay-quota-host/Cargo.toml --all-targets --locked -- -D warnings
cargo test --manifest-path sidecar/relay-quota-host/Cargo.toml --locked
git diff --check
```

Expected: every command exits zero. Pre-existing user modifications remain present but are not staged by installer commits.

- [ ] **Step 3: Build the development setup**

Run:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File build/Build-WindowsInstaller.ps1 -Configuration Development
```

Expected: setup, SHA-256, and manifest appear under `outputs/installer`; manifest records `SigningStatus=Unsigned` and the correct dirty-worktree flag.

- [ ] **Step 4: Perform desktop installation acceptance**

Run the setup interactively in the normal Windows desktop session. Verify no UAC, no terminal window, Start-menu and desktop shortcuts, tray/window appearance, ordinary health, one instance, private runtime path, startup shortcut path, and legacy data preservation.

- [ ] **Step 5: Perform upgrade and uninstall acceptance**

Install the same build again to exercise idempotent upgrade, verify settings/provider bytes remain unchanged, then test uninstall once with retained data and once with complete data removal. Reinstall the monitor at the end only if the user wants it to remain installed.

- [ ] **Step 6: Run final artifact verification**

Run `build/Test-WindowsInstaller.ps1 -SetupPath <absolute setup path>` and independently compare the executable hash with the `.sha256` and `manifest.json` values.

- [ ] **Step 7: Commit final source corrections only**

Do not commit generated `outputs`. Stage only installer-related source, tests, and documentation corrections, then commit:

```powershell
git commit -m "build: verify distributable Windows setup"
```

## Final handoff

Report:

- the absolute setup path;
- setup size and uppercase SHA-256;
- application and bundled PowerShell versions;
- signing status and SmartScreen expectation;
- automated test totals and Rust gate results;
- desktop install/upgrade/uninstall acceptance results;
- any pre-existing dirty worktree files left untouched.
