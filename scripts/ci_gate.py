#!/usr/bin/env python3
"""Require the exact profile jobs from this run attempt; API failures fail closed."""
import argparse
import json
import os
import sys

from ci_policy import PolicyError, required_jobs, validate_jobs
from release_artifacts import GitHub, ReleaseError, WORKFLOW_PATH, sha


def validate_gate(run, jobs, profile, run_id, attempt, event, head_sha, needs, repository, source_sha=None):
    if (not isinstance(run, dict) or run.get("id") != run_id or run.get("run_attempt") != attempt
            or run.get("event") != event or run.get("head_sha") != sha(head_sha)
            or run.get("path", "").split("@")[0] != WORKFLOW_PATH
            or run.get("repository", {}).get("full_name", "").lower() != repository.lower()):
        raise PolicyError("Cannot bind CI Gate to this workflow run attempt and commit")
    allowed = {"pull_request": ("docs", "pr-standard", "pr-full"),
               "push": ("docs", "main-full"), "workflow_dispatch": ("recovery-full",)}
    if profile not in allowed.get(event, ()):
        raise PolicyError(f"Profile {profile} is invalid for {event}")
    expected = {"source": "success", "regression": "skipped" if profile == "docs" else "success",
                "build": "skipped" if profile == "docs" else "success"}
    if not isinstance(needs, dict) or any(needs.get(key, {}).get("result") != value
                                         for key, value in expected.items()):
        raise PolicyError("Source or required matrix did not succeed (or unexpected docs execution)")
    if needs["source"].get("outputs", {}).get("sha") != sha(source_sha or head_sha):
        raise PolicyError("Source job did not resolve the expected immutable build commit")
    validate_jobs(jobs, required_jobs(profile), run_id, attempt)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--attempt", required=True, type=int)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--event", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    try:
        api = GitHub(args.repository, os.environ.get("GH_TOKEN", ""))
        run = api.request("GET", f"{api.prefix}/actions/runs/{args.run_id}/attempts/{args.attempt}")
        jobs = api.attempt_jobs(args.run_id, args.attempt)
        validate_gate(run, jobs, args.profile, args.run_id, args.attempt, args.event,
                      args.head_sha, json.loads(os.environ["CI_NEEDS_JSON"]), args.repository, args.source_sha)
    except (PolicyError, ReleaseError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"CI Gate failed: {error}", file=sys.stderr)
        return 1
    print(f"CI Gate passed: {args.profile}, run {args.run_id}, attempt {args.attempt}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
