#!/usr/bin/env python3
"""Exercise telemetry with real child processes, including failures/signals."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci_timing.py"


class TimingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.records = self.directory / "records"
        self.environment = dict(os.environ, CI_TIMING_DIR=str(self.records))
        self.environment.pop("CI_TIMING_PARENT_ID", None)

    def command(self, *command, phase="execute"):
        return [sys.executable, str(SCRIPT), "run", "--phase", phase, "--label", "fixture", "--", *command]

    def rows(self):
        return [json.loads(p.read_text()) for p in self.records.glob("*.json") if p.name != "summary.json"]

    def test_output_arguments_and_nonzero_exit_are_preserved(self):
        result = subprocess.run(self.command(sys.executable, "-c",
            "import sys; print(sys.argv[1]); print('error-output', file=sys.stderr); sys.exit(7)", "a b;$literal"),
            env=self.environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, "a b;$literal\n")
        self.assertEqual(result.stderr, "error-output\n")
        row, = self.rows()
        self.assertEqual(row["exitCode"], 7)
        self.assertGreater(row["seconds"], 0)
        self.assertNotIn("command", row)  # Do not archive arbitrary command arguments.

    def test_missing_executable_is_recorded(self):
        result = subprocess.run(self.command(str(self.directory / "missing")), env=self.environment, capture_output=True)
        self.assertEqual(result.returncode, 127)
        self.assertEqual(self.rows()[0]["exitCode"], 127)

    def test_nested_measurements_keep_the_parent_without_double_counting(self):
        subprocess.run(self.command(*self.command(sys.executable, "-c", "pass"), phase="suite"),
                       env=self.environment, check=True)
        rows = self.rows()
        parent = next(row for row in rows if row["phase"] == "suite")
        child = next(row for row in rows if row["phase"] == "execute")
        self.assertEqual(child["parentID"], parent["id"])
        self.assertGreater(parent["seconds"], child["seconds"])
        subprocess.run([sys.executable, str(SCRIPT), "report"], env=self.environment, check=True, capture_output=True)
        # Repeating report must not consume its own summary as another event.
        subprocess.run([sys.executable, str(SCRIPT), "report"], env=self.environment, check=True, capture_output=True)
        self.assertEqual(len(json.loads((self.records / "summary.json").read_text())), 2)

    def test_swift_reported_durations_are_separate_from_wall_time(self):
        result = subprocess.run(self.command(sys.executable, "-c",
            "import sys; print('Build complete! (3.12秒)',file=sys.stderr); "
            "print('✔ Test run with 131 tests in 10 suites passed after 0.321 seconds.'); "
            "print('✔ Test run with 99 tests in 13 suites passed after 0.654 seconds.')", phase="core-tests"),
            env=self.environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("Build complete!", result.stderr)
        self.assertIn("131 tests", result.stdout)
        self.assertEqual(self.rows()[0]["swiftReported"],
                         {"buildSeconds": 3.12, "testRuns": [
                             {"testCount": 131, "suiteCount": 10, "testSeconds": 0.321},
                             {"testCount": 99, "suiteCount": 13, "testSeconds": 0.654}]})

    def test_sigterm_is_forwarded_and_recorded(self):
        ready = self.directory / "ready"
        code = "import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(30)"
        process = subprocess.Popen(self.command(sys.executable, "-c", code, str(ready)), env=self.environment)
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists())
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=5), 143)
            self.assertEqual(self.rows()[0]["exitCode"], 143)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_compiler_wrapper_preserves_arguments_and_disabled_mode(self):
        binary = self.directory / "swiftc"
        binary.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\"\nexit 9\n")
        binary.chmod(0o755)
        environment = dict(self.environment, PATH=str(self.directory) + os.pathsep + os.environ["PATH"])
        command = ["bash", "-c", 'source "$1"; swiftc "a b.swift" -target demo', "test", str(ROOT / "scripts/ci-timing.sh")]
        result = subprocess.run(command, env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 9)
        self.assertEqual(result.stdout, "a b.swift\n-target\ndemo\n")
        row, = self.rows()
        self.assertEqual(row["sourceFiles"], ["a b.swift"])
        self.assertEqual(row["target"], "demo")
        environment.pop("CI_TIMING_DIR")
        disabled = subprocess.run(command, env=environment, capture_output=True, text=True)
        self.assertEqual(disabled.returncode, 9)
        self.assertEqual(disabled.stdout, result.stdout)
        self.assertEqual(len(self.rows()), 1)

    def test_in_process_span_preserves_timeout_and_disabled_behavior(self):
        code = ("import sys, subprocess; sys.path.insert(0, sys.argv[1]); "
                "from ci_timing import observed_span\n"
                "try:\n"
                " with observed_span('execute', 'timeout'):\n"
                "  raise subprocess.TimeoutExpired('fixture', 45)\n"
                "except subprocess.TimeoutExpired as error:\n"
                " assert error.timeout == 45\n"
                " print('original timeout preserved')\n")
        command = [sys.executable, "-c", code, str(ROOT / "scripts")]
        result = subprocess.run(command, env=self.environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        row, = self.rows()
        self.assertEqual(row["exitCode"], 124)
        self.assertEqual(row["measurementKind"], "in-process")
        disabled = dict(self.environment)
        disabled.pop("CI_TIMING_DIR")
        result2 = subprocess.run(command, env=disabled, capture_output=True, text=True)
        self.assertEqual((result2.returncode, result2.stdout), (0, result.stdout))
        self.assertEqual(len(self.rows()), 1)

    def test_update_server_keeps_child_failure_and_records_cleanup(self):
        result = subprocess.run(self.command(sys.executable, str(ROOT / "Tests/app_update_download_server.py"),
                                            "/usr/bin/false"), env=self.environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        rows = self.rows()
        outer = next(r for r in rows if r["label"] == "fixture")
        child = next(r for r in rows if r["label"] == "app-update-progress-test")
        self.assertEqual(child["exitCode"], 1)
        self.assertEqual(child["parentID"], outer["id"])
        self.assertEqual({r["label"] for r in rows if r["phase"] == "cleanup"},
                         {"app-update-server-shutdown", "app-update-server-close"})
        self.assertTrue(all(r["exitCode"] == 0 for r in rows if r["phase"] == "cleanup"))


if __name__ == "__main__":
    unittest.main()
