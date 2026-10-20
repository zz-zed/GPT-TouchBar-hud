#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/readme-menu-capture
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
source scripts/swift-module-cache.sh
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
swiftc -whole-module-optimization "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" \
    -module-cache-path "$(swift_module_cache_path)" "${sources[@]}" \
    Marketing/ReadmeMenuCapture.swift -o .build/readme-menu-capture/ReadmeMenuCapture
.build/readme-menu-capture/ReadmeMenuCapture
