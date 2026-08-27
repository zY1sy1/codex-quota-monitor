# Console-Free Launch Design

## Problem

Installed shortcuts currently target `pwsh.exe` directly and pass
`-WindowStyle Hidden`. When Windows Terminal is the default terminal host, it
attaches to the console process before PowerShell can apply that option. A
visible terminal tab remains open, and closing it terminates the PowerShell
process that owns the monitor UI.

## Desired Behavior

- Starting the monitor from its desktop or Startup shortcut must not open a
  PowerShell, Windows Terminal, or console window.
- The monitor must keep running after the short-lived launcher exits.
- The monitor must still exit through its existing window and tray commands.
- Single-instance behavior, logging, settings, quota collection, and UI
  behavior must remain unchanged.

## Design

Add a small VBScript launcher to the installed application payload. The
shortcut will target the Windows GUI subsystem executable `wscript.exe`
instead of the console subsystem executable `pwsh.exe`. Its arguments will
identify the launcher, the previously validated PowerShell 7 executable, and
the installed monitor entry script.

The launcher will validate its argument count, build a quoted PowerShell
command line, and call `WScript.Shell.Run` with a hidden window style and
without waiting for completion. `wscript.exe` can then exit while the monitor's
PowerShell process continues to own the WPF window and tray icon.

Installation, repair, upgrade, and the UI startup toggle will consistently
recreate the managed Startup shortcut with the console-free launch contract.
The existing PowerShell executable probe remains responsible for requiring a
launchable PowerShell 7.4 or later runtime.

The installer does not own or create desktop shortcuts. As a deployment step,
the existing `Codex 余额监视器.lnk` shortcut on the current machine will be
updated to the same target and arguments while preserving its name, icon,
description, and working directory. This migration is limited to that known
shortcut and does not introduce automatic desktop shortcut creation.

## Error Handling

Installation and repair will fail before replacing a working installation if
the launcher payload or system `wscript.exe` is missing. Runtime launch errors
remain non-interactive because the shortcut uses `wscript.exe //B`; the
monitor's existing logs and health checks remain the diagnostic interface.

## Testing

Regression coverage will verify:

- generated shortcuts target the absolute system `wscript.exe` path rather
  than `pwsh.exe`;
- shortcut arguments preserve launcher, PowerShell, and entry-script paths
  containing spaces and non-ASCII characters;
- the launcher exits promptly while the launched PowerShell process remains
  alive and has no console window;
- managed Startup shortcut overwrite and removal behavior remains intact;
- installation and repair stage the launcher and create shortcuts with the new
  contract;
- the migrated desktop shortcut has the new launch target and retains its
  existing presentation metadata;
- the existing unit and integration suites continue to pass.

## Scope

This change applies to the `z` Codex quota monitor repository and its current
installed copy. The separate `relay-quota-monitor` worktree has the same legacy
shortcut implementation but contains unrelated in-progress changes and is not
part of this change.
