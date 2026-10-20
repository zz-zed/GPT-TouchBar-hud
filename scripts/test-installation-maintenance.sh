#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-module-cache.sh
cache="$(swift_module_cache_path)"
build_directory="$PWD/.build/installation-maintenance-tests"
mkdir -p "$build_directory"
swiftc -module-cache-path "$cache" Sources/AppInstallationMaintenance.swift \
    Tests/InstallationMaintenanceProbe.swift -o "$build_directory/probe"
zsh -n Tests/InstallationMaintenanceFixture.zsh
python3 Tests/InstallationMaintenanceTests.py "$build_directory/probe"
