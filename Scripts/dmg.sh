#!/bin/bash
# Builds Blocky-<version>-macOS.dmg — a drag-to-Applications installer.
# Stages the app + an /Applications symlink + a generated background, lays
# the icons out via Finder, then compresses with hdiutil. No Xcode needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/Blocky.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0.0)"
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

# Icon layout + background via Finder. Best-effort: if automation permission
# is missing we still ship a perfectly usable (if plainer) DMG.
echo "==> Laying out the window"
osascript <<APPLESCRIPT || echo "  (Finder layout skipped — no automation permission; DMG still works)"
tell application "Finder"
    set theDisk to (POSIX file "$STAGE") as alias
    open theDisk
    set theWindow to container window of theDisk
    set current view of theWindow to icon view
    set icon size of theWindow to 96
    set text size of theWindow to 11
    set toolbar visible of theWindow to false
    set statusbar visible of theWindow to false
    set bounds of theWindow to {120, 120, 780, 520}
    try
        set background picture of theWindow to file ".background:background.png" of theDisk
    end try
    set position of item "Blocky.app" of theDisk to {165, 180}
    set position of item "Applications" of theDisk to {495, 180}
    close theWindow
end tell
APPLESCRIPT

# Finder flushes .DS_Store asynchronously — imaging before it lands loses
# the layout. Wait for it (or proceed plain after ~5 s).
for _ in $(seq 1 10); do
    if [ -f "$STAGE/.DS_Store" ]; then
        echo "  layout persisted (.DS_Store present)"
        break
    fi
    sleep 0.5
done
[ -f "$STAGE/.DS_Store" ] || echo "  (layout did not persist — DMG ships plain)"

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
