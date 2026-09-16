#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/.build/app-migration-tests"

mkdir -p "$TEST_DIR/module-cache"
cd "$PROJECT_DIR"

swiftc -module-cache-path "$TEST_DIR/module-cache" \
    Sources/AppIdentity.swift Tests/AppMigrationTests.swift \
    -o "$TEST_DIR/AppMigrationTests"
"$TEST_DIR/AppMigrationTests"
