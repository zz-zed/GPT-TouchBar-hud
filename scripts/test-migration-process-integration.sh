#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Normal developer runs compile only. Actual GUI registration/launch is confined
# to disposable GitHub runners and must also pass the Python runner guard.
if [[ $# -gt 0 ]]; then
  python3 scripts/test-migration-process-integration.py "$@"
elif [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  python3 scripts/test-migration-process-integration.py --execute-disposable-ci
else
  python3 scripts/test-migration-process-integration.py --compile-only
fi
