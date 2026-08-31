#!/usr/bin/env bash
# Builds Crunch in release mode and assembles a standalone dist/Crunch.app bundle,
# complete with Info.plist, an ad-hoc code signature, and an app icon generated
# from icon_generator.swift. Idempotent: safe to re-run.
#
# Usage: scripts/make-app.sh
#
# Notarization is NOT performed here. To notarize for distribution outside this
# Mac, after running this script:
#   ditto -c -k --keepParent dist/Crunch.app dist/Crunch.zip
#   xcrun notarytool submit dist/Crunch.zip --keychain-profile <profile> --wait
#   xcrun stapler staple dist/Crunch.app

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Crunch"
BUNDLE_ID="com.paultakisaki.crunch"
BUNDLE_VERSION="1.0.0"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$DIST_DIR/$APP_NAME.iconset"
ICNS_PATH="$RESOURCES_DIR/AppIcon.icns"

echo "==> Building $APP_NAME (release)"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"

if [ ! -x "$BIN_PATH" ]; then
    echo "error: expected release binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"

echo "==> Writing Info.plist"
cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$BUNDLE_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUNDLE_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Generating app icon"
rm -rf "$ICONSET_DIR"
GENERATED_ICONSET="/tmp/Crunch.iconset"
rm -rf "$GENERATED_ICONSET"
swift "$ROOT_DIR/icon_generator.swift"

if [ ! -d "$GENERATED_ICONSET" ] || [ -z "$(find "$GENERATED_ICONSET" -maxdepth 1 -name '*.png' -print -quit)" ]; then
    echo "error: icon_generator.swift did not produce any PNGs in $GENERATED_ICONSET" >&2
    exit 1
fi

mkdir -p "$ICONSET_DIR"
cp "$GENERATED_ICONSET"/*.png "$ICONSET_DIR/"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
rm -rf "$ICONSET_DIR"

echo "==> Ad-hoc code signing"
codesign --force --deep -s - "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
