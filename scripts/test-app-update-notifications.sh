#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
TEST_BUILD="$PROJECT_DIR/.build/app-update-notification-tests"
mkdir -p "$TEST_BUILD"
source scripts/reset-news-core-build.sh
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" -module-cache-path "$SWIFT_MODULE_CACHE" \
  Sources/AppUpdateModels.swift Sources/AppUpdateNotificationController.swift \
  Sources/ResetNewsNotificationController.swift Tests/AppUpdateNotificationTests.swift \
  -o "$TEST_BUILD/AppUpdateNotificationTests"
"$TEST_BUILD/AppUpdateNotificationTests"
