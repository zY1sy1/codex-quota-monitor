# Codex Quota Monitor Windows Installer Design

**Date:** 2026-08-14  
**Status:** Approved for implementation  
**Target:** Windows 11 x64, current-user installation

## 1. Goal

Produce a standard Windows installer named `CodexQuotaMonitor-Setup-<version>-x64.exe` that can be shared with another Windows user. The recipient installs the monitor through a normal wizard and does not need to install PowerShell, Rust, Cargo, or the Codex plugin bundle separately.

Codex itself remains an external prerequisite. Each user signs in to Codex with their own account and enters their own relay credentials. The installer must never package local credentials, account state, settings, cache, or logs from the build machine.

## 2. Selected approach

Use Inno Setup to build a per-user installer containing:

- the Codex Quota Monitor application files;
- the existing console-free VBScript launcher;
- the packaged `relay-quota-host.exe` and its SHA-256 manifest;
- a pinned portable PowerShell 7.6 LTS x64 runtime;
- application icons, presets, licenses, and third-party notices;
- install, migration, health-check, and uninstall support scripts.

The private PowerShell runtime is an application component, not a system installation. It is not added to `PATH`, registered as a shell, or used to modify an existing PowerShell installation. All installed shortcuts explicitly target the private runtime through the existing `wscript.exe` launcher path.

Inno Setup is preferred over MSIX because the current application is a desktop PowerShell/WPF companion with mutable per-user state and an existing launcher/startup model. A native C# rewrite is outside this project because it would replace the application architecture rather than add a distribution layer.

## 3. Installation scope and directory layout

The installer uses current-user scope and must not request elevation. The default program directory is:

```text
%LOCALAPPDATA%\Programs\CodexQuotaMonitor
```

Its installed layout is:

```text
CodexQuotaMonitor\
├─ app\
│  ├─ CodexQuotaMonitor.psd1
│  ├─ CodexQuotaMonitor.psm1
│  ├─ Start-CodexQuotaMonitor.ps1
│  ├─ Start-CodexQuotaMonitor.vbs
│  ├─ Bin\
│  ├─ Private\
│  ├─ Presets\
│  ├─ ThirdPartyNotices.txt
│  └─ UI\
├─ runtime\
│  └─ pwsh\
├─ assets\
├─ licenses\
└─ installer-manifest.json
```

Mutable data remains under the existing root:

```text
%LOCALAPPDATA%\CodexQuotaMonitor\data
%LOCALAPPDATA%\CodexQuotaMonitor\logs
```

This preserves current-user DPAPI compatibility and separates replaceable program files from user-owned state. The path model must therefore distinguish program root, data root, logs, shortcuts, and startup entry instead of assuming that `app`, `data`, and `logs` share one parent.

Repository-based developer installation remains supported. The existing thin scripts continue to work from a repository or plugin root with a system PowerShell 7.4 or later. Packaged installation supplies an explicit program root and explicit private `pwsh.exe` path without breaking the development route.

## 4. Runtime policy

The installer build locks one specific PowerShell 7.6 LTS x64 portable release in `installer/runtime-lock.json`. The lock contains the version, official asset URL, expected archive SHA-256, architecture, archive file name, and license metadata.

The build must:

1. obtain the locked archive into a reusable build cache;
2. reject any archive whose SHA-256 differs from the lock;
3. extract it into a clean staging directory;
4. run the staged `pwsh.exe` and verify the exact locked version and x64 architecture;
5. run application verification with that runtime before compiling the installer.

The end-user installer is offline with respect to PowerShell. It never downloads a runtime during installation.

The application always uses its private runtime by default, even when a compatible system `pwsh.exe` exists. This gives every recipient the tested runtime and prevents system upgrades or downgrades from changing application behavior. An existing system PowerShell is neither inspected nor modified except where legacy-install migration needs to locate and stop an already running old installation.

Internal launches use a process-scoped invocation with `-NoLogo`, `-NoProfile`, `-NonInteractive`, `-Sta`, and hidden-window behavior. The installer and application must not change machine-level or user-level PowerShell execution-policy settings.

## 5. User experience

The setup wizard provides:

- product name, version, publisher text, and application icon;
- the per-user destination directory;
- an option to create a desktop shortcut, enabled by default;
- an option to enable startup monitoring, enabled by default unless a preserved setting says otherwise;
- an option to launch the monitor after installation, enabled by default;
- a non-blocking Codex availability result;
- a final success or actionable failure message.

The Start menu contains:

- `Codex 额度监控`;
- `卸载 Codex 额度监控`.

Application and startup shortcuts launch `%WINDIR%\System32\wscript.exe` with the installed VBScript launcher, the private `pwsh.exe`, and the installed entry script as explicit absolute arguments. The shortcut uses the existing white-blue application icon. Starting the monitor must not create a PowerShell, Command Prompt, Windows Terminal, or OpenConsole window.

The Add/Remove Programs entry uses a stable Inno Setup `AppId`, allowing a newer installer to upgrade the same product rather than create a second product entry.

## 6. Codex and account handling

Setup checks whether Codex can be located through the same supported discovery paths used by the application. Missing Codex produces a clear warning and an instruction to install and sign in to Codex, but it does not prevent application installation.

Installation success and quota availability remain separate:

- a healthy process with `AuthRequired` is a successful installation;
- API-key-only or Bedrock state may produce `Unavailable` without making installation fail;
- live ChatGPT quota is verified only when the user is signed in with a supported ChatGPT account;
- missing or temporarily unavailable quota data never becomes a fabricated zero.

No account login flow is embedded in setup. The monitor continues to reuse the locally installed Codex App Server and the user's Codex login state.

## 7. Fresh install, legacy migration, and upgrade

### 7.1 Fresh install

The installer:

1. validates Windows 11 x64, writable destination, required disk space, and payload integrity;
2. installs program files and the private runtime;
3. creates Start menu, optional desktop, and configured startup shortcuts;
4. launches the monitor when selected;
5. waits for ordinary health and reports process health separately from account state.

### 7.2 Legacy migration

A legacy script installation may have program files under:

```text
%LOCALAPPDATA%\CodexQuotaMonitor\app
```

When found, setup must:

1. request normal shutdown through the existing instance-control mechanism;
2. wait for bounded process exit;
3. preserve `data` and `logs` in place;
4. install the new program root and private runtime;
5. replace the startup shortcut so it targets the private runtime;
6. start and health-check the new installation;
7. remove the legacy `app` directory only after the new process reaches valid ordinary health.

If migration cannot stop the existing process or cannot validate the new installed layout, setup aborts with the legacy installation and user data intact.

### 7.3 Upgrade

Running a newer setup over an installed setup is the supported update mechanism. Upgrade must:

- preserve all data, logs, DPAPI-encrypted relay configuration, cache, and user appearance settings;
- request normal exit before replacing files;
- stage and validate the complete candidate payload;
- preserve or restore the previous program files if deterministic replacement or integrity validation fails;
- create only one running monitor instance after completion.

`AuthRequired`, `Unavailable`, or zero returned quota windows are not rollback conditions. Missing files, hash mismatch, invalid runtime, invalid installed layout, or inability to launch the monitor are installation failures.

Automatic network update is explicitly excluded from the first installer release.

## 8. Uninstall behavior

Uninstall must first request normal monitor shutdown and remove:

- program files;
- the private PowerShell runtime;
- Start menu shortcuts;
- desktop shortcuts created by setup;
- the current-user startup shortcut;
- the Add/Remove Programs entry.

The uninstaller asks whether the user wants to retain personal settings and logs for a future reinstall. Retention is the default to avoid accidental data loss. Choosing complete removal deletes `%LOCALAPPDATA%\CodexQuotaMonitor\data` and `%LOCALAPPDATA%\CodexQuotaMonitor\logs`, including DPAPI-encrypted relay credentials.

Uninstall must never remove Codex, system PowerShell, PATH entries, unrelated startup entries, or files outside the exact program and data roots.

## 9. Build system and artifacts

Add the following source structure:

```text
installer\
├─ CodexQuotaMonitor.iss
├─ runtime-lock.json
└─ README.md

build\
├─ Acquire-PowerShellRuntime.ps1
├─ Build-WindowsInstaller.ps1
└─ Test-WindowsInstaller.ps1
```

`Build-WindowsInstaller.ps1` is the single supported build entry point. It performs preflight checks, assembles a clean staging tree, validates the staged payload, invokes Inno Setup's command-line compiler, validates the compiled executable, and generates distribution metadata.

The output directory is:

```text
outputs\installer\
├─ CodexQuotaMonitor-Setup-<version>-x64.exe
├─ CodexQuotaMonitor-Setup-<version>-x64.exe.sha256
└─ manifest.json
```

`manifest.json` records the application version, Git commit when available, dirty-worktree indicator, build time, Windows architecture, PowerShell version, relay-host SHA-256, setup SHA-256, and signing status. A dirty working tree may produce a development installer, but the manifest must label it. A release build mode rejects a dirty working tree.

The application version is derived from `.codex-plugin/plugin.json`. Inno Setup display version, executable version metadata, output file name, and distribution manifest use the same normalized version. Build metadata that cannot be represented in Windows numeric file-version fields is retained in the display version and manifest while numeric fields use the compatible core version plus a generated build component.

## 10. Integrity, privacy, and licensing

Build and install validation cover:

- the locked PowerShell archive and extracted runtime;
- `relay-quota-host.exe` against `relay-quota-host.sha256`;
- required module, launcher, UI, preset, and notice files;
- the final setup executable SHA-256.

Staging uses an explicit allowlist. It excludes repository metadata, worktrees, build caches, test fixtures, visual captures, health files, logs, settings, relay provider files, cache data, credentials, and machine-specific absolute paths.

The installer includes PowerShell's license and the application's existing third-party notices. Inno Setup is a build-time tool and is not installed on the recipient's machine.

Version one may be unsigned. The build script includes an optional signing stage that is inactive when no signing configuration is supplied. Unsigned output is labeled in `manifest.json`; the documentation explains the possible Windows SmartScreen `Unknown publisher` flow. No certificate or signing secret is committed to the repository.

## 11. Error handling and rollback

The installer uses bounded waits and sanitized user-facing errors. It must not print raw App Server messages, decrypted relay configuration, HTTP responses, headers, tokens, cookies, or full runtime logs.

Failure handling follows these rules:

- build-time dependency or hash failure: do not produce a distributable setup;
- unsupported architecture or unwritable destination: stop before modifying an installation;
- existing monitor cannot exit: abort replacement and leave the old installation intact;
- candidate payload invalid: abort before switching shortcuts;
- post-install process launch failure: restore the previous program files on upgrade;
- valid process with non-live account state: keep the installation and report the account category;
- uninstall shutdown failure: stop and report the blocker rather than deleting files used by a live process.

Installer diagnostic messages may point to the monitor's logs directory, but they do not embed or dump complete logs into setup output.

## 12. Verification and acceptance

Automated verification must cover:

1. the existing PowerShell test suite under the repository-supported runtime;
2. the existing Rust format, lint, and test gates when Rust is available;
3. relay-host packaged hash and self-test;
4. full PowerShell tests under the staged private PowerShell 7.6 LTS runtime;
5. installer source validation and compilation;
6. setup metadata, output naming, manifest, and final SHA-256;
7. payload allowlist and absence of credential-bearing or machine-state files;
8. path resolution for packaged and repository installations;
9. shortcut arguments targeting the private runtime;
10. legacy path migration and preserved settings;
11. upgrade replacement and rollback behavior;
12. uninstall with both retained and deleted user data.

Desktop acceptance on Windows 11 x64 must demonstrate:

- installation completes without UAC;
- no system `pwsh` prerequisite is required;
- an existing system PowerShell remains unchanged;
- no console window appears during launch or startup;
- the floating window and tray icon appear;
- only one monitor instance runs;
- ordinary health becomes valid;
- signed-out Codex reports `AuthRequired` without installation rollback;
- startup launches through the private runtime after sign-in or reboot simulation;
- an upgrade preserves settings and encrypted relay configuration;
- uninstall removes program files and shortcuts;
- the retain-data and complete-removal choices behave exactly as described.

Live quota and real relay-provider validation remain manual credential-bearing checks and must follow the existing privacy constraints.

## 13. Deliverables

Implementation is complete only when the repository contains the installer sources and build scripts, automated verification passes, desktop acceptance is recorded, and a locally built setup artifact exists with its SHA-256 and manifest.

Publishing to GitHub, creating a GitHub Release, purchasing a certificate, or distributing the setup to third parties is outside this implementation unless separately authorized.
