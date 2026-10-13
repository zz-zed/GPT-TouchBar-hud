#!/usr/bin/env python3
"""Print true when a main push needs the full macOS build and test matrix.

An unknown revision or Git failure runs the full matrix. Release selection still
requires a successful run with both architecture build jobs and matching artifacts.
"""

import argparse
import json
import os
import re
import subprocess
from pathlib import Path

from ci_policy import matrices, profile_for


SHA_PATTERN = re.compile(r"[0-9a-fA-F]{40}\Z")


def needs_build(paths):
    return profile_for("push", paths) != "docs"


def changed_paths(before, after):
    if not SHA_PATTERN.fullmatch(before or "") or not SHA_PATTERN.fullmatch(after or ""):
        return None
    if before == "0" * 40:
        return None
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "-z", "--no-renames", before, after],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return [path.decode("utf-8", "surrogateescape") for path in result.stdout.split(b"\0") if path]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True)
    parser.add_argument("--after", required=True)
    parser.add_argument("--event", choices=("push", "pull_request", "workflow_dispatch"), default="push")
    parser.add_argument("--github-output")
    args = parser.parse_args()
    paths = changed_paths(args.before, args.after)
    added = set()
    if paths is not None and args.event == "pull_request":
        for path in paths:
            if not path.startswith(("Sources/", "Tests/")):
                continue
            try:
                subprocess.run(["git", "cat-file", "-e", f"{args.before}:{path}"],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except (OSError, subprocess.CalledProcessError):
                added.add(path)
    labels = []
    if args.event == "pull_request":
        try:
            event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
            labels = [label["name"] for label in event["pull_request"]["labels"]]
        except (KeyError, OSError, ValueError, TypeError):
            paths = None
    force = os.environ.get("CI_FORCE_FULL_PR", "").lower() == "true" or "ci:full" in labels
    profile = profile_for(args.event, paths, force_full=force, added_paths=added)
    required = "false" if profile == "docs" else "true"
    print(required)  # Original boolean CLI contract.
    if args.github_output:
        regression, build = matrices(profile)
        with Path(args.github_output).open("a") as output:
            for key, value in {"profile": profile, "build_required": required,
                               "regression_matrix": json.dumps(regression, separators=(",", ":")),
                               "build_matrix": json.dumps(build, separators=(",", ":"))}.items():
                output.write(f"{key}={value}\n")


if __name__ == "__main__":
    raise SystemExit(main())
