#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/unified-diagnostic-task-trace
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
swiftc -target "$(uname -m)-apple-macosx11.0" -module-cache-path "$SWIFT_MODULE_CACHE" \
    "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" "${sources[@]}" \
    Tests/UnifiedDiagnosticTaskTraceTests.swift -o .build/unified-diagnostic-task-trace/tests
.build/unified-diagnostic-task-trace/tests
