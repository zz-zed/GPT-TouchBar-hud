#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${HUD_APP_DIR:-$ROOT_DIR/build/GPT TouchBar HUD.app}"
DIST_DIR="${HUD_DIST_DIR:-$ROOT_DIR/dist}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
ARCH="${HUD_BUILD_ARCHS:-$(uname -m)}"
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { echo 'DMG packaging requires one architecture' >&2; exit 1; }
# DUAL_PACKAGE_SCHEMA=2: one signed build, two single-app installers.
cd "$ROOT_DIR"
"$ROOT_DIR/scripts/build-app.sh" >/dev/null
mkdir -p "$DIST_DIR"
CDHASH="$(codesign -dvvv "$APP_DIR" 2>&1 | sed -n 's/^CDHash=//p')"
[[ "$CDHASH" =~ ^[0-9a-f]{40}$ ]] || { echo 'Missing app CDHash' >&2; exit 1; }
for kind in primary compatibility; do
    if [[ "$kind" == primary ]]; then
        APP_NAME='GPT HUD.app'
        PREFIX='GPT-HUD'
    else
        APP_NAME='GPT TouchBar HUD.app'
        PREFIX='GPT-TouchBar-HUD'
    fi
    STAGING_DIR="$(mktemp -d "$DIST_DIR/dmg-stage-$kind.XXXXXX")"
    trap 'rm -rf "$STAGING_DIR"' EXIT
    DMG_PATH="$DIST_DIR/$PREFIX-$VERSION-$ARCH.dmg"
    cp -R "$APP_DIR" "$STAGING_DIR/$APP_NAME"
    ln -s /Applications "$STAGING_DIR/Applications"
    # Pin each helper to the exact signed payload and its allowed installation path.
    sed -e "s/__PACKAGED_CDHASH__/$CDHASH/g" -e "s/__PACKAGED_APP_NAME__/$APP_NAME/g" \
        "$ROOT_DIR/Resources/first-open.command" > "$STAGING_DIR/首次打开助手.command"
    chmod 755 "$STAGING_DIR/首次打开助手.command"
    sed "s/__PACKAGED_APP_NAME__/$APP_NAME/g" "$ROOT_DIR/Resources/first-open-guide.txt" > "$STAGING_DIR/首次打开说明.txt"
    bash -n "$STAGING_DIR/首次打开助手.command"
    hdiutil create -volname "GPT HUD" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
    rm -rf "$STAGING_DIR"
    trap - EXIT
    echo "$DMG_PATH"
done
