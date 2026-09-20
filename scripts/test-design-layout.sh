#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/design-tests/module-cache Design/ui-v2/native
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
source scripts/hook-core-build.sh
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" -module-cache-path .build/design-tests/module-cache "${sources[@]}" Tests/DesignLayoutTests.swift -o .build/design-tests/DesignLayoutTests
.build/design-tests/DesignLayoutTests
