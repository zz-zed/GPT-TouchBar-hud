#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/.build/host-lifecycle-tests"

mkdir -p "$TEST_DIR/module-cache"
cd "$PROJECT_DIR"

swiftc -module-cache-path "$TEST_DIR/module-cache" \
    Sources/HostLifecycleMonitor.swift Tests/HostLifecycleMonitorTests.swift \
    -o "$TEST_DIR/HostLifecycleMonitorTests"
"$TEST_DIR/HostLifecycleMonitorTests"
