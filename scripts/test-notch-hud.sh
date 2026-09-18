#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/notch-tests/module-cache build
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
swiftc -module-cache-path .build/notch-tests/module-cache "${sources[@]}" Tests/NotchHUDTests.swift -o .build/notch-tests/NotchHUDTests
.build/notch-tests/NotchHUDTests
