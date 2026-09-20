#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/.build/touchbar-tests"
TEST_APP="$TEST_DIR/TouchBarTests.app"
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_DIR/module-cache"
cd "$PROJECT_DIR"

source scripts/hook-core-build.sh
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" -sdk "$SDK_PATH" -module-cache-path "$TEST_DIR/module-cache" \
    Sources/SystemTouchBarPresenter.swift Sources/PersistentTouchBarController.swift \
    Sources/DesignTokens.swift Sources/TouchBarRateLimitsView.swift Sources/TaskStatusAppearance.swift Sources/SegmentedBatteryBar.swift \
    Sources/LimitModels.swift Sources/LocalTokenUsageReader.swift Sources/TokenUsageScanner.swift \
    Sources/CompactHUDPanel.swift Sources/CompactHUDViewController.swift Sources/HUDAppearance.swift \
    Tests/PersistentTouchBarTests.swift \
    -o "$TEST_APP/Contents/MacOS/TouchBarTests"
cp Tests/TouchBarTests-Info.plist "$TEST_APP/Contents/Info.plist"
"$TEST_APP/Contents/MacOS/TouchBarTests" "$@"
