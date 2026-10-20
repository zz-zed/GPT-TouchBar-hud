#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
"${RELEASE_TEST_PYTHON:-python3}" Tests/CITimingTests.py
"${RELEASE_TEST_PYTHON:-python3}" Tests/UISharedBuildKeyTests.py
"${RELEASE_TEST_PYTHON:-python3}" Tests/CIGroupingBenchmarkTests.py
"${RELEASE_TEST_PYTHON:-python3}" Tests/CIBuildScopeTests.py
"${RELEASE_TEST_PYTHON:-python3}" Tests/CIGateTests.py
"${RELEASE_TEST_PYTHON:-python3}" Tests/CIRegressionTests.py
"${RELEASE_TEST_PYTHON:-python3}" Tests/PublicReleaseVerificationTests.py
"${RELEASE_TEST_PYTHON:-python3}" Tests/UpdateCompatibilityContractTests.py
exec "${RELEASE_TEST_PYTHON:-python3}" Tests/ReleaseWorkflowTests.py "$@"
