#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/.build/app-migration-tests"

mkdir -p "$TEST_DIR"
cd "$PROJECT_DIR"

source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc -module-cache-path "$SWIFT_MODULE_CACHE" \
    Sources/AppIdentity.swift Tests/AppMigrationTests.swift \
    -o "$TEST_DIR/AppMigrationTests"
"$TEST_DIR/AppMigrationTests"
