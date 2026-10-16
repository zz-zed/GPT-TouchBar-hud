#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/hook-core-build.sh
source scripts/reset-news-core-build.sh
cache="$(swift_module_cache_path "$RESET_NEWS_CORE_TARGET" "$RESET_NEWS_CORE_SDK_PATH")"
mkdir -p .build/app-lifecycle-termination-tests
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/main.swift ]] || sources+=("$source")
done
swiftc "${HOOK_CORE_SWIFT_FLAGS[@]}" "${RESET_NEWS_CORE_SWIFT_FLAGS[@]}" \
    -module-cache-path "$cache" -parse-as-library \
    "${sources[@]}" Tests/AppLifecycleTerminationTests.swift \
    -o .build/app-lifecycle-termination-tests/termination

python3 - <<'PY'
import subprocess

try:
    result = subprocess.run(
        ['.build/app-lifecycle-termination-tests/termination'],
        capture_output=True, text=True, timeout=8,
    )
except subprocess.TimeoutExpired as error:
    raise SystemExit(f'FAIL: native lifecycle termination exceeded 8 seconds\n{error.stdout}\n{error.stderr}')

marker = 'PASS: native lifecycle coordinator termination'
pass_lines = [line for line in result.stdout.splitlines() if line.startswith('PASS:')]
if result.returncode != 0 or pass_lines != [marker] or 'FAIL:' in result.stdout + result.stderr:
    raise SystemExit(f'FAIL: native lifecycle termination, exit {result.returncode}\n{result.stdout}\n{result.stderr}')
print(marker)
PY
