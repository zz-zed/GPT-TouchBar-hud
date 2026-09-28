#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/verified-quota-tests/module-cache
source scripts/hook-core-build.sh
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx11.0" "${HOOK_CORE_SWIFT_FLAGS[@]}" -module-cache-path .build/verified-quota-tests/module-cache \
  Sources/LimitModels.swift Sources/CodexAppServerClient.swift Sources/AccountTokenUsage.swift \
  Sources/VerifiedQuotaReader.swift Sources/RateLimitStore.swift Tests/VerifiedQuotaTests.swift \
  -o .build/verified-quota-tests/VerifiedQuotaTests
.build/verified-quota-tests/VerifiedQuotaTests
