#!/usr/bin/env python3
"""Protect coverage and attribution in the grouping experiment."""
import importlib.util
from pathlib import Path
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("grouping", ROOT / "scripts/benchmark-ci-grouping.py")
grouping = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grouping)


class GroupingTests(unittest.TestCase):
    def test_missing_or_duplicate_suite_is_rejected(self):
        workflow = (ROOT / grouping.WORKFLOW).read_text()
        source = (ROOT / "scripts/ci_regression.py").read_text()
        frozen = json.loads((ROOT / "Tests/Fixtures/ci-regression-layout-v1.json").read_text())["suites"]
        current = {suite: list(scripts) for suite, scripts in frozen.items()}
        current["data"].insert(current["data"].index("test-host-lifecycle") + 1, "test-app-termination")
        index = current["data"].index("test-single-instance") + 1
        current["data"][index:index] = ["test-installation-maintenance", "test-installation-migration"]
        self.assertEqual(grouping.layout(workflow, source), current)
        with self.assertRaises(ValueError):
            grouping.layout(workflow, source.replace('"test-hooks"', '"test-task-status"'))
        with self.assertRaises(ValueError):
            grouping.layout(workflow)
        legacy = "\n".join("      - name: " + suite + "\n        if: matrix.suite == '" + suite + "'\n" +
                           "\n".join("          python3 timer --phase suite --label " + script +
                                     " -- bash scripts/" + script + ".sh" for script in scripts)
                           for suite, scripts in frozen.items())
        self.assertEqual(grouping.layout(legacy), frozen)
        with self.assertRaises(ValueError):
            grouping.layout(legacy.replace("--label test-hooks --", "--label missing --"))

    def test_only_intact_diagnostic_move_is_accepted(self):
        before = {"data": ["a", grouping.DIAGNOSTIC, "b"], "interface": ["c"]}
        grouping.validate_layouts(before, {"data": ["a", "b"], "interface": ["c", grouping.DIAGNOSTIC]})
        for after in [{"data": ["b", "a"], "interface": ["c", grouping.DIAGNOSTIC]},
                      {"data": ["a"], "interface": ["b", "c", grouping.DIAGNOSTIC]}]:
            with self.assertRaises(ValueError):
                grouping.validate_layouts(before, after)

    def test_dynamic_frames_do_not_hide_changed_check_counts(self):
        a = grouping.coverage("PASS: 437 native island checks; 90 presented frames", "test-notch-presentation")
        b = grouping.coverage("PASS: 437 native island checks; 145 presented frames", "test-notch-presentation")
        self.assertEqual(a, b)
        self.assertNotEqual(a, grouping.coverage("PASS: 436 native island checks; 90 presented frames", "test-notch-presentation"))
        self.assertTrue(grouping.coverage("HUD material tests passed: 45 checks; native glass supported: false", "test-hud-material"))
        with self.assertRaises(ValueError):
            grouping.coverage("compiler succeeded but no tests ran", "test-hud-material")


if __name__ == "__main__":
    unittest.main()
