#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/GPT TouchBar HUD.app"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/dmg-stage"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
DMG_NAME="GPT-TouchBar-HUD-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

cd "$ROOT_DIR"

"$ROOT_DIR/scripts/build-app.sh" >/dev/null

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$DIST_DIR"

cp -R "$APP_DIR" "$STAGING_DIR/GPT TouchBar HUD.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "GPT TouchBar HUD" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$STAGING_DIR"

echo "$DMG_PATH"
