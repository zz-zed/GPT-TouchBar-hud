#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/account-usage-tests
test_source=Tests/AccountTokenUsageTests.swift
if [[ "${1:-}" == "--live" ]]; then
    test_source=Tests/AccountTokenUsageSmoke.swift
fi
source scripts/hook-core-build.sh
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" -module-cache-path "$SWIFT_MODULE_CACHE" \
    Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DiagnosticTaskPresentation.swift Sources/LimitModels.swift Sources/CodexAppServerClient.swift Sources/AccountTokenUsage.swift \
    "$test_source" -o .build/account-usage-tests/AccountTokenUsageTests
.build/account-usage-tests/AccountTokenUsageTests
