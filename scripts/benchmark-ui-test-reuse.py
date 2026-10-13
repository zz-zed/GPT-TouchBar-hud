#!/usr/bin/env python3
"""Pair legacy direct-source builds with the two-fixture shared-module pilot.

Each mode gets a fresh source/build tree. UI fixtures are serial and keep their
own processes; no system caches are purged. Both modes use identical assertions.
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
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ROOTS = ["Package.swift", "HookCore", "ResetNewsCore", "HookHelper", "Sources", "Tests", "scripts", "Resources"]
FIXTURES = [("test-idle-performance", "Tests/IdlePerformanceTests.swift", "idle-performance"),
            ("test-design-layout", "Tests/DesignLayoutTests.swift", "design-layout")]
IMPORT = b"#if HUD_SHARED_UI_TESTS\n@testable import HUDTestSupport\n#endif\n"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", default="HEAD")
    parser.add_argument("--baseline", default="fe56fec67d5c55b131fb281516242745fb832daa")
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--first-mode", choices=["legacy", "shared"], default="legacy")
    parser.add_argument("--reverse-fixtures", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("At least one sample is required")
    candidate = git("rev-parse", args.candidate + "^{commit}").decode().strip()
    baseline = git("rev-parse", args.baseline + "^{commit}").decode().strip()
    # The reference establishes unchanged production code and assertions. Timing
    # compares the new scripts' explicit legacy/shared paths on identical inputs.
    if git("diff", "--name-only", baseline, candidate, "Sources", "HookCore", "ResetNewsCore", "HookHelper"):
        raise ValueError("Production source changed")
    digests = {}
    for _, fixture, _ in FIXTURES:
        before = git("show", baseline + ":" + fixture)
        after = git("show", candidate + ":" + fixture)
        if after.count(IMPORT) != 1 or after.replace(IMPORT, b"") != before:
            raise ValueError("Fixture assertions changed: " + fixture)
        digests[fixture] = hashlib.sha256(before).hexdigest()
    snapshot = git("archive", candidate, *ROOTS)
    fixtures = list(reversed(FIXTURES)) if args.reverse_fixtures else FIXTURES
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    report = {"candidate": candidate, "assertionReference": baseline, "fixtureBodySHA256": digests,
              "samples": args.samples, "projectCaches": "fresh per mode", "systemCaches": "not cleared",
              "compiler": subprocess.check_output(["swiftc", "--version"], text=True).strip(), "rows": []}
    expected = {}
    destination = args.output / "comparison.json"
    for sample in range(1, args.samples + 1):
        order = [args.first_mode, "shared" if args.first_mode == "legacy" else "legacy"]
        if not sample % 2:
            order.reverse()
        for mode in order:
            with tempfile.TemporaryDirectory(prefix="hud-ui-benchmark-") as temporary:
                tree = Path(temporary)
                with tarfile.open(fileobj=io.BytesIO(snapshot)) as archive:
                    for item in archive.getmembers():
                        if Path(item.name).is_absolute() or ".." in Path(item.name).parts or item.issym() or item.islnk():
                            raise ValueError("Unsafe source archive entry")
                    archive.extractall(tree)
                timing = args.output / f"{mode}-{sample}-timings"
                environment = dict(os.environ, HUD_SHARED_UI_TESTS="1" if mode == "shared" else "0", CI_TIMING_DIR=str(timing))
                environment.pop("CI_TIMING_PARENT_ID", None)
                for script, _, label in fixtures:
                    log = args.output / f"{mode}-{sample}-{script}.log"
                    started = time.monotonic()
                    with log.open("w") as output:
                        process = subprocess.run(["python3", "scripts/ci_timing.py", "run", "--phase", "suite",
                                                  "--label", script, "--", "bash", "scripts/" + script + ".sh"],
                                                 cwd=tree, env=environment, stdout=output, stderr=subprocess.STDOUT)
                    # A compiler version probe can emit stderr without a trailing
                    # newline; accept the complete PASS summary after that prefix.
                    checks = sorted(re.findall(r"PASS: [^\r\n]+", log.read_text()))
                    row = {"sample": sample, "mode": mode, "script": script, "seconds": round(time.monotonic()-started, 3),
                           "exitCode": process.returncode, "checks": checks, "log": log.name}
                    report["rows"].append(row)
                    destination.write_text(json.dumps(report, indent=2) + "\n")
                    print(json.dumps(row), flush=True)
                    if process.returncode:
                        raise RuntimeError("Failed fixture; no speedup accepted: " + str(log))
                    if not checks:
                        raise RuntimeError("Missing fixture summary; no speedup accepted: " + str(log))
                    if script in expected and expected[script] != checks:
                        raise RuntimeError("Fixture output changed: " + script)
                    expected[script] = checks
                records = [json.loads(path.read_text()) for path in timing.glob("*.json")]
                executions = [r for r in records if r["phase"] == "execute"]
                if len(executions) != 2 or len({r["processID"] for r in executions}) != 2:
                    raise RuntimeError("Fixtures must execute in separate processes")
                if {r["label"] for r in executions} != {f[2] for f in FIXTURES}:
                    raise RuntimeError("Missing fixture execution")
                builds = [r for r in records if r.get("module") == "HUDTestSupport"]
                hits = [r for r in records if r["phase"] == "dependency-reuse" and r["label"] == "HUDTestSupport"]
                expected_count = 1 if mode == "shared" else 0
                if len(builds) != expected_count or len(hits) != expected_count:
                    raise RuntimeError("Shared module must build once and be reused once")
                if any(r["exitCode"] for r in records):
                    raise RuntimeError("A measured command failed")
    totals = {mode: [sum(r["seconds"] for r in report["rows"] if r["mode"] == mode and r["sample"] == sample)
                    for sample in range(1, args.samples + 1)] for mode in ("legacy", "shared")}
    medians = {mode: statistics.median(values) for mode, values in totals.items()}
    report.update(coverageEquivalent=True, independentProcesses=True, sharedBuildOncePerPair=True,
                  summary={"pairSeconds": totals, "medians": medians,
                           "savedPercent": round((1-medians["shared"]/medians["legacy"])*100, 2)})
    destination.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2))


if __name__ == "__main__":
    main()
