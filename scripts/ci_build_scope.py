#!/usr/bin/env python3
"""Print true when a main push needs the full macOS build and test matrix.

An unknown revision or Git failure runs the full matrix. Release selection still
requires a successful run with both architecture build jobs and matching artifacts.
"""

import argparse
import re
import subprocess


BUILD_FILES = {"Package.swift", "RELEASE_NOTES.md"}
BUILD_PREFIXES = (
    ".github/workflows/",
    "HookCore/",
    "HookHelper/",
    "ResetNewsCore/",
    "Resources/",
    "Sources/",
    "Tests/",
    "scripts/",
)
SHA_PATTERN = re.compile(r"[0-9a-fA-F]{40}\Z")


def needs_build(paths):
    return any(path in BUILD_FILES or path.startswith(BUILD_PREFIXES) for path in paths)


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
    args = parser.parse_args()
    paths = changed_paths(args.before, args.after)
    if paths is None or needs_build(paths):
        print("true")
    else:
        print("false")


if __name__ == "__main__":
    raise SystemExit(main())
