# AGENTS.md

Proxmacs: a menubar VM manager for Apple Silicon. It is Swift 6.2 (SwiftPM, Swift 6 language mode, macOS 26+) and shells out to the Homebrew `tart`
binary. A React web UI lives in `web/`. See README.md for features, the CLI and the on-disk layout.

## Build and check

```bash
swift build && swift test                  # Swift
npm --prefix web run build                 # typecheck + bundle into web/dist (a debug build serves it)
./scripts/build-app.sh                     # build/Proxmacs.app, web UI bundled into Resources/WebAssets
```

Run both `swift test` and the web build before you finish a change.

## Layout

- `Sources/Proxmacs/`
  - `App/`: `AppState` (state, polling, scheduler) and `CLI.swift` (`Proxmacs cli …`, which shares code with the menubar).
  - `Tart/`: the `tart` wrapper, LaunchAgents and `VMRunner` (supervises `tart run` and owns the serial console).
  - `Backup/`, `Offsite/` (SMB and PBS), `Storage/` (external drives), `Images/` (qcow2 → raw), `Provision/` (cloud-init).
  - `Web/`: Hummingbird server, `/api/*` and auth.
  - `UI/`: SwiftUI menubar.
- `web/src/`: React 19 + TS, with no UI library; styles are in `app.css`.
- `scripts/`: build, uninstall, icon and screenshot generators.

## Testing without touching real data

- Point `PROXMACS_SUPPORT_DIR` at a scratch directory.
- Write its `storage.json`, which sets custom `vms` and `backups` paths with `.proxmacs-storage` markers, **before**
  running anything. Otherwise Tart uses the real `~/.tart`. `TART_HOME` also works for VMs.
- `cli serve` with a `web.json` like `{"port": 8016, "bind": "127.0.0.1", "tls": false}` runs a headless web UI;
  set its password with `cli web-passwd --stdin`.
- Remove the test VMs afterwards (`cli delete`), including their LaunchAgents. Never run `scripts/uninstall.sh`
  against real data.

## Conventions

- Match the surrounding style. Comments explain *why*, sparingly.
- Errors are `ProxmacsError("…")` with a message a user can act on.
- Tart owns `<VM storage>/vms/<name>/`. Proxmacs metadata goes in the data directory (`Paths`).
- Check `Storage.require(...)` before you touch VM or backup storage.
- Paths may contain spaces. Tart 2.x breaks when `TART_HOME` has one, so the disk is swapped in our own code
  (`BackupManager.setDisk`) rather than with `tart set --disk`.
- Disk images must stay sparse: use `FileCopy` (clone on the same volume, data regions only across volumes).
- Never put secrets in config, logs or argv. They go in `secrets.json` (0600) and are entered at a hidden prompt or
  through the UI.
- Web UI:
  - It must work from 320px wide up to very wide screens; the breakpoint is `NARROW` (760px) in `hooks.ts`.
  - Use CSS variables for colors, so both light and dark themes work.
- When UI changes, update the README and, if relevant, `docs/` screenshots (`scripts/docs-screenshots.swift`).
