#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/hook-core-build.sh
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DiagnosticTaskPresentation.swift Sources/LimitModels.swift Sources/TaskStatusMonitor.swift Sources/DiagnosticHookTaskTrace.swift Sources/DiagnosticTaskEngineTrace.swift Sources/TaskMonitoringCoordinator.swift \
    Sources/CodexAppServerClient.swift Sources/AccountTokenUsage.swift \
    Sources/HookExperimentPreferencesController.swift Tests/HookMonitoringIntegrationTests.swift -o .build/hook-core-standalone/IntegrationTests
.build/hook-core-standalone/IntegrationTests
