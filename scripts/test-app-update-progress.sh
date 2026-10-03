#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD="$PWD/.build/update-progress-tests"
mkdir -p "$TEST_BUILD"
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc -module-cache-path "$SWIFT_MODULE_CACHE" \
    Sources/AppUpdateModels.swift Sources/AppIdentity.swift Sources/AppUpdateDownload.swift \
    Sources/AppUpdateProgressChannel.swift Sources/AppUpdateProgressWindowController.swift \
    Sources/AppUpdateProgressHelper.swift Sources/AppUpdateInstallation.swift \
    Tests/AppUpdateProgressTests.swift -o "$TEST_BUILD/AppUpdateProgressTests"
python3 Tests/app_update_download_server.py "$TEST_BUILD/AppUpdateProgressTests"
