#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/update-tests
swiftc Sources/AppUpdateModels.swift Tests/AppUpdateTests.swift -o .build/update-tests/AppUpdateTests
.build/update-tests/AppUpdateTests
zsh -n Resources/install-update.sh
# Invalid target must be rejected before waiting, moving files or launching apps.
if zsh Resources/install-update.sh 999999 /tmp/not-an-install.app /tmp/not-a-stage; then
  echo 'FAIL: installer accepted an arbitrary target' >&2
  exit 1
fi
echo 'PASS: updater shell syntax and invalid-target rejection'
