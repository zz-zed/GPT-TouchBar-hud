#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
TEST_BUILD="$PROJECT_DIR/.build/reset-news-runtime-tests"
mkdir -p "$TEST_BUILD/module-cache"
source scripts/reset-news-core-build.sh
swiftc "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" \
  Sources/ResetNewsFeedClient.swift Sources/ResetNewsRepository.swift Sources/ResetNewsMonitor.swift \
  Sources/ResetNewsNotificationController.swift Sources/ResetNewsViewState.swift \
  Tests/ResetNewsRuntimeTests.swift -o "$TEST_BUILD/ResetNewsRuntimeTests"
"$TEST_BUILD/ResetNewsRuntimeTests"
