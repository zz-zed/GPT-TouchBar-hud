#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/reset-news-popover-tests build
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" -whole-module-optimization \
    -module-cache-path "$SWIFT_MODULE_CACHE" "${sources[@]}" \
    Tests/ResetNewsPopoverTests.swift -o .build/reset-news-popover-tests/ResetNewsPopoverTests
.build/reset-news-popover-tests/ResetNewsPopoverTests
