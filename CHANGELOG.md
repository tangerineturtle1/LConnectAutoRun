# Changelog

## 1.0.0

- Applies L-Connect profiles at boot in a hidden session, then closes the app. The service keeps running for fan curves.
- Turns off L-Connect's and OpenRGB's own startup entries, and re-checks them every boot.
- Disables the L-Connect service watcher.
- OpenRGB gate: OpenRGB only runs while the L-Connect app is open.
- Install.cmd, Uninstall.cmd (restores everything) and Diagnose.cmd. Every step is logged.
