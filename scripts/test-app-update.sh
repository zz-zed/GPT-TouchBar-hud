#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/update-tests
source scripts/swift-module-cache.sh
SWIFT_MODULE_CACHE="$(swift_module_cache_path)"
swiftc -module-cache-path "$SWIFT_MODULE_CACHE" Sources/AppUpdateModels.swift Sources/AppUpdateScheduler.swift Sources/AppUpdateReleaseNotes.swift Sources/GitHubReleaseFetcher.swift Tests/AppUpdateTests.swift -o .build/update-tests/AppUpdateTests
.build/update-tests/AppUpdateTests
zsh Tests/AppUpdateInstallerTests.zsh
zsh -n Resources/install-update.sh
# Invalid target must be rejected before waiting, moving files or launching apps.
if zsh Resources/install-update.sh 999999 /tmp/not-an-install.app /tmp/not-a-stage; then
  echo 'FAIL: installer accepted an arbitrary target' >&2
  exit 1
fi
echo 'PASS: updater shell syntax and invalid-target rejection'
