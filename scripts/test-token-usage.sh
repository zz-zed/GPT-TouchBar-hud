#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/token-tests
source scripts/hook-core-build.sh
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" -O -module-cache-path "$SWIFT_MODULE_CACHE" \
    Sources/TokenUsageScanner.swift Sources/LimitModels.swift \
    Tests/TokenUsageScannerTests.swift -o .build/token-tests/TokenUsageScannerTests
.build/token-tests/TokenUsageScannerTests
