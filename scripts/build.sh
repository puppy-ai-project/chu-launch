#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "${CHU_RELEASE:-0}" = 1 ]; then
    APP_NAME="Chu Launchpad.app"
    APP_DISPLAY_NAME="Chu Launchpad"
    APP_BUNDLE_ID="com.withqq.chu-launchpad"
    AGENT_BUNDLE_ID="com.withqq.chu-launchpad.agent"
    BUILD_FLAGS="release"
else
    APP_NAME="Chu Launchpad dev.app"
    APP_DISPLAY_NAME="Chu Launchpad dev"
    APP_BUNDLE_ID="com.withqq.chu-launchpad.dev"
    AGENT_BUNDLE_ID="com.withqq.chu-launchpad.agent.dev"
    BUILD_FLAGS="development"
fi
APP="${1:-build/$APP_NAME}"
VERSION="${CHU_VERSION:-1.0.0}"
BUILD_NUMBER="${CHU_BUILD_NUMBER:-1}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
set --
if [ "$BUILD_FLAGS" = development ]; then set -- "$@" -D CHU_DEVELOPMENT; fi
if [ "${CHU_DEBUG:-0}" = 1 ]; then set -- "$@" -D DEBUG; fi
if [ -n "${CHU_ARCH:-}" ]; then
    case "$CHU_ARCH" in
        arm64|x86_64) ;;
        *) echo "CHU_ARCH must be arm64 or x86_64" >&2; exit 2 ;;
    esac
    set -- "$@" -target "$CHU_ARCH-apple-macosx14.0"
fi
AGENT="$APP/Contents/Helpers/$APP_NAME"
# Remove the obsolete generated helper so packaged builds contain only the current bundle.
rm -rf "$APP/Contents/Helpers/ChuLaunchAgent.app"
mkdir -p "$AGENT/Contents/MacOS" "$AGENT/Contents/Resources"
swiftc "$@" -module-cache-path /tmp/swift-module-cache -swift-version 6 -O Sources/ChuLaunchpad/Core/*.swift Sources/ChuLaunchpad/Settings/*.swift scripts/entry/DockPin.swift Sources/ChuLaunchpad/main.swift -o "$AGENT/Contents/MacOS/Chu Launchpad"
swiftc "$@" -module-cache-path /tmp/swift-module-cache -swift-version 6 -O scripts/entry/DockPin.swift scripts/entry/main.swift -o "$APP/Contents/MacOS/ChuLaunchpad"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>LSUIElement</key><true/>
<key>CFBundleExecutable</key><string>ChuLaunchpad</string>
<key>CFBundleIdentifier</key><string>$APP_BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_DISPLAY_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_DISPLAY_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string></array>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
iconset="$(mktemp -d)/ChuLaunchpad.iconset"
mkdir -p "$iconset"
trap 'rm -rf "$(dirname "$iconset")"' EXIT
cat > "$iconset/render.swift" <<'SWIFT'
import AppKit
import CoreImage
@main struct RenderIcon {
    static func main() throws {
        let image = ChuAppIcon.image(size: 1024)
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
SWIFT
swiftc -module-cache-path /tmp/swift-module-cache -swift-version 6 Sources/ChuLaunchpad/Settings/AppIcon.swift "$iconset/render.swift" -o "$iconset/render-icon"
"$iconset/render-icon" "$iconset/source.png"
sips -z 16 16 "$iconset/source.png" --out "$iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$iconset/source.png" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$iconset/source.png" --out "$iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$iconset/source.png" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$iconset/source.png" --out "$iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$iconset/source.png" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$iconset/source.png" --out "$iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$iconset/source.png" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$iconset/source.png" --out "$iconset/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$iconset/source.png" --out "$iconset/icon_512x512@2x.png" >/dev/null
rm "$iconset/source.png"
iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon' "$APP/Contents/Info.plist"
cp "$APP/Contents/Info.plist" "$AGENT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $AGENT_BUNDLE_ID" "$AGENT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Chu Launchpad" "$AGENT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_DISPLAY_NAME" "$AGENT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_DISPLAY_NAME" "$AGENT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement true' "$AGENT/Contents/Info.plist"
cp "$APP/Contents/Resources/AppIcon.icns" "$AGENT/Contents/Resources/"
printf 'Built %s\n' "$APP"
