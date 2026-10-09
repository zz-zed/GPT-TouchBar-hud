#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD="$PWD/.build/diagnostic-upgrade-installer-tests"
mkdir -p "$TEST_BUILD"
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc -module-cache-path "$SWIFT_MODULE_CACHE" \
  Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DiagnosticStore.swift Sources/DiagnosticRecorder.swift \
  Sources/DiagnosticProcessStore.swift Sources/DiagnosticInstallerBridge.swift \
  Sources/AppUpdateModels.swift Sources/AppUpdateProgressChannel.swift \
  Tests/DiagnosticUpgradeInstallerTests.swift -o "$TEST_BUILD/DiagnosticUpgradeInstallerTests"
"$TEST_BUILD/DiagnosticUpgradeInstallerTests"
zsh -n Resources/install-update.sh
