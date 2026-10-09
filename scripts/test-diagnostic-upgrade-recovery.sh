#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-module-cache.sh
cache="$(swift_module_cache_path "$(uname -m)-apple-macosx11.0")"
mkdir -p .build/diagnostic-upgrade-tests
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx11.0" -module-cache-path "$cache" \
  Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DiagnosticProcessStore.swift Sources/DiagnosticStore.swift Sources/DiagnosticRecorder.swift \
  Sources/DiagnosticInstallerBridge.swift Sources/DiagnosticUpgradeRecovery.swift \
  Sources/AppUpdateProgressChannel.swift Sources/AppUpdateModels.swift Sources/AppIdentity.swift \
  Tests/DiagnosticUpgradeRecoveryTests.swift -o .build/diagnostic-upgrade-tests/recovery
.build/diagnostic-upgrade-tests/recovery
