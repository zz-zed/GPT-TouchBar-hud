#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/design-tests Design/ui-v2/native
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
source scripts/ui-test-shared-build.sh
ui_test_compile Tests/DesignLayoutTests.swift .build/design-tests/DesignLayoutTests
ci_time execute design-layout .build/design-tests/DesignLayoutTests
