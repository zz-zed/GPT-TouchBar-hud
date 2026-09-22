#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/notch-presentation/module-cache build/notch-island
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" \
    -module-cache-path .build/notch-presentation/module-cache \
    "${sources[@]}" Tests/NotchHarness/*.swift -o .build/notch-presentation/NotchHarness
.build/notch-presentation/NotchHarness "$@"
