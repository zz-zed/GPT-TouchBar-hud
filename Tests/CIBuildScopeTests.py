#!/usr/bin/env python3
"""Offline checks for the fail-open main-push build scope."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock
import json
import os
import tempfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("ci_build_scope", ROOT / "scripts/ci_build_scope.py")
scope = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scope)
from ci_policy import profile_for, required_jobs, pr_event_requires_checks


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

    def test_real_main_history_direct_push_and_successive_merge_methods(self):
        for method in ("merge", "squash", "rebase"):
            with self.subTest(method=method), tempfile.TemporaryDirectory(prefix="hud-ci-main-history-") as temporary:
                root = Path(temporary)
                def git(*args):
                    return subprocess.check_output(["git", "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", *args], cwd=root, stderr=subprocess.STDOUT).decode().strip()
                def commit(path, text):
                    target = root / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text(text)
                    git("add", path)
                    git("commit", "--quiet", "-m", "fixture")
                    return git("rev-parse", "HEAD")
                def changes(before, after):
                    original_run = subprocess.run
                    with mock.patch.object(scope.subprocess, "run", side_effect=lambda *a, **k: original_run(*a, cwd=root, **k)):
                        return scope.changed_paths(before, after)
                git("init", "--quiet", "-b", "main")
                base = commit("README.md", "fixture\n")
                # One direct push can contain several commits; diff spans the
                # whole pushed range, while source identity is its final SHA.
                commit("Sources/A.swift", "let a = 1\n")
                direct = commit("Sources/B.swift", "let b = 1\n")
                self.assertEqual(set(changes(base, direct)), {"Sources/A.swift", "Sources/B.swift"})
                self.assertEqual(profile_for("push", changes(base, direct)), "main-full")
                for number in (1, 2):
                    before = git("rev-parse", "main")
                    git("switch", "--quiet", "-c", f"pr-{number}")
                    commit("Sources/A.swift", f"let a = {number + 1}\n")
                    if method == "rebase":
                        git("rebase", "main")
                    git("switch", "--quiet", "main")
                    if method == "squash":
                        git("merge", "--quiet", "--squash", f"pr-{number}")
                        git("commit", "--quiet", "-m", "squash fixture")
                    else:
                        git("merge", "--quiet", "--ff-only" if method == "rebase" else "--no-ff",
                            f"pr-{number}", "-m", "merge fixture")
                    after = git("rev-parse", "main")
                    self.assertNotEqual(before, after)
                    self.assertEqual(profile_for("push", changes(before, after)), "main-full")
                    git("merge-base", "--is-ancestor", before, "main")
                before_docs = git("rev-parse", "HEAD")
                docs = commit("Documentation/release.md", "fixture\n")
                self.assertEqual(profile_for("push", changes(before_docs, docs)), "docs")

    def test_five_profiles_and_mixed_changes(self):
        cases = [
            ("pull_request", ["README.md"], "docs"),
            ("pull_request", ["Sources/TaskStatusMonitor.swift"], "pr-standard"),
            ("pull_request", ["Tests/TaskStatusTests.swift", "README.md"], "pr-standard"),
            ("pull_request", ["Sources/TaskStatusMonitor.swift", "Resources/Info.plist"], "pr-full"),
            ("push", ["Sources/TaskStatusMonitor.swift"], "main-full"),
            ("push", ["RELEASE_NOTES.md"], "main-full"),
            ("pull_request", ["RELEASE_NOTES.md"], "pr-full"),
            ("push", ["Documentation/RELEASE.md"], "docs"),
            ("workflow_dispatch", ["README.md"], "recovery-full"),
        ]
        for event, paths, profile in cases:
            with self.subTest(event=event, paths=paths):
                self.assertEqual(profile_for(event, paths), profile)

    def test_high_risk_inputs_always_use_full_pr(self):
        for path in ("Package.swift", "scripts/test-hooks.sh", ".github/workflows/build-dmg.yml",
                     "HookCore/State.swift", "HookHelper/main.swift", "ResetNewsCore/Cache.swift",
                     "Resources/icon.png", "Sources/AppUpdateInstallation.swift", "Sources/AppDelegate.swift",
                     "Sources/HostLifecycleMonitor.swift", "Sources/SingleInstanceLock.swift",
                     "Sources/TouchBarRateLimitsView.swift", "Sources/NotchHUDController.swift"):
            with self.subTest(path=path):
                self.assertEqual(profile_for("pull_request", ["README.md", path]), "pr-full")

    def test_unknown_diff_or_file_and_new_source_escalate(self):
        for paths in (None, ["unknown.md"], ["Documentation/build.swift"], [".gitignore"], ["Tests/config.json"]):
            with self.subTest(paths=paths):
                self.assertEqual(profile_for("pull_request", paths), "pr-full")
                self.assertEqual(profile_for("push", paths), "main-full")
        self.assertEqual(profile_for("pull_request", ["Sources/New.swift"], added_paths={"Sources/New.swift"}), "pr-full")

    def test_force_full_only_increases_checks(self):
        for paths in (["README.md"], ["Sources/TaskStatusMonitor.swift"], None):
            self.assertEqual(profile_for("pull_request", paths, force_full=True), "pr-full")
        self.assertEqual(profile_for("push", ["README.md"], force_full=True), "docs")

    def test_cli_label_and_repository_override_and_boolean_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            event = Path(temporary) / "event.json"
            output = Path(temporary) / "output"
            event.write_text(json.dumps({"pull_request": {"labels": [{"name": "ci:full"}]}}))
            argv = ["ci_build_scope.py", "--before", "a" * 40, "--after", "b" * 40,
                    "--event", "pull_request", "--github-output", str(output)]
            with mock.patch.object(sys, "argv", argv), mock.patch.dict(os.environ, {"GITHUB_EVENT_PATH": str(event)}), \
                    mock.patch.object(scope, "changed_paths", return_value=["README.md"]), mock.patch("builtins.print") as printed:
                scope.main()
                printed.assert_called_once_with("true")
            self.assertIn("profile=pr-full\n", output.read_text())
            event.write_text(json.dumps({"pull_request": {"labels": []}}))
            with mock.patch.object(sys, "argv", argv), mock.patch.dict(os.environ, {"GITHUB_EVENT_PATH": str(event), "CI_FORCE_FULL_PR": "true"}), \
                    mock.patch.object(scope, "changed_paths", return_value=["README.md"]), mock.patch("builtins.print"):
                scope.main()
            self.assertEqual(output.read_text().count("profile=pr-full\n"), 2)

    def test_pr_standard_requires_production_app_besides_core_tests(self):
        self.assertIn("Build App (arm64)", required_jobs("pr-standard"))
        self.assertEqual(len(required_jobs("main-full")), 7)

    def test_pr_metadata_only_exemptions_and_unknown_payloads(self):
        for action in ("labeled", "unlabeled"):
            self.assertFalse(pr_event_requires_checks({"action": action, "label": {"name": "documentation"}}))
            self.assertTrue(pr_event_requires_checks({"action": action, "label": {"name": "ci:full"}}))
            self.assertTrue(pr_event_requires_checks({"action": action}))
        self.assertFalse(pr_event_requires_checks({"action": "edited", "changes": {"title": {"from": "old"}}}))
        self.assertFalse(pr_event_requires_checks({"action": "edited", "changes": {"title": {}, "body": {}}}))
        for payload in (None, {}, {"action": "edited"}, {"action": "edited", "changes": {}},
                        {"action": "edited", "changes": {"base": {"ref": {"from": "develop"}}}},
                        {"action": "edited", "changes": {"unknown": {}}}, {"action": "synchronize"}):
            with self.subTest(payload=payload):
                self.assertTrue(pr_event_requires_checks(payload))

    def test_cli_keeps_metadata_distinct_from_documentation_scope(self):
        with tempfile.TemporaryDirectory() as temporary:
            event = Path(temporary) / "event.json"
            output = Path(temporary) / "output"
            event.write_text(json.dumps({"action": "edited", "changes": {"body": {"from": "old"}},
                                         "pull_request": {"labels": []}}))
            argv = ["ci_build_scope.py", "--before", "a" * 40, "--after", "b" * 40,
                    "--event", "pull_request", "--github-output", str(output)]
            with mock.patch.object(sys, "argv", argv), mock.patch.dict(os.environ, {"GITHUB_EVENT_PATH": str(event)}), \
                    mock.patch.object(scope, "changed_paths", return_value=["Resources/Info.plist"]), \
                    mock.patch("builtins.print"):
                scope.main()
            self.assertIn("profile=pr-full\n", output.read_text())
            self.assertIn("build_required=true\n", output.read_text())
            self.assertIn("checks_required=false\n", output.read_text())


if __name__ == "__main__":
    unittest.main()
