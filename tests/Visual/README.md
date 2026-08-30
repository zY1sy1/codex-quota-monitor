# Quota monitor visual matrix

Run from the repository root in PowerShell 7 on Windows:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\tests\Visual\Capture-QuotaMonitorMatrix.ps1
```

The harness uses only synthetic official and relay presentation rows. It captures 44 PNGs covering:

- Full Overview, Full Tabs, and both Overview expanders collapsed;
- CompactBar and Orb with an official percentage, a relay percentage, a relay absolute wallet, and an unavailable pinned key;
- Light and Dark themes;
- 100% and 150% scale.

The PNGs are written to the ignored `outputs/visual` directory. Review each image for:

- transparent cohesive surfaces without an opaque white header or hard white root border;
- continuous progress fills without decorative white segmentation;
- dark mode title/body consistency and readable light-mode contrast;
- visible close controls and no clipped metric text;
- source labels, refresh button, unavailable placeholder, and collapsed-window natural height;
- correct layout at both scale factors.

## Settings center matrix

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -Sta -File .\tests\Visual\Capture-SettingsMatrix.ps1
```

The script writes 18 PNGs under `outputs/visual/settings`, covering all three pages,
light and dark themes, 100% and 150% scale, the disabled full-layout state, and a
focused error status. Review navigation selection, text clipping, keyboard-focus
affordance, segment and switch alignment, fixed status height, and theme contrast.
