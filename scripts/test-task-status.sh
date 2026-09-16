#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/task-status-tests/module-cache
swiftc -module-cache-path .build/task-status-tests/module-cache \
  Sources/LimitModels.swift Sources/TaskStatusMonitor.swift Tests/TaskStatusTests.swift \
  -o .build/task-status-tests/TaskStatusTests
.build/task-status-tests/TaskStatusTests "$@"
