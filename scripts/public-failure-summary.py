#!/usr/bin/env python3
"""Create a fixed-field release failure summary without reading raw evidence."""
import argparse
import json
from pathlib import Path
import re

STEPS = ("source", "publication", "sdk", "helpers", "core", "build", "smoke", "package", "metadata", "verify", "payload")
OUTCOMES = {"success", "failure", "cancelled", "skipped"}


def summary(version, arch, source_sha, outcomes):
    results = {name: outcomes.get(name) if outcomes.get(name) in OUTCOMES else "unknown" for name in STEPS}
    return {
        "schema_version": 1,
        "version": version if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) else "unknown",
        "architecture": arch if arch in {"arm64", "x86_64"} else "unknown",
        "source_sha": source_sha if re.fullmatch(r"[0-9a-f]{40}", source_sha) else None,
        "scope": "native-release",
        "result": "failed",
        "error_category": next((name for name in STEPS if results[name] == "failure"), "workflow"),
        "tests": results,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="")
    parser.add_argument("--arch", required=True)
    parser.add_argument("--source-sha", default="")
    parser.add_argument("--step", action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    outcomes = dict(item.split("=", 1) for item in args.step if "=" in item)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(summary(args.version, args.arch, args.source_sha, outcomes), indent=2) + "\n")


if __name__ == "__main__":
    main()
