#!/usr/bin/env python3
"""Native Gate acceptance: result, immutable source and matrix omissions."""
import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from ci_policy import PolicyError, matrices, pr_event_requires_checks
from ci_gate import validate_gate

SHA = "a" * 40


def fixtures(profile, event, payload=None):
    checks = event != "pull_request" or pr_event_requires_checks(payload)
    native = checks and profile != "docs"
    needs = {key: {"result": "success" if key == "source" or native else "skipped"}
             for key in ("source", "regression", "build")}
    regression, build = matrices(profile)
    needs["source"]["outputs"] = {
        "sha": SHA, "profile": profile, "checks_required": str(checks).lower(),
        "build_required": "false" if profile == "docs" else "true",
        "regression_matrix": json.dumps(regression), "build_matrix": json.dumps(build)}
    return needs


class CIGateTests(unittest.TestCase):
    def validate(self, profile="main-full", event="push", mutate=None, payload=None):
        needs = fixtures(profile, event, payload)
        if mutate:
            mutate(needs)
        return validate_gate(profile, event, SHA, needs, payload)

    def test_all_profiles_accept_only_expected_native_results(self):
        for profile, event in (("docs", "pull_request"), ("docs", "push"), ("pr-standard", "pull_request"),
                               ("pr-full", "pull_request"), ("main-full", "push"),
                               ("recovery-full", "workflow_dispatch")):
            with self.subTest(profile=profile, event=event):
                self.assertTrue(self.validate(profile, event))

    def test_missing_failed_cancelled_skipped_and_unfinished_dependencies_fail(self):
        for key in ("source", "regression", "build"):
            for status in ("failure", "cancelled", "skipped", "in_progress", None, "missing", "invalid"):
                def mutate(needs):
                    if status == "missing":
                        needs.pop(key)
                    elif status == "invalid":
                        needs[key] = None
                    else:
                        needs[key]["result"] = status
                with self.subTest(key=key, status=status), self.assertRaises(PolicyError):
                    self.validate(mutate=mutate)

    def test_docs_cannot_claim_native_success(self):
        for key in ("regression", "build"):
            with self.subTest(key=key), self.assertRaises(PolicyError):
                self.validate("docs", "pull_request", lambda n: n[key].update(result="success"))

    def test_matrix_missing_duplicate_or_modified_entries_fail(self):
        for profile, event in (("pr-standard", "pull_request"), ("main-full", "push")):
            for key in ("regression_matrix", "build_matrix"):
                for mutation in ("missing", "duplicate", "wrong-runner", "empty", "invalid"):
                    def mutate(needs):
                        outputs = needs["source"]["outputs"]
                        matrix = json.loads(outputs[key])
                        if mutation == "missing":
                            matrix["include"].pop()
                        elif mutation == "duplicate":
                            matrix["include"].append(copy.deepcopy(matrix["include"][0]))
                        elif mutation == "wrong-runner":
                            matrix["include"][0]["runner"] = "ubuntu-latest"
                        elif mutation == "empty":
                            matrix["include"] = []
                        else:
                            outputs[key] = "invalid-json"
                            return
                        outputs[key] = json.dumps(matrix)
                    with self.subTest(profile=profile, key=key, mutation=mutation), self.assertRaises(PolicyError):
                        self.validate(profile, event, mutate)

    def test_missing_outputs_or_source_identity_fail(self):
        for key in fixtures("main-full", "push")["source"]["outputs"]:
            with self.subTest(key=key), self.assertRaises(PolicyError):
                self.validate(mutate=lambda n: n["source"]["outputs"].pop(key))
        with self.assertRaises(PolicyError):
            self.validate(mutate=lambda n: n["source"]["outputs"].update(sha="b" * 40))
        with self.assertRaises(PolicyError):
            self.validate(mutate=lambda n: n["source"]["outputs"].update(checks_required="false"))
        with self.assertRaises(PolicyError):
            self.validate(mutate=lambda n: n["source"]["outputs"].update(build_required="false"))

    def test_event_profile_mismatch_fails(self):
        for profile in ("typo", "pr-standard", "recovery-full"):
            with self.subTest(profile=profile), self.assertRaises(PolicyError):
                self.validate(profile, "push")

    def test_known_metadata_is_separate_and_cannot_assert_code_success(self):
        payloads = [{"action": "labeled", "label": {"name": "documentation"}},
                    {"action": "unlabeled", "label": {"name": "documentation"}},
                    {"action": "edited", "changes": {"body": {"from": "old"}}}]
        for payload in payloads:
            with self.subTest(payload=payload):
                self.assertFalse(self.validate("pr-full", "pull_request", payload=payload))
                with self.assertRaises(PolicyError):
                    self.validate("pr-full", "pull_request",
                                  lambda n: n["build"].update(result="success"), payload)
        with self.assertRaises(PolicyError):
            self.validate("pr-full", "pull_request",
                          lambda n: n["source"]["outputs"].update(checks_required="false"),
                          {"action": "edited", "changes": {"base": {"ref": {"from": "develop"}}}})

    def test_workflow_uses_validated_matrices_without_gate_api_permissions(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/build-dmg.yml").read_text()
        for job, key in (("regression", "regression_matrix"), ("build", "build_matrix")):
            section = workflow.split("\n  " + job + ":\n", 1)[1].split("\n  gate:", 1)[0]
            if job == "regression":
                section = section.split("\n  build:", 1)[0]
            self.assertIn("matrix: ${{ fromJSON(needs.source.outputs." + key + ") }}", section)
            self.assertIn("checks_required == 'true'", section)
            self.assertIn("fail-fast: false", section)
        gate = workflow.split("\n  gate:\n", 1)[1]
        self.assertNotIn("actions: read", gate)
        self.assertNotIn("GH_TOKEN", gate)
        self.assertIn("'PR metadata' || 'CI Gate'", gate)
        self.assertIn("format('metadata-{0}', github.run_id)", workflow)
        self.assertIn("CI_SUITE: ${{ matrix.suite }}", workflow)
        self.assertEqual(workflow.count('run: python3 "$CI_REGRESSION_SCRIPT" --suite "$CI_SUITE"'), 1)


if __name__ == "__main__":
    unittest.main()
