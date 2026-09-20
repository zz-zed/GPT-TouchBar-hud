#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/token-tests/module-cache
source scripts/hook-core-build.sh
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" -O -module-cache-path .build/token-tests/module-cache \
    Sources/TokenUsageScanner.swift Sources/LimitModels.swift \
    Tests/TokenUsageScannerTests.swift -o .build/token-tests/TokenUsageScannerTests
.build/token-tests/TokenUsageScannerTests
