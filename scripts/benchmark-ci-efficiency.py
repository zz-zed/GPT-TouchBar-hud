#!/usr/bin/env python3
"""Compare core and diagnostic scripts in fresh, isolated source snapshots.

Run sequentially: concurrent compilers would invalidate the comparison. The
candidate's bounded startup fixture is applied to both arms and its digest is
recorded. System/OS caches are not purged; every project build directory is new.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ROOTS = ["Package.swift", "HookCore", "ResetNewsCore", "HookHelper", "Sources", "Tests", "scripts", "Resources"]
FIXTURE = "Tests/UnifiedDiagnosticTaskTraceTests.swift"
SCRIPTS = ["test-hooks", "test-diagnostic-logging"]


def git(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=ROOT)


def coverage(log, script):
    if script == "test-hooks":
        counts = [int(value) for value in re.findall(r"Test run with (\d+) tests.*?passed after", log)]
        names = sorted(re.findall(r"✔ Test (?!run with)(.*?) passed after [\d.]+ seconds", log))
        return {"testCount": sum(counts), "passedTestNames": names}
    return {"checks": sorted(line for line in log.splitlines()
                              if line.startswith("PASS:") or "checks passed" in line)}


def extract(snapshot, destination):
    with tarfile.open(fileobj=io.BytesIO(snapshot)) as archive:
        # Git archives contain repository-relative entries; benchmark only code
        # already present in this local repository, never downloaded archives.
        for item in archive.getmembers():
            if Path(item.name).is_absolute() or ".." in Path(item.name).parts or item.issym() or item.islnk():
                raise ValueError("Unsafe benchmark archive entry")
        archive.extractall(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("At least one sample is required")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    commits = {name: git("rev-parse", ref + "^{commit}").decode().strip()
               for name, ref in [("baseline", args.baseline), ("candidate", args.candidate)]}
    snapshots = {name: git("archive", commit, *ROOTS) for name, commit in commits.items()}
    fixture = git("show", commits["candidate"] + ":" + FIXTURE)
    # Production and all other test source must match, so this benchmark cannot
    # report a gain caused by deleting tests or replacing production behavior.
    changed = git("diff", "--name-only", commits["baseline"], commits["candidate"],
                  "Sources", "HookCore", "ResetNewsCore", "HookHelper", "Tests").decode().splitlines()
    allowed = {FIXTURE, "Tests/CITimingTests.py", "Tests/CoreTestBuildGraphTests.py"}
    if any(path not in allowed for path in changed):
        raise ValueError("Baseline and candidate differ in production or unrelated tests")
    result = {"commits": commits, "samples": args.samples, "projectCaches": "fresh per sample",
              "systemCaches": "not cleared", "fixtureOverrideSHA256": hashlib.sha256(fixture).hexdigest(),
              "rows": []}
    result["compiler"] = subprocess.check_output(["swiftc", "--version"], text=True).strip()
    report = args.output / "comparison.json"
    expected = {}
    for sample in range(1, args.samples + 1):
        order = ["baseline", "candidate"] if sample % 2 else ["candidate", "baseline"]
        for mode in order:
            with tempfile.TemporaryDirectory(prefix="hud-ci-benchmark-") as temporary:
                tree = Path(temporary)
                extract(snapshots[mode], tree)
                (tree / FIXTURE).write_bytes(fixture)
                environment = dict(os.environ)
                environment.pop("HUD_CORE_TESTS_ONLY", None)
                environment.pop("CI_TIMING_PARENT_ID", None)
                environment["CI_TIMING_DIR"] = str(args.output / f"{mode}-{sample}-timings")
                for script in SCRIPTS:
                    log_path = args.output / f"{mode}-{sample}-{script}.log"
                    started = time.monotonic()
                    with log_path.open("w") as output:
                        process = subprocess.run(["bash", "scripts/" + script + ".sh"], cwd=tree,
                                                 env=environment, stdout=output, stderr=subprocess.STDOUT)
                    row = {"mode": mode, "sample": sample, "script": script, "exitCode": process.returncode,
                           "seconds": round(time.monotonic() - started, 3), "log": log_path.name}
                    row["coverage"] = coverage(log_path.read_text(), script)
                    result["rows"].append(row)
                    report.write_text(json.dumps(result, indent=2) + "\n")
                    print(json.dumps({key: value for key, value in row.items() if key != "coverage"}), flush=True)
                    if process.returncode:
                        raise RuntimeError(f"Failed benchmark sample; not counted as a speedup: {log_path}")
                    if not row["coverage"].get("testCount", row["coverage"].get("checks")):
                        raise RuntimeError(f"No successful test coverage found: {log_path}")
                    if script in expected and row["coverage"] != expected[script]:
                        raise RuntimeError(f"Test coverage changed: {log_path}")
                    expected[script] = row["coverage"]
    result["summary"] = {}
    for script in SCRIPTS:
        values = {mode: [row["seconds"] for row in result["rows"] if row["mode"] == mode and row["script"] == script]
                  for mode in commits}
        baseline = statistics.median(values["baseline"])
        candidate = statistics.median(values["candidate"])
        result["summary"][script] = {"baselineMedian": baseline, "candidateMedian": candidate,
                                     "savedPercent": round((baseline - candidate) / baseline * 100, 2),
                                     "candidateMaximum": max(values["candidate"])}
    result["coverageEquivalent"] = True
    report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["summary"], indent=2))


if __name__ == "__main__":
    main()
