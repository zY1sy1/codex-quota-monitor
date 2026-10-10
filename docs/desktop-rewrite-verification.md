# C# desktop migration verification — 2026-10-10

Branch: `feat/csharp-wpf-runtime`. Implementation and launch instructions: `desktop/README.md`.

The compiled C# + WPF runtime replaces the resident PowerShell host, reuses the existing XAML and Rust query/CC Switch inspection binaries, and uses a native Windows tray without loading WinForms. The original scripts remain for maintenance and explicit `-Legacy` comparisons. Repository and installer launchers choose the compiled executable when available. The self-contained x64 build includes its .NET runtime and license notices.

Validation performed:

- 34 new behavioral checks passed: quota fixtures and unknown/zero amounts; settings schema 1/2/3; existing DPAPI format; destination validation; provider migration; conservative Generic/Custom conversion; import fingerprints; failure retention; manual scheduling and backoff; wallet-only daily spending; bounded output and request cleanup; a real Rust host/extractor against an isolated loopback fixture; native account eligibility; single-instance activation and exit.
- Existing PowerShell unit suite: 568 passed, 1 existing skip. Existing integration suite: 300 passed.
- Three successive native startup/exit regression runs passed after startup was dispatched on the WPF UI context.
- Published executable smoke checks passed for Full, CompactBar and Orb in both themes, all settings pages, relay management, mode release, focused metrics, full-window tabs and closing/restoring through the tray. Fourteen rendered previews were reviewed. The smoke check rejects loading PowerShell or WinForms in the resident process.
- The native process read the real local Codex App Server, reported `Live` with two official windows, and its health file was accepted by the existing PowerShell health reader. The probe used isolated state and did not replace the installed app.

Memory was measured with the same fake App Server and two official quota windows, full dark UI, no relay providers, a 30-second warmup, and no forced GC or working-set trimming. Native health additionally confirmed that two quota cards were rendered.

| Main process | Private working set | Total working set | Private committed |
| --- | ---: | ---: | ---: |
| C# + WPF | 64.1 MiB | 147.6 MiB | 83.5 MiB |
| PowerShell + WPF | 155.9 MiB | 302.5 MiB | 178.7 MiB |

Private working set decreased by approximately 59%. Shared framework/driver pages affect total working sets; this comparison concerns the main UI process, with equivalent fixture children outside the totals. Another run measured 63.7 versus 147.4 MiB. These short checks do not establish day-long memory stability or exhaustively validate every monitor/DPI/GPU setup.

Generated executables, SDK, test state, memory JSON and PNG previews are under ignored build/output directories. The installed deployment and the separate `relay-quota-monitor` repository were not modified.
