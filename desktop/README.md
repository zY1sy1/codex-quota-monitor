# C# desktop runtime

Supported systems: Windows 10 x64, version 2004 / build 19041 or later (including 22H2), and Windows 11 x64. The executable declares Windows 10 compatibility and per-monitor DPI awareness, checks the same minimum build as the installer, and includes .NET 8 in the self-contained distribution. Blur is optional: software rendering, disabled transparency, high contrast or an unavailable composition API use an opaque surface without a shadow. No Windows 11-only Mica or window-corner API is required.

`CodexQuotaMonitor.Core` contains settings and provider compatibility, quota normalization, presentation, daily wallet consumption and bounded JSONL transport. `CodexQuotaMonitor.Desktop` owns the WPF views, native Windows tray, single-instance events, DPAPI, scheduling and lifecycle. It reuses `companion/UI/*.xaml`, the existing Rust relay host and the original data filenames. `CodexQuotaMonitor.Tests` runs behavioral checks without additional test-framework packages.

Build from the canonical Git root with .NET SDK 8 or newer:

```powershell
pwsh -NoProfile -File .\build\Build-Desktop.ps1
pwsh -NoProfile -File .\build\Test-Desktop.ps1
pwsh -NoProfile -File .\build\Measure-DesktopMemory.ps1
pwsh -NoProfile -File .\scripts\Start-DesktopPreview.ps1 -Demo
```

`Build-Desktop.ps1` publishes a self-contained Windows x64 executable into `companion/Desktop` by default. That directory is generated and ignored by Git; the install and installer scripts copy it into their payload. Use `-Destination` to choose another staging directory, or `-FrameworkDependent` for development on a machine with .NET Desktop Runtime 8. The SDK is needed only for development. The installed shortcuts and runtime starter choose the compiled executable, while the legacy script remains available with `-Legacy` for comparisons.

Run the compiled executable directly:

```powershell
.\companion\Desktop\CodexQuotaMonitor.exe --data-root D:\path\to\isolated-state --instance-prefix 'Local\CodexQuotaMonitor.Preview' --demo
```

Omit `--demo` to read official quota through the installed Codex App Server. Optional flags include `--mode Full|CompactBar|Orb`, `--theme Dark|Light`, `--codex <executable>`, repeated `--codex-argument <argument>`, `--cc-switch-db <path>`, `--headless`, `--run-for-seconds <seconds>`, and `--exit`. Demo and smoke-test runs require a separate data directory. `--smoke-test <output-directory>` exercises the views, writes PNG previews and produces `smoke-result.json`.

The executable does not host PowerShell, load WinForms, compile scripts or force garbage collection to alter memory figures. Quota requests and extractors run in the existing Rust sidecar. Its binaries are verified against the packaged SHA-256 before normal query startup. Credentials use the same current-user DPAPI/base64 format as the script version. Process stderr and raw protocol payloads are never written to logs; failures retain a fixed, safe error category.

Only the active quota mode is instantiated. Settings, relay management and import windows are created when opened and released when closed. Quota cards are retained by stable row keys and countdowns update existing controls. JSONL records are bounded before parsing, pending requests are removed on response, cancellation or timeout, and shutting down kills only child processes owned by this runtime. Named mutex and activate/exit events interoperate with the existing maintenance scripts.

When enabled in settings, daily USD wallet spending appears as a short line beneath the balance on the same card. It does not create another card or focus metric; an existing focus on the removed daily-spending card moves to its wallet. Daily spending remains an estimate based on the day's peak balance minus the latest balance.

Data formats: settings schema 1/2/3, relay providers schema 1/2, cache and daily spending schema 1. Older relay scripts retain their full Custom rules during migration. CC Switch is read by the existing inspector; unsafe or dynamic rules require an explicit Custom choice, and imported drafts must pass a test before saving. If settings or provider files are invalid, their original contents are preserved and the C# runtime refuses to overwrite them.

Short memory comparisons use two equivalent official quota windows, the full dark UI, the same fake App Server and a 30-second warmup. Compare the private working set and private committed bytes; total working sets include shared framework and driver pages. These short runs do not establish day-long stability or cover all GPU and mixed-DPI configurations.
