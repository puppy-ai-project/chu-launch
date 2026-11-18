#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

VERSION="${CHU_VERSION:?Set CHU_VERSION, for example 1.2.3}"
case "$VERSION" in
    *[!0-9.]*|.*|*.|*..*) echo "CHU_VERSION must be a numeric version such as 1.2.3" >&2; exit 2 ;;
esac
OUTPUT_DIR="${1:-build/release}"
APP_NAME="Chu Launchpad.app"
VOLUME_NAME="Chu Launchpad $VERSION"
APP_PATH="build/$APP_NAME"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT HUP INT TERM

mkdir -p "$OUTPUT_DIR"
CHU_VERSION="$VERSION" CHU_BUILD_NUMBER="${CHU_BUILD_NUMBER:-1}" sh scripts/build.sh "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/Chu-Launchpad-$VERSION-mac.zip"
cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$OUTPUT_DIR/Chu-Launchpad-$VERSION-mac.dmg" >/dev/null
(cd "$OUTPUT_DIR" && shasum -a 256 "Chu-Launchpad-$VERSION-mac.zip" "Chu-Launchpad-$VERSION-mac.dmg" > "Chu-Launchpad-$VERSION-SHA256SUMS.txt")
printf 'Packaged Chu Launchpad %s in %s\n' "$VERSION" "$OUTPUT_DIR"
