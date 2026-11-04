#!/usr/bin/env python3
"""Check tracked publication files without printing matched private content."""

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


TEXT_EXTENSIONS = {".md", ".txt", ".rst", ".adoc", ".json", ".yaml", ".yml", ".toml", ".html", ".xml", ".csv", ".tsv"}
PUBLIC_DIRS = {"documentation", "docs", "marketing", "assets", "experiments", "resources"}
ARCHIVE_DIRS = {"validation", "evidence", "archive"}
PLACEHOLDER_USERS = {"user", "username", "your_user", "your_username", "example", "example-user", "shared", "public", "default", "guest", "runner", "runneradmin"}
HOME_PATHS = (
    re.compile(r"(?<![\w/])/(?:Users|home)/([^/\\\r\n`\"<>]+)"),
    re.compile(r"\b[A-Za-z]:[\\/]+(?:Users|Documents and Settings)[\\/]+([^/\\\r\n`\"<>]+)"),
)
INTERNAL_SESSION = re.compile(r"\b(?!https?://|file://)[a-z][a-z0-9+.-]*://(?:threads?|chats?|conversations?|sessions?)/[a-z0-9][a-z0-9._~%/-]*", re.I)
PRIVATE_WORKTREE = re.compile(r"(?<!\w)\.[\w.-]+[\\/]+worktrees?[\\/]+[^\s/\\<>`\"']+")
PROMPT_KEYS = {"prompt", "prompts", "negative_prompt", "system_prompt", "developer_prompt"}
CALL_KEYS = {"tool", "model", "references", "source_file", "total_calls", "attempts", "requests", "responses"}


def publication_file(path):
    # Functional tests intentionally contain privacy sentinels and synthetic data.
    if path.parts[0] == "Tests":
        return False
    suffix = path.suffix.lower()
    return suffix in TEXT_EXTENSIONS and (
        len(path.parts) == 1
        or path.parts[0].lower() in PUBLIC_DIRS
        or suffix in {".md", ".rst", ".adoc"}
    )


def prompt_record(text, path):
    if path.suffix.lower() != ".json":
        return False
    try:
        pending = [json.loads(text)]
    except (ValueError, RecursionError):
        return False
    keys = set()
    has_prompt = False
    while pending:
        value = pending.pop()
        if isinstance(value, dict):
            keys.update(str(k).lower() for k in value)
            for key, item in value.items():
                if str(key).lower() in PROMPT_KEYS:
                    has_prompt |= isinstance(item, str) and bool(item.strip())
                    has_prompt |= isinstance(item, list) and any(isinstance(x, str) and x.strip() for x in item)
                pending.append(item)
        elif isinstance(value, list):
            pending.extend(value)
    return has_prompt and (bool(keys & CALL_KEYS) or path.parts[0].lower() in {"marketing", "assets"})


def scan_file(root, name):
    if name.startswith("/") or "\\" in name or any(p in {".", "..", ""} for p in name.split("/")):
        return [(0, "invalid relative file path")], False
    path = PurePosixPath(name)
    parts = tuple(p.lower() for p in path.parts)
    candidate = root.joinpath(*path.parts)
    archived = parts[0] == ".local" or (parts[0] in {"documentation", "docs"} and any(p in ARCHIVE_DIRS for p in parts[1:-1]))
    raw_log = parts[0] in PUBLIC_DIRS and path.suffix.lower() == ".log"
    if not archived and not raw_log and not publication_file(path):
        return [], False
    if any(root.joinpath(*path.parts[:i]).is_symlink() for i in range(1, len(path.parts) + 1)):
        return [(0, "publication files must not traverse symbolic links")], False
    if not candidate.exists() and not candidate.is_symlink():
        return [], False  # Allow locally deleted tracked files.
    if archived:
        return [(0, "raw working records belong outside the published tree")], False
    if raw_log:
        return [(0, "raw log file in publication materials")], False
    if not candidate.is_file():
        return [(0, "publication entry is not a regular file")], False
    try:
        text = candidate.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return [(0, "cannot read publication text as UTF-8")], False
    if "\0" in text:
        return [(0, "binary data in a publication text file")], False
    findings = []
    for number, line in enumerate(text.splitlines(), 1):
        normalized = line.replace("\\/", "/")
        for pattern in HOME_PATHS:
            for match in pattern.finditer(normalized):
                user = match.group(1).strip().lower()
                if user not in PLACEHOLDER_USERS and not user.startswith(("$", "%", "{", "[")):
                    findings.append((number, "personal absolute home path; use a relative path or placeholder"))
                    break
        if INTERNAL_SESSION.search(normalized):
            findings.append((number, "internal conversation or session link"))
        if PRIVATE_WORKTREE.search(normalized):
            findings.append((number, "private worktree location"))
    if prompt_record(text, path):
        match = re.search(r'"(?:prompt|prompts|negative_prompt|system_prompt|developer_prompt)"\s*:', text)
        line = text.count("\n", 0, match.start()) + 1 if match else 1
        findings.append((line, "raw generation prompt/call record in publication materials"))
    return findings, True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1], help="repository root")
    parser.add_argument("--files-from", type=Path, help="NUL-separated relative file list; default: git ls-files")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        if args.files_from:
            raw = args.files_from.read_bytes()
        else:
            raw = subprocess.run(["git", "ls-files", "-z", "--cached"], cwd=root, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    except (OSError, subprocess.CalledProcessError):
        print("Cannot obtain the tracked file list; run in a checkout or pass --files-from.", file=sys.stderr)
        return 2
    if raw and not raw.endswith(b"\0"):
        print("The file list must use NUL-terminated relative paths.", file=sys.stderr)
        return 2
    names = sorted(set(p.decode("utf-8", errors="surrogateescape") for p in raw.split(b"\0") if p))
    failures = []
    checked = 0
    for name in names:
        findings, read = scan_file(root, name)
        checked += read
        failures.extend((name, line, rule) for line, rule in findings)
    for name, line, rule in failures[:40]:
        print(f"{json.dumps(name, ensure_ascii=True)}:{line}: {rule}", file=sys.stderr)
    if failures:
        print(f"Public content check failed: {len(failures)} findings across {len(set(f[0] for f in failures))} files. Matched values are omitted.", file=sys.stderr)
        return 1
    print(f"Public content check passed: {checked} publication text files checked.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
