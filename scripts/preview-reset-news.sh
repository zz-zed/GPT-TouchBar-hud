#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/reset-news-preview/module-cache Design/reset-news-preview
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" \
    -whole-module-optimization \
    -module-cache-path .build/reset-news-preview/module-cache "${sources[@]}" \
    Tests/ResetNewsPreviewMain.swift -o .build/reset-news-preview/ResetNewsPreview
.build/reset-news-preview/ResetNewsPreview
