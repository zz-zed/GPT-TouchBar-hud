#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Synthetic HTTP responses, an in-memory credential vault, and native UI fixtures.
# Never reads a real API credential or sends a live API request.
source scripts/core-test-build.sh
for fixture in APICostTests APICostUITests; do
    core_test_compile "$CORE_TEST_DIR/bin/$fixture" "Tests/$fixture.swift"
    python3 Tests/run_status_menu_tests.py --timeout-seconds 60 "$CORE_TEST_DIR/bin/$fixture"
done
