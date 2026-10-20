#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-module-cache.sh
out=".build/phase2-migration/${HUD_TEST_ARCH:-$(uname -m)}"
mkdir -p "$out"
swiftc -parse-as-library -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "${HUD_TEST_ARCH:-$(uname -m)}-apple-macosx11.0" \
  -module-cache-path "$(swift_module_cache_path "${HUD_TEST_ARCH:-$(uname -m)}-apple-macosx11.0")" \
  Sources/AppInstallationMigration.swift Sources/AppInstallationMaintenance.swift \
  Sources/AppMigrationMacOSDriver.swift Sources/AppMigrationRuntime.swift \
  Sources/AppIdentity.swift Sources/AppUpdateModels.swift Sources/AppUpdateProgressChannel.swift \
  Sources/HostAutoLauncher.swift Sources/HostAutoLaunchPreferences.swift \
  Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DiagnosticProcessStore.swift \
  Sources/DiagnosticStore.swift Sources/DiagnosticRecorder.swift Tests/AppInstallationMigrationTests.swift \
  -o "$out/MigrationTests"
"$out/MigrationTests"
