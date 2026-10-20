#!/usr/bin/env python3
"""Pair original and regrouped CI jobs on one runner, using fresh project trees.

Run one suite per runner so each old/new pair shares a host. Combine data and
interface pairs by architecture/sample: max is the regression critical path,
sum is active runner time. Queue/checkout time is outside this controlled metric;
the separate full workflow verifies concurrent scheduling and release gates.
"""
import argparse
import ast
from collections import Counter
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ROOTS = ["Package.swift", "HookCore", "ResetNewsCore", "HookHelper", "Sources", "Tests", "scripts", "Resources"]
WORKFLOW = ".github/workflows/build-dmg.yml"
DIAGNOSTIC = "test-diagnostic-logging"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def layout(text, regression_source=None):
    groups = {"data": [], "interface": []}
    if 'python3 "$CI_REGRESSION_SCRIPT" --suite "$CI_SUITE"' in text:
        if regression_source is None:
            raise ValueError("Unified entry requires its source-versioned suite manifest")
        for statement in ast.parse(regression_source).body:
            if (isinstance(statement, ast.Assign)
                    and any(isinstance(t, ast.Name) and t.id == "REGRESSION_SUITES" for t in statement.targets)):
                groups = ast.literal_eval(statement.value)
                break
    suite = None
    for line in text.splitlines():
        if line.startswith("      - "):
            suite = None
        condition = re.search(r"if: matrix.suite == '(data|interface)'", line)
        if condition:
            suite = condition[1]
        command = re.search(r"--phase suite --label ([\w-]+) -- bash scripts/([\w-]+)\.sh", line)
        if command:
            if suite is None or command[1] != command[2]:
                raise ValueError("Unrecognized regression command: " + line)
            groups[suite].append(command[1])
    calls = [script for scripts in groups.values() for script in scripts]
    # Historical revisions have 29 entries; later source versions add explicit suites.
    expected_count = 30 if "test-app-termination" in calls else 29
    if any(name in calls for name in ("test-installation-maintenance", "test-installation-migration")):
        expected_count += 2
    if set(groups) != {"data", "interface"} or len(calls) != expected_count or len(set(calls)) != expected_count:
        raise ValueError(f"Expected all {expected_count} regression scripts exactly once")
    return groups


def layout_at(revision):
    workflow = git("show", revision + ":" + WORKFLOW).decode()
    source = (git("show", revision + ":scripts/ci_regression.py").decode()
              if 'python3 "$CI_REGRESSION_SCRIPT"' in workflow else None)
    return layout(workflow, source)


def validate_layouts(before, after):
    if Counter(sum(before.values(), [])) != Counter(sum(after.values(), [])):
        raise ValueError("Regression coverage changed")
    if before["data"].count(DIAGNOSTIC) != 1 or DIAGNOSTIC in before["interface"]:
        raise ValueError("Unexpected original diagnostic location")
    if after["data"] != [s for s in before["data"] if s != DIAGNOSTIC]:
        raise ValueError("Other data scripts moved or reordered")
    if after["interface"] != before["interface"] + [DIAGNOSTIC]:
        raise ValueError("Diagnostics must move intact to the end of interface")


def coverage(text, script):
    if script == "test-hooks":
        counts = [int(n) for n in re.findall(r"Test run with (\d+) tests.*?passed after", text)]
        names = sorted(re.findall(r"✔ Test (?!run with)(.*?) passed after [\d.]+ seconds", text))
        if sum(counts) != 230 or len(names) != 230:
            raise ValueError("All 230 core tests must pass")
        return {"testCount": sum(counts), "passedTestNames": names}
    checks = sorted(re.sub(r"; \d+ presented frames$", "; <variable> presented frames", line)
                    for line in text.splitlines()
                    if line.startswith(("PASS:", "PASS ", "RESULT checks=")) or
                    "checks passed" in line or "tests passed:" in line)
    if not checks:
        raise ValueError("No test success evidence: " + script)
    return {"checks": checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--suite", choices=["data", "interface"], required=True)
    parser.add_argument("--first-mode", choices=["original", "regrouped"], default="original")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    baseline, candidate = [git("rev-parse", ref + "^{commit}").decode().strip()
                           for ref in (args.baseline, args.candidate)]
    # Both layouts execute the identical candidate instrumentation and scripts.
    # No production Swift or existing Swift fixture may change in this batch.
    changed = git("diff", "--name-only", baseline, candidate, *ROOTS).decode().splitlines()
    if any(p.startswith(("Sources/", "HookCore/", "ResetNewsCore/", "HookHelper/")) or
           (p.startswith("Tests/") and p.endswith(".swift")) or p == "Package.swift" for p in changed):
        raise ValueError("Production/build graph or Swift test bodies changed")
    layouts = {mode: layout_at(sha)
               for mode, sha in [("original", baseline), ("regrouped", candidate)]}
    validate_layouts(layouts["original"], layouts["regrouped"])
    snapshot = git("archive", candidate, *ROOTS)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    report = {"baseline": baseline, "candidate": candidate, "architecture": platform.machine(),
              "suite": args.suite, "layouts": layouts, "projectCaches": "fresh per mode and suite",
              "systemCaches": "not cleared", "sourceArchiveSHA256": hashlib.sha256(snapshot).hexdigest(),
              "compiler": subprocess.check_output(["xcrun", "swiftc", "--version"], stderr=subprocess.STDOUT, text=True).strip(),
              "sdk": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip(),
              "modes": {}, "failures": [], "coverageMismatches": []}
    destination = args.output / "comparison.json"
    def save():
        destination.write_text(json.dumps(report, indent=2) + "\n")
    save()
    order = [args.first_mode, "regrouped" if args.first_mode == "original" else "original"]
    expected = {}
    for mode in order:
        with tempfile.TemporaryDirectory(prefix="hud-group-benchmark-") as temporary:
            tree = Path(temporary)
            with tarfile.open(fileobj=io.BytesIO(snapshot)) as archive:
                for item in archive.getmembers():
                    if Path(item.name).is_absolute() or ".." in Path(item.name).parts or item.issym() or item.islnk():
                        raise ValueError("Unsafe source archive entry")
                archive.extractall(tree)
            timings = args.output / (mode + "-timings")
            environment = dict(os.environ, CI_TIMING_DIR=str(timings))
            for key in ("CI_TIMING_PARENT_ID", "CI_TIMING_SCRIPT", "GITHUB_STEP_SUMMARY", "RESET_NEWS_CORE_DIR",
                        "HOOK_CORE_DIR", "HUD_CORE_TESTS_ONLY", "HUD_SHARED_UI_TESTS"):
                environment.pop(key, None)
            result = {"rows": [], "complete": False}
            report["modes"][mode] = result
            started = time.monotonic()
            if args.suite == "data":
                with (args.output / (mode + "-graph.log")).open("w") as output:
                    subprocess.run(["python3", "Tests/CoreTestBuildGraphTests.py"], cwd=tree,
                                   env=environment, stdout=output, stderr=subprocess.STDOUT, check=True)
            result["graphSeconds"] = round(time.monotonic() - started, 6)
            for script in layouts[mode][args.suite]:
                env = dict(environment)
                if script == "test-reset-news-runtime":
                    env["RESET_NEWS_CORE_DIR"] = str(tree / ".build/isolated-runtime-core")
                log = args.output / f"{mode}-{script}.log"
                command = ["python3", "scripts/ci_timing.py", "run", "--phase", "suite", "--label", script,
                           "--", "bash", "scripts/" + script + ".sh"]
                step_started = time.monotonic()
                with log.open("w") as output:
                    process = subprocess.run(command, cwd=tree, env=env, stdout=output, stderr=subprocess.STDOUT)
                row = {"script": script, "seconds": round(time.monotonic() - step_started, 6),
                       "exitCode": process.returncode, "log": log.name}
                result["rows"].append(row)
                save()
                print(json.dumps({"mode": mode, **row}), flush=True)
                if process.returncode:
                    report["failures"].append({"mode": mode, "script": script, "exitCode": process.returncode})
                try:
                    row["coverage"] = coverage(log.read_text().replace(str(tree), "<SOURCE>"), script)
                except ValueError as error:
                    row["coverageError"] = str(error)
                    row["coverage"] = None
                if process.returncode == 0 and row["coverage"] is not None:
                    if script in expected and expected[script] != row["coverage"]:
                        report["coverageMismatches"].append(script)
                    expected[script] = row["coverage"]
                elif not process.returncode:
                    report["failures"].append({"mode": mode, "script": script, "reason": row["coverageError"]})
                save()
            result["seconds"] = round(time.monotonic() - started, 6)
            records = [json.loads(p.read_text()) for p in timings.glob("*.json")]
            suites = [r for r in records if r["phase"] == "suite"]
            if Counter(r["label"] for r in suites) != Counter(layouts[mode][args.suite]):
                raise ValueError("Missing or duplicate executed suites")
            if len({r["processID"] for r in suites}) != len(suites):
                raise ValueError("Process isolation check failed")
            result["testsPassed"] = all(r["exitCode"] == 0 for r in records) and all(r["coverage"] is not None for r in result["rows"])
            result["complete"] = True
            result["independentSuiteProcesses"] = True
            save()
    report["complete"] = True
    report["testsPassed"] = all(mode["testsPassed"] for mode in report["modes"].values())
    report["sameSuiteCoverageEquivalent"] = report["testsPassed"] and not report["coverageMismatches"]
    save()
    # Attempt every script and both layouts, but never turn a failure into success.
    if not report["sameSuiteCoverageEquivalent"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
