#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/.build/host-auto-launcher-tests"
mkdir -p "$TEST_DIR/module-cache"
cd "$PROJECT_DIR"

swiftc -swift-version 5 -target "$(uname -m)-apple-macosx11.0" -module-cache-path "$TEST_DIR/module-cache" \
    Sources/AppIdentity.swift Sources/HostAutoLaunchPreferences.swift \
    Sources/HostAutoLauncher.swift Tests/HostAutoLauncherTests.swift \
    -o "$TEST_DIR/HostAutoLauncherTests"
"$TEST_DIR/HostAutoLauncherTests" "$PROJECT_DIR/Resources/gpt-touchbar-hud-launcher.sh"
