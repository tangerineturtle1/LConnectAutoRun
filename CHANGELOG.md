# Changelog

## 1.1.0

- **Service watcher back on.** Reinstalling turns the L-Connect service watcher back on; it's what keeps the service running.
- **Automatic restart.** If the L-Connect service crashes, Windows restarts it after 5 seconds.
- **Profiles re-applied.** A background task watches for the service stopping or restarting. About 20 seconds later it runs the same hidden apply step as at boot, bringing the fans back to your curves. If L-Connect is open at the time, it's left alone, since the open app already handles the profiles.
- **One run at a time.** The boot step and the re-apply step can't run at once or overlap.

## 1.0.0

- Applies L-Connect profiles at boot in a hidden session, then closes the app. The service keeps running for fan curves.
- Turns off L-Connect's and OpenRGB's own startup entries, and re-checks them every boot.
- Disables the L-Connect service watcher.
- OpenRGB gate: OpenRGB only runs while the L-Connect app is open.
- Install.cmd, Uninstall.cmd (restores everything) and Diagnose.cmd. Every step is logged.
