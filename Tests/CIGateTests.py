#!/usr/bin/env python3
"""Offline CI acceptance and fail-closed run-attempt checks."""
import copy
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from ci_policy import PolicyError, matrices, required_jobs
from ci_gate import validate_gate
from release_artifacts import GitHub

REPO = "zz-zed/GPT-TouchBar-hud"
SHA = "a" * 40


def fixtures(profile, event):
    run = {"id": 200, "run_attempt": 2, "event": event, "head_sha": SHA,
           "path": ".github/workflows/build-dmg.yml", "repository": {"full_name": REPO}}
    jobs = [{"name": name, "run_id": 200, "run_attempt": 2,
             "status": "completed", "conclusion": "success"} for name in required_jobs(profile)]
    needs = {key: {"result": "skipped" if profile == "docs" and key != "source" else "success"}
             for key in ("source", "regression", "build")}
    needs["source"]["outputs"] = {"sha": SHA}
    return run, jobs, needs


class CIGateTests(unittest.TestCase):
    def validate(self, profile="main-full", event="push", mutate=None):
        run, jobs, needs = fixtures(profile, event)
        if mutate:
            mutate(run, jobs, needs)
        validate_gate(run, jobs, profile, 200, 2, event, SHA, needs, REPO)

    def test_all_five_profiles_require_their_exact_jobs(self):
        for profile, event, count in (("docs", "pull_request", 1), ("pr-standard", "pull_request", 4),
                                      ("pr-full", "pull_request", 7), ("main-full", "push", 7),
                                      ("recovery-full", "workflow_dispatch", 7)):
            with self.subTest(profile=profile):
                self.validate(profile, event)
                self.assertEqual(len(required_jobs(profile)), count)
        regression, build = matrices("pr-standard")
        self.assertEqual(len(regression["include"]), 2)
        self.assertEqual(build["include"], [{"arch": "arm64", "runner": "macos-15", "kind": "App"}])

    def test_each_required_job_must_be_present_unique_and_successful(self):
        for index in range(7):
            for failure in ("missing", "duplicate", "failure", "cancelled", "skipped", "in-progress",
                            "wrong-run", "wrong-attempt", "missing-attempt"):
                def mutate(run, jobs, needs):
                    if failure == "missing":
                        jobs.pop(index)
                    elif failure == "duplicate":
                        jobs.append(copy.deepcopy(jobs[index]))
                    elif failure == "in-progress":
                        jobs[index]["status"] = "in_progress"
                    elif failure == "wrong-run":
                        jobs[index]["run_id"] = 201
                    elif failure == "wrong-attempt":
                        jobs[index]["run_attempt"] = 1
                    elif failure == "missing-attempt":
                        jobs[index].pop("run_attempt")
                    else:
                        jobs[index]["conclusion"] = failure
                with self.subTest(index=index, failure=failure), self.assertRaises(PolicyError):
                    self.validate(mutate=mutate)

    def test_missing_or_failed_aggregate_never_overrides_individual_jobs(self):
        for key in ("source", "regression", "build"):
            for status in ("failure", "cancelled", "skipped", "missing"):
                def mutate(run, jobs, needs):
                    if status == "missing":
                        needs.pop(key)
                    else:
                        needs[key]["result"] = status
                with self.subTest(key=key, status=status), self.assertRaises(PolicyError):
                    self.validate(mutate=mutate)

    def test_run_identity_or_profile_mismatch_fails(self):
        for key, value in (("id", 201), ("run_attempt", 1), ("head_sha", "b" * 40),
                           ("event", "pull_request"), ("path", "other.yml"),
                           ("repository", {"full_name": "other/repo"})):
            with self.subTest(key=key), self.assertRaises(PolicyError):
                self.validate(mutate=lambda run, jobs, needs: run.update({key: value}))
        for profile in ("typo", "pr-standard", "recovery-full"):
            with self.subTest(profile=profile), self.assertRaises(PolicyError):
                self.validate(profile, "push")

    def test_attempt_endpoint_binds_missing_api_attempt_but_preserves_mismatch(self):
        api = GitHub(REPO, "fixture")
        jobs = [{"name": "legacy", "run_id": 200}, {"name": "wrong", "run_attempt": 1}]
        with mock.patch.object(api, "pages", return_value=jobs) as pages:
            bound = api.attempt_jobs(200, 2)
        self.assertEqual(pages.call_args.args, (api.prefix + "/actions/runs/200/attempts/2/jobs", "jobs"))
        self.assertEqual([job["run_attempt"] for job in bound], [2, 1])

    def test_unavailable_job_collection_fails(self):
        with self.assertRaises(PolicyError):
            self.validate(mutate=lambda run, jobs, needs: jobs.append(None))

    def test_pr_head_identity_and_merge_preview_source_are_bound_separately(self):
        run, jobs, needs = fixtures("pr-full", "pull_request")
        merge_sha = "b" * 40
        needs["source"]["outputs"]["sha"] = merge_sha
        validate_gate(run, jobs, "pr-full", 200, 2, "pull_request", SHA, needs, REPO, merge_sha)
        with self.assertRaises(PolicyError):
            validate_gate(run, jobs, "pr-full", 200, 2, "pull_request", SHA, needs, REPO, SHA)


if __name__ == "__main__":
    unittest.main()
