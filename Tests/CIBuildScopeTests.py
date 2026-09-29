#!/usr/bin/env python3
"""Offline checks for the fail-open main-push build scope."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ci_build_scope", ROOT / "scripts/ci_build_scope.py")
scope = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scope)


class CIBuildScopeTests(unittest.TestCase):
    def test_product_release_policy_and_workflow_changes_build(self):
        for path in (
            "Package.swift", "RELEASE_NOTES.md", "Resources/Info.plist",
            "Sources/main.swift", "Tests/NotchHUDTests.swift",
            "scripts/build-app.sh", ".github/workflows/build-dmg.yml",
            ".github/workflows/release.yml", "HookCore/State.swift",
            "ResetNewsCore/Cache.swift", "HookHelper/main.swift",
        ):
            with self.subTest(path=path):
                self.assertTrue(scope.needs_build([path]))

    def test_publication_record_only_does_not_build(self):
        self.assertFalse(scope.needs_build([
            "Documentation/RELEASE-0.1.36.md",
            "Documentation/validation/release-0.1.36-publication.json",
        ]))
        self.assertTrue(scope.needs_build([
            "Documentation/RELEASE-0.1.36.md", "RELEASE_NOTES.md",
        ]))

    def test_missing_or_invalid_diff_runs_full_matrix(self):
        valid_sha = "a" * 40
        self.assertIsNone(scope.changed_paths("", valid_sha))
        self.assertIsNone(scope.changed_paths("0" * 40, valid_sha))
        with mock.patch.object(scope.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertIsNone(scope.changed_paths(valid_sha, "b" * 40))

    def test_git_diff_uses_nul_paths_and_detects_renamed_inputs(self):
        result = mock.Mock(stdout=b"Documentation/release.md\0Sources/main.swift\0")
        with mock.patch.object(scope.subprocess, "run", return_value=result) as run:
            paths = scope.changed_paths("a" * 40, "b" * 40)
        self.assertEqual(paths, ["Documentation/release.md", "Sources/main.swift"])
        self.assertIn("--no-renames", run.call_args.args[0])
        self.assertTrue(scope.needs_build(paths))


if __name__ == "__main__":
    unittest.main()
