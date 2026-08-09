# Quota monitor visual matrix

Run from the repository root in PowerShell 7 on Windows:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\tests\Visual\Capture-QuotaMonitorMatrix.ps1
```

The harness uses only synthetic official and relay presentation rows. It captures:

- Full Overview and Full Tabs;
- CompactBar;
- Orb;
- Light and Dark themes;
- 100% and 150% scale.

The sixteen PNGs are written to the ignored `outputs/visual` directory. Review each image for:

- transparent cohesive surfaces without an opaque white header or hard white root border;
- continuous progress fills without decorative white segmentation;
- dark mode title/body consistency and readable light-mode contrast;
- visible close controls and no clipped metric text;
- correct layout at both scale factors.
