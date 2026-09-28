#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/connection-diagnostics-tests/module-cache
source scripts/hook-core-build.sh
swiftc -target "$(uname -m)-apple-macosx11.0" "${HOOK_CORE_SWIFT_FLAGS[@]}" \
    -module-cache-path .build/connection-diagnostics-tests/module-cache \
    Sources/LimitModels.swift Sources/CodexAppServerClient.swift Sources/AccountTokenUsage.swift \
    Sources/ConnectionDiagnostics.swift Sources/ConnectionDiagnosticsWindowController.swift \
    Tests/ConnectionDiagnosticsTests.swift -o .build/connection-diagnostics-tests/ConnectionDiagnosticsTests
.build/connection-diagnostics-tests/ConnectionDiagnosticsTests
