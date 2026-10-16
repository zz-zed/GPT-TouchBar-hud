#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/reset-news-core-build.sh
cache="$(swift_module_cache_path "$RESET_NEWS_CORE_TARGET" "$RESET_NEWS_CORE_SDK_PATH")"
mkdir -p .build/app-termination-tests
swiftc "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" -module-cache-path "$cache" \
  Sources/MainRunLoopCompletion.swift Sources/ResetNewsRepository.swift Tests/AppTerminationTests.swift \
  -o .build/app-termination-tests/termination
python3 - <<'PY'
import subprocess

for scenario in ('completion', 'deadline', 'late-completion', 'duplicate-completion'):
    result = subprocess.run(
        ['.build/app-termination-tests/termination', scenario],
        capture_output=True, text=True, timeout=8,
    )
    if result.returncode != 0 or f'PASS: native termination {scenario}' not in result.stdout:
        raise SystemExit(f'FAIL: {scenario}, exit {result.returncode}\n{result.stdout}\n{result.stderr}')
    print(result.stdout.strip())
print('PASS: 4 native AppKit termination scenarios')
PY

bash scripts/test-app-lifecycle-termination.sh
