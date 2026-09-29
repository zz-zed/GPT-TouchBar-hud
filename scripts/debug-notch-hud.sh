#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/notch-debug build
sources=()
for source in Sources/*.swift; do
    case "$source" in
        Sources/main.swift|Sources/AppDelegate.swift|Sources/AppUpdater.swift) ;;
        *) sources+=("$source") ;;
    esac
done
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" \
    -module-cache-path "$SWIFT_MODULE_CACHE" \
    "${sources[@]}" Tests/NotchSimulationSupport.swift Tests/NotchDebugMain.swift -o .build/notch-debug/NotchFusionDebug
exec .build/notch-debug/NotchFusionDebug "$@"
