#!/usr/bin/env bash
# Validate the already-built native DMG, including representative old updaters.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
ARCH="$(uname -m)"
DMG=""
CHECKSUMS=""
OUTPUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch|--dmg|--checksums|--output)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            case "$1" in
                --arch) ARCH="$2" ;;
                --dmg) DMG="$2" ;;
                --checksums) CHECKSUMS="$2" ;;
                --output) OUTPUT="$2" ;;
            esac
            shift 2
            ;;
        -h|--help)
            echo "Usage: verify-package.sh [--arch arm64|x86_64] [--dmg PATH] [--checksums PATH] [--output NEW_DIRECTORY]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == "$ARCH" ]] || {
    echo 'Package verification requires macOS on the package native architecture.' >&2
    exit 1
}
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { echo 'Unsupported architecture.' >&2; exit 1; }
VERSION="$(python3 -c 'import plistlib; print(plistlib.load(open("Resources/Info.plist", "rb"))["CFBundleShortVersionString"])')"
DMG="${DMG:-${HUD_DIST_DIR:-$ROOT_DIR/dist}/GPT-TouchBar-HUD-$VERSION-$ARCH.dmg}"
CHECKSUMS="${CHECKSUMS:-$(dirname "$DMG")/SHA256SUMS.txt}"
[[ -f "$DMG" && -f "$CHECKSUMS" ]] || { echo 'Existing DMG and SHA256SUMS.txt are required; nothing will be rebuilt.' >&2; exit 1; }
DMG="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True))' "$DMG")"
CHECKSUMS="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True))' "$CHECKSUMS")"
if [[ -n "$OUTPUT" ]]; then
    [[ ! -e "$OUTPUT" ]] || { echo 'Verification output must be a new directory.' >&2; exit 1; }
    mkdir -p "$OUTPUT"
else
    mkdir -p "$ROOT_DIR/build/package-verification/$ARCH"
    OUTPUT="$(mktemp -d "$ROOT_DIR/build/package-verification/$ARCH/verify.XXXXXX")"
fi
OUTPUT="$(cd "$OUTPUT" && pwd)"

# This reads and mounts the actual DMG: version, identity, signatures, app/helper
# architecture, Mach-O minimum OS, first-open binding and checksum are required.
python3 scripts/check-update-compatibility.py --dmg "$DMG" --arch "$ARCH" \
    --checksums "$CHECKSUMS" --output "$OUTPUT/contract.json"

# Run the existing first-open refusal tests against the packaged app, never an
# unrelated build directory or installed app. The test only mutates a temp copy.
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/gpt-hud-package-verify.XXXXXX")"
MOUNTED=0
cleanup() {
    if [[ "$MOUNTED" == 1 ]]; then
        hdiutil detach "$MOUNT" || hdiutil detach -force "$MOUNT"
    fi
    rmdir "$MOUNT"
}
trap cleanup EXIT
hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" > "$OUTPUT/first-open-mount.log"
MOUNTED=1
HUD_APP_DIR="$MOUNT/GPT TouchBar HUD.app" HUD_BUILD_ARCHS="$ARCH" bash scripts/verify-app.sh
HUD_APP_DIR="$MOUNT/GPT TouchBar HUD.app" bash scripts/test-first-open.sh
hdiutil detach "$MOUNT" > "$OUTPUT/first-open-detach.log"
MOUNTED=0
rmdir "$MOUNT"
trap - EXIT

python3 scripts/test-earliest-update-contract.py --version "$VERSION" --arch "$ARCH" \
    --checksums "$CHECKSUMS" --output "$OUTPUT/earliest"
python3 scripts/test-legacy-update-compatibility.py --dmg "$DMG" --arch "$ARCH" \
    --output "$OUTPUT/legacy"
printf 'PASS: existing native DMG and representative upgrade/rollback; evidence: %s\n' "$OUTPUT"
