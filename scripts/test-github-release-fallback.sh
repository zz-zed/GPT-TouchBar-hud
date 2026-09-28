#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/.build/github-release-fallback-tests"
mkdir -p "$TEST_DIR"
cd "$PROJECT_DIR"
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx11.0" \
    Sources/AppUpdateModels.swift Sources/AppUpdateScheduler.swift Sources/GitHubReleaseFetcher.swift \
    Tests/GitHubReleaseFallbackTests.swift -o "$TEST_DIR/GitHubReleaseFallbackTests"
"$TEST_DIR/GitHubReleaseFallbackTests" "$@"
