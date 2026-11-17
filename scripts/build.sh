#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
APP="${1:-build/Nova Launchpad.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 6 -O Sources/NovaLaunchpad/Core/*.swift Sources/NovaLaunchpad/main.swift -o "$APP/Contents/MacOS/NovaLaunchpad"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NovaLaunchpad</string>
<key>CFBundleIdentifier</key><string>org.novalaunchpad.app</string>
<key>CFBundleName</key><string>Nova Launchpad</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
printf 'Built %s\n' "$APP"
