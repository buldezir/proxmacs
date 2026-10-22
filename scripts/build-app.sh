#!/bin/bash
# Builds build/Proxmacs.app. IDENTITY=<codesign identity> overrides ad-hoc signing;
# VERSION=<x.y.z>, BUILD=<number> and BUNDLE_ID=<id> override Resources/Info.plist's.
set -euo pipefail
cd "$(dirname "$0")/.."

# Web UI (React): needs Node.js.
npm --prefix web ci --no-audit --no-fund
npm --prefix web run build

swift build -c release --product Proxmacs
BIN_DIR="$(swift build -c release --show-bin-path)"

APP=build/Proxmacs.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Proxmacs" "$APP/Contents/MacOS/Proxmacs"
# The updater: swift build leaves it next to the binary, an app keeps it in Frameworks.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Proxmacs"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R web/dist "$APP/Contents/Resources/WebAssets"
if [ -n "${VERSION:-}" ]; then plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"; fi
if [ -n "${BUILD:-}" ]; then plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"; fi
if [ -n "${BUNDLE_ID:-}" ]; then plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"; fi

# Notarization needs the hardened runtime and a secure timestamp, on the app and
# on Sparkle's helpers. An ad hoc signature goes without: library validation,
# part of the hardened runtime, would stop an ad hoc app from loading
# Sparkle.framework, which is signed by Sparkle's team.
case "${IDENTITY:-}" in
"Developer ID"*)
  scripts/sign-sparkle.sh "$APP" "$IDENTITY"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
  ;;
*)
  codesign --force --sign - "$APP"
  ;;
esac
echo "Built $APP"
