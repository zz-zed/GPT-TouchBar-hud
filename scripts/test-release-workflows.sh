#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
exec "${RELEASE_TEST_PYTHON:-python3}" Tests/ReleaseWorkflowTests.py "$@"
