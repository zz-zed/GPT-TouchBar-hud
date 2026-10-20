#!/usr/bin/env python3
"""Preserve legacy suite coverage, command isolation, timing and failure exits."""
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import ci_regression as regression


class CIRegressionTests(unittest.TestCase):
    def test_frozen_workflow_coverage_and_order_are_preserved(self):
        frozen = json.loads((ROOT / "Tests/Fixtures/ci-regression-layout-v1.json").read_text())
        # The historical entry points retain their order; the architecture refactor
        # adds the real coordinator shutdown fence immediately after lifecycle checks.
        expected = frozen["suites"]
        expected["data"].insert(expected["data"].index("test-host-lifecycle") + 1, "test-app-termination")
        index = expected["data"].index("test-single-instance") + 1
        expected["data"][index:index] = ["test-installation-maintenance", "test-installation-migration"]
        self.assertEqual(regression.REGRESSION_SUITES, expected)
        scripts = sum(regression.REGRESSION_SUITES.values(), [])
        self.assertEqual(len(scripts), 32)
        self.assertEqual(len(set(scripts)), 32)

    def test_every_script_has_its_own_timing_and_bash_invocation(self):
        for suite, scripts in regression.REGRESSION_SUITES.items():
            with self.subTest(suite=suite), mock.patch.object(regression.subprocess, "run", return_value=mock.Mock(returncode=0)) as run, mock.patch("builtins.print"):
                self.assertEqual(regression.run_suite(suite, ROOT, "scripts/ci_timing.py", {"RUNNER_TEMP": "/tmp/fixture"}), 0)
                self.assertEqual(len(run.call_args_list), len(scripts))
                for call, script in zip(run.call_args_list, scripts):
                    self.assertEqual(call.args[0][-3:], ["--", "bash", "scripts/" + script + ".sh"])
                    self.assertIn(script, call.args[0])
                    self.assertEqual(call.kwargs["cwd"], ROOT)
                    if script == "test-reset-news-runtime":
                        self.assertTrue(call.kwargs["env"]["RESET_NEWS_CORE_DIR"].startswith("/tmp/fixture/reset-news-core-runtime-"))
                    else:
                        self.assertNotIn("RESET_NEWS_CORE_DIR", call.kwargs["env"])

    def test_failure_stops_suite_and_preserves_exit(self):
        for code, expected in ((7, 7), (-9, 137)):
            with self.subTest(code=code), mock.patch.object(regression.subprocess, "run", return_value=mock.Mock(returncode=code)) as run, mock.patch("builtins.print"):
                self.assertEqual(regression.run_suite("data", ROOT, "scripts/ci_timing.py", {}), expected)
                self.assertEqual(run.call_count, 1)

    def test_missing_script_or_timer_fails_before_execution(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(regression.subprocess, "run") as run:
            root = Path(temporary)
            with self.assertRaises(ValueError):
                regression.run_suite("data", root, "missing-timer", {})
            (root / "timer.py").write_text("")
            with self.assertRaises(ValueError):
                regression.run_suite("data", root, "timer.py", {})
            run.assert_not_called()

    def test_actual_failed_command_retains_timing_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/ci_timing.py", root / "scripts/ci_timing.py")
            for name in sum(regression.REGRESSION_SUITES.values(), []):
                (root / "scripts" / (name + ".sh")).write_text("exit 7\n")
            (root / "Sources").mkdir()
            for name in ("AppInstallationMaintenance.swift", "AppInstallationMigration.swift", "AppMigrationMacOSDriver.swift", "AppMigrationRuntime.swift"):
                (root / "Sources" / name).write_text("")
            result = regression.run_suite("data", root, "scripts/ci_timing.py",
                                          {"CI_TIMING_DIR": str(root / "timings")})
            self.assertEqual(result, 7)
            records = [json.loads(p.read_text()) for p in (root / "timings").glob("*.json")]
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["label"], "test-task-status")
            self.assertEqual(records[0]["exitCode"], 7)

    def test_immutable_historical_source_skips_only_wholly_absent_capability(self):
        additions = ("test-installation-maintenance", "test-installation-migration")
        modules = ("AppInstallationMaintenance.swift", "AppInstallationMigration.swift",
                   "AppMigrationMacOSDriver.swift", "AppMigrationRuntime.swift")
        expected = [name for name in regression.REGRESSION_SUITES["data"] if name not in additions]
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(regression.subprocess, "run", return_value=mock.Mock(returncode=0)) as run, mock.patch("builtins.print"):
            root = Path(temporary); (root / "scripts").mkdir(); (root / "Sources").mkdir()
            (root / "timer.py").write_text("")
            for name in expected:
                (root / "scripts" / (name + ".sh")).write_text("")
            self.assertEqual(regression.run_suite("data", root, "timer.py", {}), 0)
            self.assertEqual([call.args[0][-1] for call in run.call_args_list], ["scripts/" + name + ".sh" for name in expected])
            # Neither an orphan test script nor an orphan production module can
            # turn a damaged current checkout into the historical exemption.
            (root / "scripts" / (additions[0] + ".sh")).write_text("")
            with self.assertRaisesRegex(ValueError, "Incomplete"):
                regression.run_suite("data", root, "timer.py", {})
            (root / "scripts" / (additions[0] + ".sh")).unlink()
            (root / "Sources" / modules[0]).write_text("")
            with self.assertRaisesRegex(ValueError, "Incomplete"):
                regression.run_suite("data", root, "timer.py", {})


if __name__ == "__main__":
    unittest.main()
