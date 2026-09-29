#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
"${RELEASE_TEST_PYTHON:-python3}" Tests/CIBuildScopeTests.py
"${RELEASE_TEST_PYTHON:-python3}" Tests/PublicReleaseVerificationTests.py
exec "${RELEASE_TEST_PYTHON:-python3}" Tests/ReleaseWorkflowTests.py "$@"
