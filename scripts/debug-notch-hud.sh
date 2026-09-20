#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/notch-debug/module-cache build
sources=()
for source in Sources/*.swift; do
    case "$source" in
        Sources/main.swift|Sources/AppDelegate.swift|Sources/AppUpdater.swift) ;;
        *) sources+=("$source") ;;
    esac
done
source scripts/hook-core-build.sh
swiftc -swift-version 5 "${HOOK_CORE_SWIFT_FLAGS[@]}" -module-cache-path .build/notch-debug/module-cache \
    "${sources[@]}" Tests/NotchSimulationSupport.swift Tests/NotchDebugMain.swift -o .build/notch-debug/NotchFusionDebug
exec .build/notch-debug/NotchFusionDebug "$@"
