# Windows 10 compatibility — 2026-10-11

The C# branch supports Windows 10 x64 version 2004 / build 19041 and later, including 22H2 / build 19045, and Windows 11 x64. The desktop launch guard matches the installer's existing `MinVersion=10.0.19041`. Self-contained distributions include .NET 8; recipients do not need a separate .NET installation.

The executable embeds the Windows 10/11 supported-OS identifier, requests ordinary user privileges, and declares PerMonitorV2 DPI awareness with a PerMonitor fallback. The tray, DPAPI and window placement use APIs available on the supported Windows 10 builds.

Blur is optional. Missing composition functions, disabled system transparency, high contrast and software rendering select an opaque background and remove shadows. Switching back to an available transparent theme restores the original shadow. This fallback applies to Full, CompactBar and Orb.

Validation: 44 C# behavioral checks passed, including build boundaries, failed native blur calls and the actual executable's embedded manifest. The 27 existing installer/runtime/theme regression checks passed. The self-contained executable passed 20 UI captures, including all three modes in both themes with forced opaque surfaces. Generated output: `outputs/desktop/win10-compatible`; its distribution manifest records minimum Windows version and supported systems.

The validation host is Windows 11 x64 (build 26300). Version-boundary and rendering-fallback tests simulate Windows 10 conditions; an actual Windows 10 machine or VM has not yet been used. The installed deployment was not replaced.
