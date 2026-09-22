#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/reset-news-popover-tests/module-cache build
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" -whole-module-optimization \
    -module-cache-path .build/reset-news-popover-tests/module-cache "${sources[@]}" \
    Tests/ResetNewsPopoverTests.swift -o .build/reset-news-popover-tests/ResetNewsPopoverTests
.build/reset-news-popover-tests/ResetNewsPopoverTests
