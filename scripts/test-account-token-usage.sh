#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/account-usage-tests/module-cache
test_source=Tests/AccountTokenUsageTests.swift
if [[ "${1:-}" == "--live" ]]; then
    test_source=Tests/AccountTokenUsageSmoke.swift
fi
source scripts/hook-core-build.sh
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" -module-cache-path .build/account-usage-tests/module-cache \
    Sources/LimitModels.swift Sources/CodexAppServerClient.swift Sources/AccountTokenUsage.swift \
    "$test_source" -o .build/account-usage-tests/AccountTokenUsageTests
.build/account-usage-tests/AccountTokenUsageTests
