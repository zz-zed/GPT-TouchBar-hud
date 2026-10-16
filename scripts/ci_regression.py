#!/usr/bin/env python3
"""Run the existing regression scripts in order, with timing and original exits."""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import sys

# Frozen from the previously validated workflow; processes and assertions stay intact.
REGRESSION_SUITES = {
    "data": [
        "test-task-status",
        "test-hook-integration",
        "test-token-usage",
        "test-task-reliability",
        "test-account-token-usage",
        "test-verified-quota",
        "test-quota-alerts",
        "test-host-auto-launcher",
        "test-connection-diagnostics",
        "test-diagnostic-logging",
        "test-diagnostic-upgrade-storage",
        "test-diagnostic-upgrade-installer",
        "test-diagnostic-upgrade-recovery",
        "test-host-lifecycle",
        "test-app-termination",
        "test-single-instance",
        "test-app-update",
        "test-app-update-progress",
        "test-github-release-fallback",
        "test-app-update-notifications",
        "test-reset-news-runtime",
        "test-hooks"
    ],
    "interface": [
        "test-hud-material",
        "test-idle-performance",
        "test-status-menu",
        "test-notch-hud",
        "test-notch-presentation",
        "test-touchbar",
        "test-touchbar-layout",
        "test-design-layout"
    ]
}


def run_suite(suite, root, timing_script, environment=None):
    scripts = REGRESSION_SUITES[suite]
    root = Path(root)
    if not (root / timing_script).is_file():
        raise ValueError("Missing timing entry point: " + str(timing_script))
    for script in scripts:
        if not (root / "scripts" / (script + ".sh")).is_file():
            raise ValueError("Missing regression script: " + script)
    environment = dict(os.environ if environment is None else environment)
    for script in scripts:
        env = dict(environment)
        if script == "test-reset-news-runtime":
            temporary = Path(env.get("RUNNER_TEMP", str(root / ".build")))
            env.setdefault("RESET_NEWS_CORE_DIR", str(temporary / ("reset-news-core-runtime-" + platform.machine())))
        print("Running " + script, flush=True)
        result = subprocess.run(
            [sys.executable, str(timing_script), "run", "--phase", "suite", "--label", script,
             "--", "bash", "scripts/" + script + ".sh"], cwd=root, env=env)
        if result.returncode:
            return result.returncode if result.returncode > 0 else 128 - result.returncode
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=tuple(REGRESSION_SUITES), required=True)
    parser.add_argument("--list", action="store_true", help="List the suite without executing it")
    args = parser.parse_args()
    if args.list:
        print("\n".join(REGRESSION_SUITES[args.suite]))
        return 0
    return run_suite(args.suite, Path.cwd(), os.environ.get("CI_TIMING_SCRIPT", "scripts/ci_timing.py"))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        raise SystemExit("Regression entry failed: " + str(error))
