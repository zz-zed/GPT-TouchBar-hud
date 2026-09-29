#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---dry-run}"
if [[ "$#" -gt 1 || ( "$MODE" != --dry-run && "$MODE" != --apply ) ]]; then
    echo "Usage: bash scripts/clean-build-caches.sh [--dry-run|--apply]" >&2
    exit 2
fi

BUILD_DIR="$ROOT_DIR/.build"
if [[ ! -d "$BUILD_DIR" ]]; then
    echo "No .build directory"
    exit 0
fi

# Keep test logs, binaries, release candidates and evidence outside these cache directories.
find "$BUILD_DIR" -type d \( \
    -name module-cache -o \
    -name ModuleCache.noindex -o \
    -name SDKExplicitPrecompiledModules -o \
    -name SDKStatCaches.noindex \
\) -prune -print0 | while IFS= read -r -d '' cache_dir; do
    du -sh "$cache_dir"
    if [[ "$MODE" == --apply ]]; then
        rm -r -- "$cache_dir"
    fi
done

if [[ "$MODE" == --dry-run ]]; then
    echo "Dry run only. Run with --apply when no build or test is active."
fi
