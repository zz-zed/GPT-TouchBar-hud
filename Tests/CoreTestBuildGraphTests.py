#!/usr/bin/env python3
"""Check the actual SwiftPM manifest in both modes, including switching back."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CoreTestBuildGraphTests(unittest.TestCase):
    def manifest(self, core_only):
        environment = dict(os.environ)
        environment.pop("HUD_CORE_TESTS_ONLY", None)
        if core_only:
            environment["HUD_CORE_TESTS_ONLY"] = "1"
        return json.loads(subprocess.check_output(["swift", "package", "dump-package"], cwd=ROOT, env=environment))

    def test_only_executables_are_removed_and_default_graph_is_restored(self):
        before = self.manifest(False)
        core = self.manifest(True)
        after = self.manifest(False)
        self.assertEqual(before, after)
        core_targets = {target["name"]: target for target in core["targets"]}
        normal_targets = {target["name"]: target for target in before["targets"]}
        self.assertEqual(set(core_targets), {"HookCore", "ResetNewsCore", "HookCoreTests", "ResetNewsCoreTests"})
        self.assertEqual(set(normal_targets) - set(core_targets), {"GPTTouchBarHUD", "HookEmitter"})
        for name, target in core_targets.items():
            self.assertEqual(target, normal_targets[name])
        self.assertEqual(core["products"], [])
        self.assertEqual({product["name"] for product in before["products"]}, {"GPTTouchBarHUD", "HookEmitter"})
        self.assertEqual(core["platforms"], before["platforms"])


if __name__ == "__main__":
    unittest.main()
