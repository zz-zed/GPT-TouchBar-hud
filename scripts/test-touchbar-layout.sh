#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/layout-tests
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
source scripts/hook-core-build.sh
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path "$(uname -m)-apple-macosx11.0" "$SDK_PATH")"
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" -swift-version 5 -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx11.0" \
    -module-cache-path "$SWIFT_MODULE_CACHE" \
    Sources/DiagnosticEvent.swift Sources/DiagnosticTaskTrace.swift Sources/DesignTokens.swift Sources/ResetForecastIndicator.swift Sources/TouchBarRateLimitsView.swift Sources/TaskStatusAppearance.swift Sources/SegmentedBatteryBar.swift \
    Sources/SystemTouchBarPresenter.swift Sources/DiagnosticTaskPresentation.swift Sources/LimitModels.swift Tests/TouchBarLayoutTests.swift \
    -o .build/layout-tests/TouchBarLayoutTests
.build/layout-tests/TouchBarLayoutTests
