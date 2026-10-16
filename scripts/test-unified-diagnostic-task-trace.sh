#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/unified-diagnostic-task-trace
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
# Real monitoring, persistence, export and all four production consumer surfaces.
# Keep this dependency list explicit; unrelated app/update/settings entry points
# must not be compiled just to run this integration fixture.
sources=(
    Sources/AccountTokenUsage.swift
    Sources/AppIdentity.swift
    Sources/AppUpdateModels.swift
    Sources/CodexAppServerClient.swift
    Sources/CompactHUDPanel.swift
    Sources/CompactHUDViewController.swift
    Sources/ConnectionDiagnostics.swift
    Sources/DesignTokens.swift
    Sources/DiagnosticEnvironment.swift
    Sources/DiagnosticEvent.swift
    Sources/DiagnosticExport.swift
    Sources/DiagnosticProcessStore.swift
    Sources/DiagnosticRecorder.swift
    Sources/DiagnosticStore.swift
    Sources/DiagnosticTaskEngineTrace.swift
    Sources/DiagnosticTaskPresentation.swift
    Sources/DiagnosticTaskTrace.swift
    Sources/DiagnosticTaskTraceCoverage.swift
    Sources/ForecastPresentation.swift
    Sources/HUDAppearance.swift
    Sources/HUDPresentation.swift
    Sources/LimitModels.swift
    Sources/NotchContentAdapter.swift
    Sources/NotchLayout.swift
    Sources/NotchMotion.swift
    Sources/NotchPresentationModel.swift
    Sources/ResetForecastIndicator.swift
    Sources/ResetNewsNotificationController.swift
    Sources/ResetNewsViewState.swift
    Sources/StatusSummaryView.swift
    Sources/TaskMonitoringCoordinator.swift
    Sources/TaskStatusAppearance.swift
    Sources/TaskStatusMonitor.swift
    Sources/TouchBarRateLimitsView.swift
)
swiftc -target "$(uname -m)-apple-macosx11.0" -module-cache-path "$SWIFT_MODULE_CACHE" \
    "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" "${sources[@]}" \
    Tests/UnifiedDiagnosticTaskTraceTests.swift -o .build/unified-diagnostic-task-trace/tests
ci_time execute unified-diagnostic-task-trace .build/unified-diagnostic-task-trace/tests
