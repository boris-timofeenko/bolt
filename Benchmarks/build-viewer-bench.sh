#!/bin/bash
# Builds build/BoltBench.app (the launcher that gets the permissions) and build/viewerbench (the tool).
# The launcher is only rebuilt when missing: rebuilding it would void the grants.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 Benchmarks/ViewerBench/viewerbench.swift -o build/viewerbench
codesign --force --sign - build/viewerbench

APP=build/BoltBench.app
if [ ! -d "$APP" ]; then
    mkdir -p "$APP/Contents/MacOS"
    swiftc -O Benchmarks/ViewerBench/launcher.swift -o "$APP/Contents/MacOS/BoltBench"
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>BoltBench</string>
	<key>CFBundleIdentifier</key><string>org.boltviewer.BoltBench</string>
	<key>CFBundleName</key><string>BoltBench</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSUIElement</key><true/>
	<key>NSScreenCaptureUsageDescription</key><string>Records the screen to time how fast photo viewers show photos.</string>
</dict>
</plist>
PLIST
    codesign --force --sign - "$APP"
fi
echo "$APP"
