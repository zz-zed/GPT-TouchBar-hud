#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p build/task-reliability/integration
source scripts/hook-core-build.sh
shasum -a 256 HookCore/*.swift Sources/LimitModels.swift Sources/HUDPresentation.swift \
  Sources/TaskStatusAppearance.swift Sources/TaskStatusMonitor.swift Sources/DiagnosticTaskEngineTrace.swift Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DiagnosticTaskPresentation.swift Sources/TaskMonitoringCoordinator.swift \
  Tests/TaskReliabilityIntegrationTests.swift > build/task-reliability/integration/source-sha256.txt
swiftc -target "$(uname -m)-apple-macosx11.0" "${HOOK_CORE_SWIFT_FLAGS[@]}" \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  Sources/LimitModels.swift Sources/HUDPresentation.swift Sources/TaskStatusAppearance.swift \
  Sources/TaskStatusMonitor.swift Sources/DiagnosticTaskEngineTrace.swift Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DiagnosticTaskPresentation.swift Sources/TaskMonitoringCoordinator.swift \
  Tests/TaskReliabilityIntegrationTests.swift \
  -o build/task-reliability/integration/TaskReliabilityIntegrationTests
set +e
build/task-reliability/integration/TaskReliabilityIntegrationTests "$@" > build/task-reliability/integration/output.txt 2>&1
TEST_EXIT=$?
set -e
printf '%s\n' "$TEST_EXIT" > build/task-reliability/integration/exit-code.txt
cat build/task-reliability/integration/output.txt
exit "$TEST_EXIT"
