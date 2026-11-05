#!/usr/bin/env python3
"""Select exact CI refs and PR text for the shared publication checker."""
import importlib.util
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("public_content", ROOT / "scripts/check-public-content.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def check():
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    kind = os.environ["GITHUB_EVENT_NAME"]
    review = checker.Review(ROOT)
    try:
        if kind == "pull_request":
            pr = event["pull_request"]
            payload = json.dumps({"title": pr["title"], "body": pr.get("body") or ""}).encode()
            review.add("pull-request", checker.scan_content("payload.json", payload, force_text=True))
            ref, base = pr["head"]["sha"], pr["base"]["sha"]
        else:
            if event.get("deleted"):
                return 0
            ref = os.environ["GITHUB_REF"] if os.environ["GITHUB_REF"].startswith("refs/tags/") else os.environ["GITHUB_SHA"]
            base = event.get("before", checker.ZERO)
            if base == checker.ZERO:
                base = checker.git(ROOT, "rev-parse", "refs/remotes/origin/main").decode().strip()
        if not re.fullmatch(r"[0-9a-f]{40}", base):
            raise checker.CheckError("Invalid base")
        # Fetch old force-push/PR bases explicitly if checkout did not obtain them.
        try:
            checker.git(ROOT, "cat-file", "-e", base + "^{commit}")
        except checker.CheckError:
            checker.git(ROOT, "fetch", "--no-tags", "origin", base)
        oid = checker.git(ROOT, "rev-parse", "--verify", ref).decode().strip()
        review.history([oid], [base])
        return review.report()
    finally:
        review.objects.close()


if __name__ == "__main__":
    try:
        raise SystemExit(check())
    except (checker.CheckError, OSError, ValueError, KeyError, UnicodeError):
        print("Public content CI coverage unavailable (PC009); refusing to pass.", file=sys.stderr)
        raise SystemExit(2)
