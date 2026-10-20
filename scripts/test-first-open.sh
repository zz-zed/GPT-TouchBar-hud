#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${HUD_APP_DIR:-$ROOT/build/GPT TouchBar HUD.app}"
[[ -d "$APP" ]] || { echo 'Run scripts/build-app.sh first' >&2; exit 1; }
TEST_DIR="$(mktemp -d /tmp/gpt-hud-first-open.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir "$TEST_DIR/system" "$TEST_DIR/user"
for app_name in 'GPT HUD.app' 'GPT TouchBar HUD.app'; do
    for location in system user; do
        TARGET="$TEST_DIR/$location/$app_name"
        if [[ "$location" == system ]]; then OTHER="$TEST_DIR/user/$app_name"; else OTHER="$TEST_DIR/system/$app_name"; fi
        cp -R "$APP" "$TARGET"
        HASH="$(codesign -dvvv "$TARGET" 2>&1 | sed -n 's/^CDHash=//p')"
        # Only these isolated fixture roots are allowed; suppress application launch.
        sed -e "s|\$HOME/Applications|$TEST_DIR/user|g" \
            -e "s|/Applications|$TEST_DIR/system|g" \
            -e "s/__PACKAGED_APP_NAME__/$app_name/g" \
            -e "s/__PACKAGED_CDHASH__/$HASH/" \
            -e 's|/usr/bin/open "$APP"|/usr/bin/true "$APP"|' \
            "$ROOT/Resources/first-open.command" > "$TEST_DIR/helper.command"
        bash -n "$TEST_DIR/helper.command"
        xattr -w com.apple.quarantine '0083;00000000;FirstOpenTest;' "$TARGET"
        xattr -w com.example.first-open-test keep "$TARGET"
        # Both fixed locations present: refuse to choose or modify either copy.
        cp -R "$APP" "$OTHER"
        if printf 'OPEN\n' | bash "$TEST_DIR/helper.command" > "$TEST_DIR/duplicate.log" 2>&1; then exit 1; fi
        xattr -p com.apple.quarantine "$TARGET" >/dev/null
        rm -rf "$OTHER"
        # A broken link at the other fixed location still blocks ambiguous selection.
        ln -s "$TEST_DIR/missing" "$OTHER"
        if printf 'OPEN\n' | bash "$TEST_DIR/helper.command" > "$TEST_DIR/duplicate-link.log" 2>&1; then exit 1; fi
        rm "$OTHER"
        # An arbitrary path outside the fixed roots must fail before xattr changes.
        sed -e "s|APP='$TEST_DIR/system/$app_name'|APP='$TEST_DIR/disallowed.app'|" \
            -e 's|select_target$|: # fixture suppress selection|' \
            "$TEST_DIR/helper.command" > "$TEST_DIR/disallowed.command"
        if printf 'OPEN\n' | bash "$TEST_DIR/disallowed.command" > "$TEST_DIR/disallowed.log" 2>&1; then exit 1; fi
        xattr -p com.apple.quarantine "$TARGET" >/dev/null
        printf 'cancel\n' | bash "$TEST_DIR/helper.command" > "$TEST_DIR/cancel.log"
        xattr -p com.apple.quarantine "$TARGET" >/dev/null
        printf 'OPEN\n' | bash "$TEST_DIR/helper.command" > "$TEST_DIR/open.log"
        if xattr -p com.apple.quarantine "$TARGET" >/dev/null 2>&1; then exit 1; fi
        [[ "$(xattr -p com.example.first-open-test "$TARGET")" == keep ]]
        printf 'OPEN\n' | bash "$TEST_DIR/helper.command" > "$TEST_DIR/repeat.log"
        ln -s /Applications "$TARGET/unexpected-link"
        if printf 'OPEN\n' | bash "$TEST_DIR/helper.command" > "$TEST_DIR/link.log" 2>&1; then exit 1; fi
        rm "$TARGET/unexpected-link"
        sed "s/$HASH/0000000000000000000000000000000000000000/" "$TEST_DIR/helper.command" > "$TEST_DIR/mismatch.command"
        if printf 'OPEN\n' | bash "$TEST_DIR/mismatch.command" > "$TEST_DIR/mismatch.log" 2>&1; then exit 1; fi
        if bash "$TEST_DIR/helper.command" unexpected > "$TEST_DIR/args.log" 2>&1; then exit 1; fi
        printf 'tamper' >> "$TARGET/Contents/MacOS/GPTTouchBarHUD"
        if printf 'OPEN\n' | bash "$TEST_DIR/helper.command" > "$TEST_DIR/tamper.log" 2>&1; then exit 1; fi
        rm -rf "$TARGET"
    done
done
echo 'PASS: both app names and fixed locations; duplicate/refused links, disallowed targets, cancel, scoped removal, preserved attributes, repeat, hash mismatch, arguments, tampered signature'
