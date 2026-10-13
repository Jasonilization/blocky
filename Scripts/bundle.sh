#!/bin/bash
# Builds Blocky via SwiftPM and assembles a real Blocky.app bundle
# (no Xcode.app required).
set -euo pipefail

CONFIG="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Blocky"
BUILD_DIR="$ROOT_DIR/.build/$CONFIG"
APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"

echo "==> Building ($CONFIG)"
"$ROOT_DIR/Scripts/swift-build.sh" -c "$CONFIG" --package-path "$ROOT_DIR"

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Copy any SwiftPM resource bundles the target produced
for bundle in "$BUILD_DIR"/*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

echo "==> Ad-hoc codesigning"
codesign --force --deep -s - "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
echo "    Note: Blocky must run UNSANDBOXED — it spawns Java and writes to"
echo "    ~/Library/Application Support/minecraft, which the macOS sandbox"
echo "    forbids. The ad-hoc signature above intentionally carries no"
echo "    entitlements, so the bundle is not sandboxed."
