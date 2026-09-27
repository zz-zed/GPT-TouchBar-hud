#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=".build/single-instance-tests/${HUD_TEST_ARCH:-$(uname -m)}"
mkdir -p "$test_dir/module-cache"
swiftc -O -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target "${HUD_TEST_ARCH:-$(uname -m)}-apple-macosx11.0" \
    -module-cache-path "$test_dir/module-cache" \
    Sources/AppIdentity.swift Sources/SingleInstanceLock.swift Tests/SingleInstanceLockProbe.swift \
    -o "$test_dir/SingleInstanceLockProbe"
python3 Tests/SingleInstanceLockTests.py "$test_dir/SingleInstanceLockProbe"
