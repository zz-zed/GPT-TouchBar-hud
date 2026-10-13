#!/usr/bin/env python3
"""Summarize native dependency results; publishing owns cross-run API checks."""
import argparse
import json
import os
from pathlib import Path
import sys

from ci_policy import PolicyError, matrices, pr_event_requires_checks
from release_artifacts import ReleaseError, sha


def validate_gate(profile, event, source_sha, needs, payload=None):
    allowed = {"pull_request": ("docs", "pr-standard", "pr-full"),
               "push": ("docs", "main-full"), "workflow_dispatch": ("recovery-full",)}
    if profile not in allowed.get(event, ()):
        raise PolicyError(f"Profile {profile} is invalid for {event}")
    checks_required = event != "pull_request" or pr_event_requires_checks(payload)
    native_required = checks_required and profile != "docs"
    expected = {"source": "success", "regression": "success" if native_required else "skipped",
                "build": "success" if native_required else "skipped"}
    if (not isinstance(needs, dict) or any(not isinstance(needs.get(key), dict) for key in expected)
            or any(needs.get(key, {}).get("result") != value
                                         for key, value in expected.items())):
        raise PolicyError("Source or required matrix did not succeed (or unexpected docs execution)")
    outputs = needs["source"].get("outputs", {})
    if not isinstance(outputs, dict):
        raise PolicyError("Missing source outputs")
    if outputs.get("sha") != sha(source_sha):
        raise PolicyError("Source job did not resolve the expected immutable build commit")
    if (outputs.get("profile") != profile
            or outputs.get("checks_required") != str(checks_required).lower()
            or outputs.get("build_required") != ("false" if profile == "docs" else "true")):
        raise PolicyError("Missing or inconsistent source policy outputs")
    for key, expected_matrix in zip(("regression_matrix", "build_matrix"), matrices(profile)):
        try:
            actual = json.loads(outputs[key])
        except (KeyError, TypeError, ValueError) as error:
            raise PolicyError(f"Missing or invalid {key}") from error
        if actual != expected_matrix:
            raise PolicyError(f"Unexpected {key}: missing, duplicate or changed matrix entry")
    return checks_required


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--event", required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    try:
        payload = {}
        if args.event == "pull_request":
            try:
                payload = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
            except (KeyError, OSError, ValueError):
                pass  # Missing event data can never exempt code checks.
        checks_required = validate_gate(args.profile, args.event, args.source_sha,
                                        json.loads(os.environ["CI_NEEDS_JSON"]), payload)
    except (PolicyError, ReleaseError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"CI Gate failed: {error}", file=sys.stderr)
        return 1
    print(f"CI Gate passed: {args.profile}" if checks_required else
          "PR metadata only: existing code checks remain authoritative")
    return 0


if __name__ == "__main__":
    sys.exit(main())
