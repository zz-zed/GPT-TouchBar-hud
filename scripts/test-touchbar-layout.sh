#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/layout-tests/module-cache
swiftc -module-cache-path .build/layout-tests/module-cache \
    Sources/TouchBarRateLimitsView.swift Sources/SegmentedBatteryBar.swift \
    Sources/SystemTouchBarPresenter.swift Sources/LimitModels.swift Tests/TouchBarLayoutTests.swift \
    -o .build/layout-tests/TouchBarLayoutTests
.build/layout-tests/TouchBarLayoutTests
