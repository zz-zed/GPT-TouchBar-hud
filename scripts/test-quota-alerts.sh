#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
TEST_BUILD="$PROJECT_DIR/.build/quota-alert-tests"
mkdir -p "$TEST_BUILD"
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DiagnosticTaskPresentation.swift Sources/LimitModels.swift Sources/QuotaAlerts.swift Sources/ResetNewsNotificationController.swift \
  Tests/QuotaAlertTests.swift -o "$TEST_BUILD/QuotaAlertTests"
"$TEST_BUILD/QuotaAlertTests"
