#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/diagnostic-task-trace-tests
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
source scripts/swift-module-cache.sh
target="$(uname -m)-apple-macosx11.0"
flags=(-swift-version 5 -target "$target" -module-cache-path "$(swift_module_cache_path "$target")")
core=(Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DiagnosticProcessStore.swift Sources/DiagnosticStore.swift Sources/DiagnosticRecorder.swift)
swiftc "${flags[@]}" "${core[@]}" Tests/DiagnosticTaskTraceProtocolTests.swift -o .build/diagnostic-task-trace-tests/protocol
.build/diagnostic-task-trace-tests/protocol
swiftc "${flags[@]}" "${HOOK_CORE_SWIFT_FLAGS[@]}" Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift \
    Sources/DiagnosticTaskPresentation.swift Sources/LimitModels.swift Sources/HUDPresentation.swift Sources/TaskStatusAppearance.swift \
    Sources/TaskStatusMonitor.swift Sources/TaskCompletionFeedbackController.swift Tests/DiagnosticTaskTraceLegacyTests.swift \
    -o .build/diagnostic-task-trace-tests/legacy
.build/diagnostic-task-trace-tests/legacy
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
swiftc "${flags[@]}" -D DIAGNOSTIC_TRACE_BUNDLE "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" "${sources[@]}" \
    Tests/DiagnosticTaskTracePipelineSupport.swift Tests/DiagnosticTaskTraceLegacyExportTests.swift \
    Tests/DiagnosticTaskTraceHookExportTests.swift Tests/DiagnosticTaskTraceDisplayTests.swift Tests/DiagnosticTaskTraceDeliveryTests.swift \
    Tests/DiagnosticTaskTracePipelineMain.swift -o .build/diagnostic-task-trace-tests/pipeline
.build/diagnostic-task-trace-tests/pipeline
