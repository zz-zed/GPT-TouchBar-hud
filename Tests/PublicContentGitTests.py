#!/usr/bin/env python3
"""Exercise exact Git objects, outgoing history, hooks and publication payloads."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts/check-public-content.py"
POLICY = ".github/public-content-paths.txt"
PRIVATE = "/" + "Users/" + "synthetic-private-marker/project"
PUBLIC_NAME = "example"
PUBLIC_EMAIL = "example@users.noreply.github.com"


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class GitPublicationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "source"
        self.root.mkdir()
        self.remote = self.root.parent / "remote.git"
        # Isolate hooks, identity and signing settings from the developer's machine.
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME=PUBLIC_NAME, GIT_COMMITTER_NAME=PUBLIC_NAME,
                        GIT_AUTHOR_EMAIL=PUBLIC_EMAIL, GIT_COMMITTER_EMAIL=PUBLIC_EMAIL)
        self.git("init", "-q", "-b", "main")
        self.git("init", "--bare", "-q", str(self.remote))
        self.git("remote", "add", "origin", str(self.remote))
        self.allowed = {POLICY, "README.md", "Sources/Example.swift", "Tests/sample.json"}
        self.write("README.md", "Product overview\n")
        for name in ["check-public-content.py", "public-content-ci.py", "install-public-content-hooks.py", "git-hooks/pre-commit", "git-hooks/commit-msg", "git-hooks/pre-push"]:
            target = self.root / "scripts" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / "scripts" / name, target)
            self.allowed.add("scripts/" + name)
        self.registry()
        self.commit("Initial product fixture")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("push", "-q", "origin", "main")

    def git(self, *args, check=True, env=None):
        return subprocess.run(["git", "-c", "commit.gpgsign=false", *args], cwd=self.root,
                              env=env or self.env, capture_output=True, text=True, check=check)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def registry(self):
        self.write(POLICY, "\n".join(sorted(self.allowed)) + "\n")

    def commit(self, message):
        self.git("add", "--all")
        self.git("commit", "--allow-empty", "-qm", message)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def scan(self, *args, data=None):
        result = subprocess.run([sys.executable, str(CHECK), "--root", str(self.root), *args],
                                env=self.env, input=data, capture_output=True, text=True)
        self.assertNotIn("synthetic-private-marker", result.stdout + result.stderr)
        return result

    def install(self):
        return subprocess.run([sys.executable, "scripts/install-public-content-hooks.py"],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def test_index_is_checked_even_when_worktree_is_clean(self):
        self.write("README.md", PRIVATE)
        self.git("add", "README.md")
        self.write("README.md", "Safe worktree\n")
        self.assertEqual(self.scan("--index").returncode, 1)

    def test_unstaged_private_change_is_not_mistaken_for_staged_content(self):
        self.write("README.md", PRIVATE)
        self.assertEqual(self.scan("--index").returncode, 0)
        self.assertEqual(self.scan().returncode, 1)

    def test_unregistered_file_is_rejected_even_when_content_is_benign(self):
        self.write("unreviewed.md", "Hello\n")
        self.git("add", "unreviewed.md")
        self.assertIn("PC007", self.scan("--index").stderr)

    def test_registering_a_work_record_cannot_allow_it(self):
        self.allowed.add("task_plan.md")
        self.registry()
        self.write("task_plan.md", "Benign but outside product scope\n")
        self.git("add", "--all")
        self.assertNotEqual(self.scan("--index").returncode, 0)

    def test_new_branch_add_then_delete_is_blocked(self):
        self.write("Sources/Example.swift", "// " + PRIVATE)
        self.commit("Add fixture")
        (self.root / "Sources/Example.swift").unlink()
        tip = self.commit("Remove fixture")
        self.assertEqual(self.scan("--pre-push", "origin", data=f"refs/heads/new {tip} refs/heads/new {'0'*40}\n").returncode, 1)

    def test_force_update_with_an_unpublished_ancestor_is_blocked(self):
        self.git("checkout", "--orphan", "replacement")
        self.write("README.md", PRIVATE)
        self.commit("Unpublished root")
        self.write("README.md", "Clean replacement")
        tip = self.commit("Clean tip")
        self.assertEqual(self.scan("--pre-push", "origin", data=f"refs/heads/replacement {tip} refs/heads/main {self.base}\n").returncode, 1)

    def test_all_update_lines_and_annotated_tag_text_are_checked(self):
        self.git("tag", "-a", "v1.0.0", "-m", PRIVATE)
        tag = self.git("rev-parse", "v1.0.0").stdout.strip()
        updates = f"refs/heads/main {self.base} refs/heads/main {self.base}\nrefs/tags/v1.0.0 {tag} refs/tags/v1.0.0 {'0'*40}\n"
        self.assertEqual(self.scan("--pre-push", "origin", data=updates).returncode, 1)

    def test_lightweight_tag_and_new_branch_on_reviewed_history_pass(self):
        self.git("tag", "v1.0.0")
        updates = f"refs/heads/new {self.base} refs/heads/new {'0'*40}\nrefs/tags/v1.0.0 {self.base} refs/tags/v1.0.0 {'0'*40}\n"
        self.assertEqual(self.scan("--pre-push", "origin", data=updates).returncode, 0)

    def test_commit_message_and_nonpublic_identity_are_blocked(self):
        tip = self.commit(PRIVATE)
        self.assertEqual(self.scan("--ref", tip, "--exclude", self.base).returncode, 1)
        env = dict(self.env, GIT_AUTHOR_EMAIL="fixture@machine.invalid")
        self.git("commit", "--allow-empty", "--amend", "--reset-author", "-qm", "Safe message", env=env)
        self.assertIn("PC008", self.scan("--ref", "HEAD", "--exclude", self.base).stderr)

    def test_symlinks_and_missing_history_fail_closed(self):
        (self.root / "README.md").unlink()
        (self.root / "README.md").symlink_to("outside.md")
        self.git("add", "README.md")
        self.assertNotEqual(self.scan("--index").returncode, 0)
        self.assertEqual(self.scan("--ref", "HEAD", "--exclude", "f"*40).returncode, 2)

    def test_hook_install_is_idempotent_and_actual_commit_is_blocked(self):
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.install().returncode, 0)
        self.write("README.md", PRIVATE)
        self.git("add", "README.md")
        self.write("README.md", "Safe worktree")
        result = self.git("commit", "-qm", "Safe message", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("synthetic-private-marker", result.stderr)

    def test_commit_message_hook_blocks_private_text_with_a_clean_index(self):
        self.assertEqual(self.install().returncode, 0)
        result = self.git("commit", "--allow-empty", "-qm", PRIVATE, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.base)
        self.assertNotIn("synthetic-private-marker", result.stdout + result.stderr)

    def test_shallow_history_is_refused(self):
        shallow = self.root.parent / "shallow"
        self.git("clone", "-q", "--depth", "1", "--branch", "main", self.remote.as_uri(), str(shallow))
        self.root = shallow
        result = self.scan("--ref", "HEAD", "--exclude", self.base)
        self.assertEqual(result.returncode, 2)
        self.assertIn("shallow", result.stderr)

    def test_actual_push_is_blocked_before_remote_receives_history(self):
        self.write("README.md", PRIVATE)
        self.commit("Bad content")
        self.write("README.md", "Safe tip")
        self.commit("Clean tip")
        self.assertEqual(self.install().returncode, 0)
        result = self.git("push", "origin", "HEAD:refs/heads/new", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/new").stdout, "")

    def test_installer_preserves_existing_hooks_and_configuration(self):
        self.git("config", "core.hooksPath", "existing-hooks")
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(self.git("config", "--get", "core.hooksPath").stdout.strip(), "existing-hooks")
        self.git("config", "--unset", "core.hooksPath")
        hook = self.root / ".git/hooks/pre-commit"
        hook.write_text("existing hook\n")
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(hook.read_text(), "existing hook\n")

    def test_final_payload_checks_decoded_json_and_process_headings(self):
        path = self.root.parent / "publication.json"
        for body in [PRIVATE, "# Execution log\nStep 1: do a task", "chatgpt-" + "conversation://fixture-123", "https://" + "chatgpt.com/c/fixture-123"]:
            path.write_text(json.dumps({"title": "Change", "body": body}).replace("/", "\\u002f"))
            self.assertEqual(self.scan("--payload", str(path)).returncode, 1)
        path.write_text(json.dumps({"title": "Change", "body": "Describe product behavior"}))
        self.assertEqual(self.scan("--payload", str(path)).returncode, 0)

    def test_product_prompt_template_is_allowed(self):
        self.write("Tests/sample.json", json.dumps({"prompt": "Summarize the supplied example."}))
        self.git("add", "Tests/sample.json")
        self.assertEqual(self.scan("--index").returncode, 0)

    def run_ci(self, kind, event, ref="refs/heads/main"):
        event_path = self.root.parent / "event.json"
        event_path.write_text(json.dumps(event))
        env = dict(self.env, GITHUB_EVENT_NAME=kind, GITHUB_EVENT_PATH=str(event_path),
                   GITHUB_REF=ref, GITHUB_SHA=self.git("rev-parse", "HEAD").stdout.strip())
        result = subprocess.run([sys.executable, "scripts/public-content-ci.py"], cwd=self.root,
                                env=env, capture_output=True, text=True)
        self.assertNotIn("synthetic-private-marker", result.stderr + result.stdout)
        return result

    def test_ci_push_checks_detached_sha_and_new_branch_intermediate_commits(self):
        self.write("README.md", PRIVATE)
        self.commit("Intermediate")
        self.write("README.md", "Product overview")
        tip = self.commit("Final")
        self.git("checkout", "--detach", tip)
        self.assertEqual(self.run_ci("push", {"before": "0"*40}, "refs/heads/new").returncode, 1)
        self.git("checkout", "--detach", self.base)
        self.assertEqual(self.run_ci("push", {"before": self.base}, "refs/heads/new").returncode, 0)

    def test_ci_pr_edit_checks_final_title_and_body(self):
        event = {"action": "edited", "pull_request": {"head": {"sha": self.base},
                 "base": {"sha": self.base}, "title": "Product change", "body": PRIVATE}}
        self.assertEqual(self.run_ci("pull_request", event).returncode, 1)
        event["pull_request"]["body"] = "Public behavior and verification"
        self.assertEqual(self.run_ci("pull_request", event).returncode, 0)

    def test_failure_summary_ignores_arbitrary_fields_and_values(self):
        helper = module("failure_summary", "public-failure-summary.py")
        report = helper.summary(PRIVATE, PRIVATE, PRIVATE, {
            "verify": "failure", "build": "success", "core": PRIVATE,
            "argv": [PRIVATE], "stdout": PRIVATE, "stderr": PRIVATE, "error": PRIVATE})
        self.assertEqual(report["error_category"], "verify")
        self.assertEqual(report["tests"]["core"], "unknown")
        text = json.dumps(report)
        for marker in ["synthetic-private-marker", "argv", "stdout", "stderr"]:
            self.assertNotIn(marker, text)
        self.assertEqual(set(report), {"schema_version", "version", "architecture", "source_sha", "scope", "result", "error_category", "tests"})


if __name__ == "__main__":
    unittest.main()
