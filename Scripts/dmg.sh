#!/bin/bash
# Builds Blocky-<version>-macOS.dmg — a drag-to-Applications installer.
# Stages the app + an /Applications symlink + a generated background, lays
# the icons out via Finder, then compresses with hdiutil. No Xcode needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/Blocky.app"
# The source plist, not the previously built app — that one is still the last version until bundle.sh runs.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist" 2>/dev/null || echo 1.0.0)"
STAGE="$ROOT_DIR/.build/dmg-stage"
DMG="$ROOT_DIR/Blocky-$VERSION-macOS.dmg"

echo "==> Building the app first"
"$ROOT_DIR/Scripts/bundle.sh" release

echo "==> Staging DMG contents"
rm -rf "$STAGE"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -sfn /Applications "$STAGE/Applications"
swift "$ROOT_DIR/Scripts/dmg-background.swift" "$STAGE/.background/background.png" "$ROOT_DIR/icon.png"

# Write the window layout straight into .DS_Store. Finder's AppleScript
# `set background picture` is refused on current macOS (error -10006), so
# the meadow background is applied here instead — same records, no
# automation permission needed.
echo "==> Writing DMG window layout"
python3 "$ROOT_DIR/Scripts/dmg-layout.py" "$STAGE"

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "Blocky" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet

# Verify the image mounts and contains what it should.
MOUNT="$(mktemp -d)/Blocky-mount)"
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -quiet -nobrowse
hdiutil detach "$MOUNT" -quiet >/dev/null
rm -rf "$(dirname "$MOUNT")"

echo "==> Done: $DMG"
echo "    Drag Blocky to Applications in the mounted image."
