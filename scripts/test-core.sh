#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# The list is also the execution plan: --list needs no Swift/macOS installation.
core_fixtures=(
    TaskStatusTests TokenUsageScannerTests AccountTokenUsageTests VerifiedQuotaTests
    QuotaAlertTests HostAutoLauncherTests HostLifecycleMonitorTests AppLifecycleStateTests
    AppUpdateTests GitHubReleaseFallbackTests AppUpdateNotificationTests AppMigrationTests
)
[[ $# -le 1 ]] || { echo 'Only one option is accepted' >&2; exit 2; }
case "${1:-}" in
    --list)
        printf '%s\n' UpdateCompatibilityContract HookCoreTests ResetNewsCoreTests "${core_fixtures[@]}" \
            AppUpdateInstallerTests NotchModelChecks SingleInstanceLockTests
        exit 0 ;;
    ''|--smoke) ;;
    *) echo "Usage: bash scripts/test-core.sh [--smoke|--list]" >&2; exit 2 ;;
esac
[[ "$(uname -s)" == Darwin ]] || { echo 'Core executable checks require native macOS' >&2; exit 1; }
# Fine-grained performance instrumentation belongs to the optional full suite.
unset CI_TIMING_DIR CI_TIMING_PARENT_ID

run_bounded() {
    python3 - "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout = float(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(command, start_new_session=True)

def terminate(signum, _frame=None):
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=2)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        pass
    # Descendants can outlive the direct child. Only this fresh group is owned.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)
try:
    result = process.wait(timeout=timeout)
except subprocess.TimeoutExpired:
    print(f'FAIL: {command[0]} exceeded {timeout:g}s', file=sys.stderr, flush=True)
    try:
        terminate(signal.SIGTERM)
    except SystemExit:
        raise SystemExit(124)
raise SystemExit(result if result >= 0 else 128 - result)
PY
}

if [[ "${1:-}" == --smoke ]]; then
    # Consume the just-built native Helper. No application test module is built.
    app="${HUD_APP_DIR:-$PWD/build/GPT TouchBar HUD.app}"
    run_bounded 20 python3 Tests/NativeHelperSmokeTests.py "$app/Contents/Helpers/HookEmitter"
    run_bounded 60 bash scripts/test-single-instance.sh
    echo 'PASS: native Helper IPC and single-instance file/process smoke'
    exit 0
fi

# Keep every existing HookCore/ResetNewsCore assertion. The next fixtures extend
# this coverage to quota, updates, application lifecycle and presentation models.
python3 scripts/check-update-compatibility.py
run_bounded 240 bash scripts/test-hooks.sh
source scripts/core-test-build.sh
for fixture in "${core_fixtures[@]}"; do
    executable="$CORE_TEST_DIR/bin/$fixture"
    core_test_compile "$executable" "Tests/$fixture.swift"
    echo "Running $fixture"
    if [[ "$fixture" == HostAutoLauncherTests ]]; then
        run_bounded 30 "$executable" "$PWD/Resources/gpt-touchbar-hud-launcher.sh"
    else
        run_bounded 30 "$executable"
    fi
done

# The current installer's deterministic file-state/rollback cases are cheap and
# remain mandatory. Real packaged historical-client upgrades belong to verify.
run_bounded 30 zsh Tests/AppUpdateInstallerTests.zsh
zsh -n Resources/install-update.sh
if run_bounded 5 zsh Resources/install-update.sh 999999 /tmp/not-an-install.app /tmp/not-a-stage; then
    echo 'FAIL: installer accepted an arbitrary target' >&2
    exit 1
else
    rejected=$?
    [[ "$rejected" == 2 ]] || { echo "FAIL: unexpected installer rejection status $rejected" >&2; exit 1; }
fi

core_test_compile "$CORE_TEST_DIR/bin/NotchModelChecks" \
    Tests/CoreNotchModelMain.swift Tests/NotchHarness/NotchFixtureSupport.swift \
    Tests/NotchHarness/NotchModelChecks.swift
run_bounded 30 "$CORE_TEST_DIR/bin/NotchModelChecks"
run_bounded 60 bash scripts/test-single-instance.sh
echo 'PASS: core business, lifecycle, update, Hook and pure presentation checks'
