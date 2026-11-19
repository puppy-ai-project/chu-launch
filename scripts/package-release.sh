#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

VERSION=$(tr -d '[:space:]' < VERSION)
if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "VERSION must contain a semantic version such as 1.2.3" >&2
    exit 2
fi
OUTPUT_DIR="${1:-build/release}"
ARCH="${CHU_ARCH:-$(uname -m)}"
APP_NAME="Chu Launchpad.app"
case "$ARCH" in
    arm64) ARCH_SUFFIX="arm64" ;;
    x86_64) ARCH_SUFFIX="x64" ;;
    *) echo "CHU_ARCH must be arm64 or x86_64" >&2; exit 2 ;;
esac
VOLUME_NAME="Chu Launchpad $VERSION ($ARCH_SUFFIX)"
APP_PATH="build/package-$ARCH/$APP_NAME"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT HUP INT TERM

mkdir -p "$OUTPUT_DIR"
CHU_RELEASE=1 CHU_BUILD_NUMBER="${CHU_BUILD_NUMBER:-1}" CHU_ARCH="$ARCH" sh scripts/build.sh "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/Chu-Launchpad-$VERSION-mac-$ARCH_SUFFIX.zip"
cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"
diskutil image create from --volumeName "$VOLUME_NAME" --format UDZO "$STAGING_DIR" "$OUTPUT_DIR/Chu-Launchpad-$VERSION-mac-$ARCH_SUFFIX.dmg" >/dev/null
(cd "$OUTPUT_DIR" && shasum -a 256 "Chu-Launchpad-$VERSION-mac-$ARCH_SUFFIX.zip" "Chu-Launchpad-$VERSION-mac-$ARCH_SUFFIX.dmg" > "Chu-Launchpad-$VERSION-SHA256SUMS-$ARCH_SUFFIX.txt")
printf 'Packaged Chu Launchpad %s (%s) in %s\n' "$VERSION" "$ARCH_SUFFIX" "$OUTPUT_DIR"
