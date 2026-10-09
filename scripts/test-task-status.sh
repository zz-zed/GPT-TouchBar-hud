#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/task-status-tests
source scripts/hook-core-build.sh
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" -module-cache-path "$SWIFT_MODULE_CACHE" \
  Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DiagnosticTaskPresentation.swift Sources/LimitModels.swift Sources/HUDPresentation.swift Sources/TaskStatusAppearance.swift \
  Sources/TaskStatusMonitor.swift Sources/TaskCompletionFeedbackController.swift \
  Tests/TaskStatusTests.swift \
  -o .build/task-status-tests/TaskStatusTests
.build/task-status-tests/TaskStatusTests "$@"
