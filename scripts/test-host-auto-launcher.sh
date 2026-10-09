#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/.build/host-auto-launcher-tests"
mkdir -p "$TEST_DIR"
cd "$PROJECT_DIR"

source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path "$(uname -m)-apple-macosx11.0")"
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx11.0" -module-cache-path "$SWIFT_MODULE_CACHE" \
    Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DiagnosticProcessStore.swift Sources/DiagnosticStore.swift Sources/DiagnosticRecorder.swift Sources/AppIdentity.swift Sources/HostAutoLaunchPreferences.swift \
    Sources/HostAutoLauncher.swift Tests/HostAutoLauncherTests.swift \
    -o "$TEST_DIR/HostAutoLauncherTests"
"$TEST_DIR/HostAutoLauncherTests" "$PROJECT_DIR/Resources/gpt-touchbar-hud-launcher.sh"
