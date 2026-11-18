#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

VERSION="${NOVA_VERSION:?Set NOVA_VERSION, for example 1.2.3}"
case "$VERSION" in
    *[!0-9.]*|.*|*.|*..*) echo "NOVA_VERSION must be a numeric version such as 1.2.3" >&2; exit 2 ;;
esac
OUTPUT_DIR="${1:-build/release}"
APP_NAME="Nova Launchpad.app"
VOLUME_NAME="Nova Launchpad $VERSION"
APP_PATH="build/$APP_NAME"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT HUP INT TERM

mkdir -p "$OUTPUT_DIR"
NOVA_VERSION="$VERSION" NOVA_BUILD_NUMBER="${NOVA_BUILD_NUMBER:-1}" sh scripts/build.sh "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/Nova-Launchpad-$VERSION-mac.zip"
cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$OUTPUT_DIR/Nova-Launchpad-$VERSION-mac.dmg" >/dev/null
(cd "$OUTPUT_DIR" && shasum -a 256 "Nova-Launchpad-$VERSION-mac.zip" "Nova-Launchpad-$VERSION-mac.dmg" > "Nova-Launchpad-$VERSION-SHA256SUMS.txt")
printf 'Packaged Nova Launchpad %s in %s\n' "$VERSION" "$OUTPUT_DIR"
