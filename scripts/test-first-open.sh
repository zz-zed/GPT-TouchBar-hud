#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/GPT TouchBar HUD.app"
[[ -d "$APP" ]] || { echo 'Run scripts/build-app.sh first' >&2; exit 1; }
TEST_DIR="$(mktemp -d /tmp/gpt-hud-first-open.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
TARGET="$TEST_DIR/GPT TouchBar HUD.app"
cp -R "$APP" "$TARGET"
HASH="$(codesign -dvvv "$TARGET" 2>&1 | sed -n 's/^CDHash=//p')"
# Only this isolated test copy accepts a fixture target and suppresses application launch.
sed -e "s|/Applications/GPT TouchBar HUD.app|$TARGET|g" \
    -e "s/__PACKAGED_CDHASH__/$HASH/" \
    -e 's|/usr/bin/open "$APP"|/usr/bin/true "$APP"|' \
    "$ROOT/Resources/first-open.command" > "$TEST_DIR/helper.command"
bash -n "$TEST_DIR/helper.command"
xattr -w com.apple.quarantine '0083;00000000;FirstOpenTest;' "$TARGET"
xattr -w com.example.first-open-test keep "$TARGET"
printf 'cancel\n' | bash "$TEST_DIR/helper.command" > "$TEST_DIR/cancel.log"
xattr -p com.apple.quarantine "$TARGET" >/dev/null
printf 'OPEN\n' | bash "$TEST_DIR/helper.command" > "$TEST_DIR/open.log"
if xattr -p com.apple.quarantine "$TARGET" >/dev/null 2>&1; then exit 1; fi
[[ "$(xattr -p com.example.first-open-test "$TARGET")" == keep ]]
# Idempotent without quarantine.
printf 'OPEN\n' | bash "$TEST_DIR/helper.command" > "$TEST_DIR/repeat.log"
ln -s /Applications "$TARGET/unexpected-link"
if printf 'OPEN\n' | bash "$TEST_DIR/helper.command" > "$TEST_DIR/link.log" 2>&1; then exit 1; fi
rm "$TARGET/unexpected-link"
sed "s/$HASH/0000000000000000000000000000000000000000/" "$TEST_DIR/helper.command" > "$TEST_DIR/mismatch.command"
if printf 'OPEN\n' | bash "$TEST_DIR/mismatch.command" > "$TEST_DIR/mismatch.log" 2>&1; then exit 1; fi
if bash "$TEST_DIR/helper.command" unexpected > "$TEST_DIR/args.log" 2>&1; then exit 1; fi
printf 'tamper' >> "$TARGET/Contents/MacOS/GPTTouchBarHUD"
if printf 'OPEN\n' | bash "$TEST_DIR/helper.command" > "$TEST_DIR/tamper.log" 2>&1; then exit 1; fi
echo 'PASS: cancel, scoped removal, preserve unrelated attributes, repeat, symlink, hash mismatch, arguments, tampered signature'
