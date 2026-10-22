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

## Releases

`.github/workflows/release.yml` runs on `v*` tags, on the `xcode-27` runner:

- `build-app.sh` builds the app with the tag as `VERSION`, and as `BUILD`, a build number that only grows (`0.3.0-beta.2` →
  30002, `0.3.0` → 30099), which Sparkle compares. A local build is version `0.1`, and doesn't update.
- It signs the app (`IDENTITY`) with the Developer ID certificate in the repository's secrets
  (`MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`), with the hardened runtime and a secure timestamp, and
  Sparkle's helpers with `scripts/sign-sparkle.sh`, as notarization requires. The workflow notarizes it with an App
  Store Connect API key (`NOTARY_API_KEY_BASE64`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID`) and staples it.
- `scripts/appcast.sh` writes the app's Sparkle feed, `Proxmacs-macOS-appcast.xml`: the zip's EdDSA signature
  (`SPARKLE_PRIVATE_KEY`, checked against the app's `SUPublicEDKey`) and the release's notes up to its `## Downloads`,
  if the release is written by then. The release job uploads `Proxmacs-macOS-arm64.zip` and `SHA256SUMS`, then the
  feed, which `SUFeedURL` reads from the latest release.
- A tag without the secrets fails. A run by hand without them signs ad hoc and keeps the zip as a run artifact. An ad
  hoc build has no hardened runtime, under which it couldn't load Sparkle.framework. A run by hand takes a `version`,
  such as `0.2.0-test.1`, to build an app that offers and takes updates, and a `bundle_id`, such as
  `dev.proxmacs.app.updatetest`, to keep it apart from the installed one.

Proxmacs updates itself with Sparkle (`AppUpdater`), only in the menubar app: `cli` never starts it. `build-app.sh`
copies Sparkle.framework into the app, where the binary finds it through `@executable_path/../Frameworks`. An update
that a daily check finds while the app is in the background waits in the menubar window, as **Update to …**. VMs run
under their own LaunchAgents, so they keep running while the app restarts. Sparkle refuses to update an app that macOS
runs from a temporary copy (App Translocation), which happens to a downloaded app opened before it was moved into
Applications; `xattr -dr com.apple.quarantine` on the app in Applications fixes it.

Sparkle installs only updates signed with the key whose public half is `SUPublicEDKey` in `Resources/Info.plist`. Its
private half is in the login keychain of the Mac that made it, and in the repository's secrets; keep a backup, since
without it the app can never update again:

```bash
mkdir -p ~/sparkle && curl -fsSL https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz | tar -xf - -C ~/sparkle
~/sparkle/bin/generate_keys --account proxmacs         # prints the public key
~/sparkle/bin/generate_keys --account proxmacs -x ~/sparkle/private-key
gh secret set SPARKLE_PRIVATE_KEY < ~/sparkle/private-key
```

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
