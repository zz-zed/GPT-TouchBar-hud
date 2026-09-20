#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/hook-core-build.sh
mkdir -p .build/installer-tests
# Real debug and release executables provide two valid signed versions without altering instructions.
swift build --product HookEmitter >/dev/null
build_bin="$(swift build --show-bin-path)"
cp "$build_bin/HookEmitter" .build/installer-tests/HookEmitter.debug
codesign --force --sign - --identifier com.gpt-touchbar-hud.hook-emitter .build/installer-tests/HookEmitter.debug >/dev/null 2>&1
swiftc -parse-as-library "${HOOK_CORE_SWIFT_FLAGS[@]}" Tests/HookInstallerTests.swift -o .build/installer-tests/InstallerTests
.build/installer-tests/InstallerTests "$PWD/build/GPT TouchBar HUD.app/Contents/Helpers/HookEmitter" "$PWD/.build/installer-tests/HookEmitter.debug"
