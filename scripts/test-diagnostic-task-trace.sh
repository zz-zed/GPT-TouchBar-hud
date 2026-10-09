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
# Retired legacy-controller fixtures are preserved under Tests for historical evidence.
# Current production coverage exercises both modes, backlog, >32 identities and persistence.
bash scripts/test-unified-diagnostic-task-trace.sh
