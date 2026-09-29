#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/notch-tests build
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" \
    -module-cache-path "$SWIFT_MODULE_CACHE" "${sources[@]}" \
    Tests/NotchHUDTests.swift Tests/NotchSimulationSupport.swift Tests/HookPresentationIntegrationChecks.swift Tests/AppUpdateIntegrationChecks.swift \
    -o .build/notch-tests/NotchHUDTests
.build/notch-tests/NotchHUDTests
