#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/reset-news-date-card-tests/module-cache
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" -whole-module-optimization \
    -module-cache-path .build/reset-news-date-card-tests/module-cache "${sources[@]}" \
    Tests/ResetNewsDateCardTests.swift -o .build/reset-news-date-card-tests/ResetNewsDateCardTests
.build/reset-news-date-card-tests/ResetNewsDateCardTests
