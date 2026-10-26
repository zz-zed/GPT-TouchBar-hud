#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${HUD_APP_DIR:-$ROOT_DIR/build/GPT TouchBar HUD.app}"
DIST_DIR="${HUD_DIST_DIR:-$ROOT_DIR/dist}"
[[ -d "$APP_DIR" ]] || { echo 'No built app. Run make package, or build-app.sh before packaging.' >&2; exit 1; }
VERSION="$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleShortVersionString"])' "$ROOT_DIR/Resources/Info.plist")"
# Native releases keep the updater's architecture-specific filenames. A universal
# local app can still be packaged explicitly with HUD_PACKAGE_ARCH=universal.
PACKAGE_ARCH="${HUD_PACKAGE_ARCH:-$(uname -m)}"
DMG_NAME="GPT-TouchBar-HUD-${VERSION}.dmg"
case "$PACKAGE_ARCH" in
    arm64|x86_64)
        DMG_NAME="${DMG_NAME%.dmg}-$PACKAGE_ARCH.dmg"
        EXPECTED_ARCHES="$PACKAGE_ARCH"
        ;;
    universal) EXPECTED_ARCHES="arm64 x86_64" ;;
    *) echo "Unsupported package architecture: $PACKAGE_ARCH" >&2; exit 1 ;;
esac
DMG_PATH="$DIST_DIR/$DMG_NAME"

cd "$ROOT_DIR"

# Packaging consumes this exact existing app. It never invokes a compiler.
HUD_APP_DIR="$APP_DIR" HUD_BUILD_ARCHS="$EXPECTED_ARCHES" bash "$ROOT_DIR/scripts/verify-app.sh"

mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$DIST_DIR/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$APP_DIR" "$STAGING_DIR/GPT TouchBar HUD.app"
ln -s /Applications "$STAGING_DIR/Applications"

# Bind the first-open helper to this exact app; keep it outside the signed bundle.
CDHASH="$(codesign -dvvv "$APP_DIR" 2>&1 | sed -n 's/^CDHash=//p')"
[[ "$CDHASH" =~ ^[0-9a-f]{40}$ ]] || { echo 'Missing app CDHash' >&2; exit 1; }
sed "s/__PACKAGED_CDHASH__/$CDHASH/g" "$ROOT_DIR/Resources/first-open.command" > "$STAGING_DIR/首次打开助手.command"
chmod 755 "$STAGING_DIR/首次打开助手.command"
cp "$ROOT_DIR/Resources/first-open-guide.txt" "$STAGING_DIR/首次打开说明.txt"
bash -n "$STAGING_DIR/首次打开助手.command"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "GPT HUD" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

# Keep the checksum beside the package for local verification. Each native CI
# runner owns its workspace; the publisher combines the two verified payloads.
(cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt)
printf '%s\n' "$DMG_PATH"
