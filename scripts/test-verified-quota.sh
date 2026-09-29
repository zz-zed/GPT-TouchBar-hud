#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/verified-quota-tests
source scripts/hook-core-build.sh
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path "$(uname -m)-apple-macosx11.0")"
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx11.0" "${HOOK_CORE_SWIFT_FLAGS[@]}" -module-cache-path "$SWIFT_MODULE_CACHE" \
  Sources/LimitModels.swift Sources/CodexAppServerClient.swift Sources/AccountTokenUsage.swift \
  Sources/VerifiedQuotaReader.swift Sources/RateLimitStore.swift Tests/VerifiedQuotaTests.swift \
  -o .build/verified-quota-tests/VerifiedQuotaTests
.build/verified-quota-tests/VerifiedQuotaTests
