# LConnectAutoRun

**Version 1.0.0** · Windows · for Lian Li L-Connect 3

Applies your L-Connect lighting, fan and LCD profiles **invisibly at boot**, then closes L-Connect, so it isn't sitting in the background. The L-Connect service keeps running so your fan curves still work.

## What it does

- **At boot** (before you log in, with no windows): makes sure the L-Connect service is running, opens L-Connect hidden so it applies your profiles, then closes the app.
- **Stops L-Connect and OpenRGB from starting with Windows** on their own. This is checked again every boot, in case L-Connect turns them back on.
- **Disables the L-Connect service watcher.** The main service stays on.
- **OpenRGB only runs while the L-Connect app is open,** and is stopped when you close the app. Any other time, launches of OpenRGB.exe are blocked.

## Install

1. Download the latest zip from **Releases** and extract it to a folder.
2. Double-click **Install.cmd** and approve the admin prompt.
3. Reboot once and check your lighting.

## Change your lighting later

Open L-Connect normally, change and save, then close it. OpenRGB works while it's open.

## Uninstall

Double-click **Uninstall.cmd**. Everything is put back the way it was.

## Troubleshooting

Every step is logged to `C:\ProgramData\LConnectAutoRun\autorun.log`.

- **OpenRGB problems:** open L-Connect, wait 15 seconds, then double-click **Diagnose.cmd**. It tests the OpenRGB gate and writes what it finds to the log.
- **Profiles not applied at boot:** reinstall with longer waits, from PowerShell in this folder:
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\LConnectAutoRun.ps1 -Install -ApplySeconds 40 -ServiceSettleSeconds 20
  ```
- **L-Connect not found:** add `-LConnectPath "C:\path\to\L-Connect 3.exe"` to that command.

## Notes

- **The OpenRGB rule applies to any program named OpenRGB.exe,** including a separate OpenRGB install. It works through Windows' Image File Execution Options, which a small gate program built on your PC at install time uses. Uninstall removes it.
- **Closing L-Connect's window to the tray** keeps the app, and OpenRGB, running. Exit it from the tray icon to close it fully.
- **Requires** Windows 10 or 11 and L-Connect 3.

## License

MIT. See LICENSE.
