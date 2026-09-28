#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
TEST_BUILD="$PROJECT_DIR/.build/quota-alert-tests"
mkdir -p "$TEST_BUILD/module-cache"
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" \
  -module-cache-path "$TEST_BUILD/module-cache" \
  Sources/LimitModels.swift Sources/QuotaAlerts.swift Sources/ResetNewsNotificationController.swift \
  Tests/QuotaAlertTests.swift -o "$TEST_BUILD/QuotaAlertTests"
"$TEST_BUILD/QuotaAlertTests"
