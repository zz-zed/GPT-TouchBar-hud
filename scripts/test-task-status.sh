#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/task-status-tests/module-cache
source scripts/hook-core-build.sh
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" -module-cache-path .build/task-status-tests/module-cache \
  Sources/LimitModels.swift Sources/TaskStatusAppearance.swift Sources/TaskStatusMonitor.swift Tests/TaskStatusTests.swift \
  -o .build/task-status-tests/TaskStatusTests
.build/task-status-tests/TaskStatusTests "$@"
