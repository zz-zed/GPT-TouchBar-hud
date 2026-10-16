#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/.build/app-lifecycle-state-tests"

mkdir -p "$TEST_DIR"
cd "$PROJECT_DIR"

source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc -module-cache-path "$SWIFT_MODULE_CACHE" \
    Sources/AppLifecycleState.swift Tests/AppLifecycleStateTests.swift \
    -o "$TEST_DIR/AppLifecycleStateTests"
"$TEST_DIR/AppLifecycleStateTests"
