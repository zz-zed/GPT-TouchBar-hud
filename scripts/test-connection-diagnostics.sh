#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/connection-diagnostics-tests
source scripts/hook-core-build.sh
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path "$(uname -m)-apple-macosx11.0")"
swiftc -target "$(uname -m)-apple-macosx11.0" "${HOOK_CORE_SWIFT_FLAGS[@]}" \
    -module-cache-path "$SWIFT_MODULE_CACHE" \
    Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DiagnosticProcessStore.swift Sources/DiagnosticStore.swift Sources/DiagnosticRecorder.swift Sources/DiagnosticEnvironment.swift Sources/DiagnosticTaskTraceCoverage.swift Sources/DiagnosticExport.swift Sources/DiagnosticTaskPresentation.swift Sources/LimitModels.swift Sources/CodexAppServerClient.swift Sources/AccountTokenUsage.swift \
    Sources/ConnectionDiagnostics.swift Sources/ConnectionDiagnosticsWindowController.swift \
    Tests/ConnectionDiagnosticsTests.swift -o .build/connection-diagnostics-tests/ConnectionDiagnosticsTests
.build/connection-diagnostics-tests/ConnectionDiagnosticsTests
