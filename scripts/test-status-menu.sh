#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/status-menu/module-cache
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
swiftc -whole-module-optimization "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" \
    -module-cache-path .build/status-menu/module-cache \
    "${sources[@]}" Tests/StatusMenuTests.swift -o .build/status-menu/StatusMenuTests
.build/status-menu/StatusMenuTests
