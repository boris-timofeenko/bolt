#!/bin/bash
# Builds Bolt.app into ./build. Usage: scripts/build-app.sh [debug|release]
# ARCH=x86_64 builds for Intel Macs (arm64 by default).
#
# Signs ad hoc. For distribution, set SIGN_IDENTITY to a Developer ID and notarize the result:
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh release
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCH="${ARCH:-arm64}"
swift build -c "$CONFIG" --arch "$ARCH"
BIN_DIR="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"
BIN="$BIN_DIR/Bolt"

APP=build/Bolt.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bolt"
# The command-line tool lives outside MacOS/: "bolt" and "Bolt" are the same name on most Mac disks.
mkdir -p "$APP/Contents/Helpers"
cp "$BIN_DIR/bolt-cli" "$APP/Contents/Helpers/bolt"
cp App/Info.plist "$APP/Contents/Info.plist"
cp -R App/*.lproj "$APP/Contents/Resources/"
cp App/Resources/* "$APP/Contents/Resources/"
[ -f App/AppIcon.icns ] && cp App/AppIcon.icns "$APP/Contents/Resources/"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/bolt"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    # Ad hoc, without the hardened runtime, so local builds can be profiled with sample and Instruments.
    # The helper first: the x86_64 linker doesn't sign it, and the app's signature covers it.
    codesign --force --sign - "$APP/Contents/Helpers/bolt"
    codesign --force --sign - "$APP"
fi
# Tell Launch Services about the app so Finder lists it under "Open With".
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
echo "$APP"
