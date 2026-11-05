#!/usr/bin/env python3
"""Check the exact Git or publication payload; never print matched content."""

import argparse
import json
import hashlib
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
import sys
import zlib


TEXT_EXTENSIONS = {".md", ".txt", ".rst", ".adoc", ".json", ".yaml", ".yml", ".toml", ".html", ".xml", ".csv", ".tsv"}
PUBLIC_IMAGE_DIRS = {"marketing", "assets"}
ARCHIVE_DIRS = {"validation", "evidence", "archive"}
PLACEHOLDER_USERS = {"user", "username", "your_user", "your_username", "example", "example-user", "shared", "public", "default", "guest", "runner", "runneradmin"}
HOME_PATHS = (
    re.compile(r"(?<![\w/])/(?:Users|home)/([^/\\\s`\"<>]+)"),
    re.compile(r"\b[A-Za-z]:[\\/]+(?:Users|Documents and Settings)[\\/]+([^/\\\s`\"<>]+)"),
)
INTERNAL_SESSION = re.compile(r"\b(?!https?://|file://)[a-z][a-z0-9+.-]*://(?:threads?|chats?|conversations?|sessions?)/[a-z0-9][a-z0-9._~%/-]*", re.I)
PRIVATE_CONVERSATION = re.compile(r"(?:chatgpt-conversation://|https?://(?:chatgpt\.com|chat\.openai\.com)/(?:g/[^/]+/)?c/)[a-z0-9_-]+", re.I)
PRIVATE_WORKTREE = re.compile(r"(?<!\w)\.[\w.-]+[\\/]+worktrees?[\\/]+[^\s/\\<>`\"']+")
PROMPT_KEYS = {"prompt", "prompts", "negative_prompt", "system_prompt", "developer_prompt"}
CALL_KEYS = {"tool", "model", "references", "source_file", "total_calls", "attempts", "requests", "responses"}
PNG_TEXT_LIMIT = 1024 * 1024


def png_text(kind, payload):
    """Decode one text chunk with a bounded compressed output size."""
    keyword, data = payload.split(b"\0", 1)
    if not 1 <= len(keyword) <= 79:
        raise ValueError("invalid PNG text keyword")
    compressed = False
    encoding = "latin-1"
    labels = []
    if kind == b"zTXt":
        if not data or data[0] != 0:
            raise ValueError("invalid PNG compression method")
        compressed, data = True, data[1:]
    elif kind == b"iTXt":
        if len(data) < 2 or data[0] not in (0, 1) or data[1] != 0:
            raise ValueError("invalid PNG international text header")
        compressed, encoding = data[0] == 1, "utf-8"
        language, translated, data = data[2:].split(b"\0", 2)
        labels = [language.decode("ascii"), translated.decode("utf-8")]
    if compressed:
        decoder = zlib.decompressobj()
        data = decoder.decompress(data, PNG_TEXT_LIMIT + 1)
        if not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
            raise ValueError("invalid or oversized PNG compressed text")
    if len(data) > PNG_TEXT_LIMIT:
        raise ValueError("PNG text exceeds the review size limit")
    return keyword.decode("latin-1"), data.decode(encoding), labels


def scan_png(data, path):
    """Review publication PNG containers without changing their provenance."""
    if len(data) > 64 * 1024 * 1024:
        return [(0, "publication image exceeds the review size limit")]
    invalid = [(0, "publication image has an invalid PNG container")]
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return invalid
    offset = 8
    found_pixels = False
    text_fields = {}
    text_size = 0
    findings = []
    first = True
    while offset + 12 <= len(data):
        size = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + size
        if (end > len(data) or (first and (kind != b"IHDR" or size != 13))
                or (not first and kind == b"IHDR")):
            return invalid
        payload = data[offset + 8:end - 4]
        expected_crc = struct.unpack_from(">I", data, end - 4)[0]
        if zlib.crc32(kind + payload) != expected_crc:
            return invalid
        first = False
        found_pixels |= kind == b"IDAT"
        if kind in {b"tEXt", b"zTXt", b"iTXt"}:
            try:
                key, value, labels = png_text(kind, payload)
            except (ValueError, UnicodeError, zlib.error):
                return [(0, "publication image contains invalid or oversized text metadata")]
            text_size += sum(len(item.encode("utf-8")) for item in [key, value, *labels])
            if text_size > PNG_TEXT_LIMIT:
                return [(0, "publication image contains invalid or oversized text metadata")]
            if any(scan_text(item) or prompt_record(item, path.with_suffix(".json")) for item in [key, value, *labels]):
                findings.append((0, "private path, session or generation record in image text metadata"))
            # Keep duplicate fields: a later benign value must not hide an earlier prompt.
            text_fields.setdefault(key, []).append(value)
        offset = end
        if kind == b"IEND":
            if size or end != len(data) or not found_pixels:
                return invalid
            if prompt_record(json.dumps(text_fields), path.with_suffix(".json")):
                findings.append((0, "raw generation record in image text metadata"))
            return findings
    return invalid


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


def scan_text(text):
    findings = []
    for number, line in enumerate(text.splitlines(), 1):
        normalized = line.replace("\\/", "/")
        for pattern in HOME_PATHS:
            for match in pattern.finditer(normalized):
                user = match.group(1).strip().lower()
                if user not in PLACEHOLDER_USERS and not user.startswith(("$", "%", "{", "[")):
                    findings.append((number, "PC010 personal absolute home path; use a relative path or placeholder"))
                    break
        if INTERNAL_SESSION.search(normalized) or PRIVATE_CONVERSATION.search(normalized):
            findings.append((number, "PC011 internal conversation or session link"))
        if PRIVATE_WORKTREE.search(normalized):
            findings.append((number, "PC012 private worktree location"))
    return findings


POLICY = ".github/public-content-paths.txt"
# Names identify working records, not product concepts such as a prompt template.
WORK_NAMES = re.compile(r"^(?:task[-_]plan|findings|progress|handoff(?:[-_].*)?|execution[-_]log|session[-_]transcript|raw[-_]prompts?)(?:\.[^.]+)?$", re.I)
WORK_HEADINGS = re.compile(r"^\s*(?:#{1,6}\s+)(?:task plan|implementation plan|execution log|work log|session transcript|conversation transcript|session summary|chat history|任务执行计划|任务计划|执行记录|执行日志|交接记录|会话原文|原始提示词)\s*$", re.I | re.M)
NO_REPLY = re.compile(r"^[^<>\s@]+@users\.noreply\.github\.com$", re.I)
ZERO = "0" * 40


class CheckError(Exception):
    """Messages are fixed categories, never subprocess output or input data."""


def git(root, *args, data=None):
    result = subprocess.run(["git", *args], cwd=root, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise CheckError("Git object or reference unavailable; no coverage was skipped")
    return result.stdout


class Objects:
    def __init__(self, root):
        self.process = subprocess.Popen(["git", "cat-file", "--batch"], cwd=root,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    def get(self, oid):
        if not re.fullmatch(r"[0-9a-f]{40,64}", oid):
            raise CheckError("Invalid Git object ID")
        self.process.stdin.write((oid + "\n").encode())
        self.process.stdin.flush()
        header = self.process.stdout.readline().split()
        if len(header) != 3 or not header[2].isdigit():
            raise CheckError("Git object unavailable")
        size = int(header[2])
        if size > 64 * 1024 * 1024:
            raise CheckError("Object exceeds the 64 MiB review limit")
        value = self.process.stdout.read(size)
        if len(value) != size or self.process.stdout.read(1) != b"\n":
            raise CheckError("Incomplete Git object read")
        return header[1].decode(), value

    def close(self):
        try:
            self.process.stdin.close()
        except OSError:
            pass
        self.process.stdout.close()
        self.process.wait()


def path_rules(name):
    if name.startswith("/") or "\\" in name or any(p in {".", "..", ""} for p in name.split("/")):
        return [(0, "invalid relative file path")]
    path = PurePosixPath(name)
    parts = tuple(p.lower() for p in path.parts)
    private_directory = any(p in {".local", ".impeccable", "designs", "sessions", "transcripts", "worktrees"} for p in parts[:-1])
    archived = parts[0] in {"documentation", "docs"} and any(p in ARCHIVE_DIRS for p in parts[1:-1])
    if private_directory or archived or WORK_NAMES.fullmatch(path.name):
        return [(0, "PC001 working records belong outside Git")]
    if path.suffix.lower() in {".log", ".jsonl", ".zip", ".tar", ".gz"}:
        return [(0, "PC002 raw logs or archives are not publication inputs")]
    return []


def scan_content(name, data, mode="100644", force_text=False):
    findings = path_rules(name)
    if findings:
        return findings
    if mode not in {"100644", "100755"}:
        return [(0, "PC003 symlinks and submodules require a separate publication design")]
    path = PurePosixPath(name)
    if path.suffix.lower() == ".png" and not force_text:
        return scan_png(data, path) if path.parts[0].lower() in PUBLIC_IMAGE_DIRS else []
    try:
        text = data.decode("utf-8")
        if "\0" in text:
            raise UnicodeError()
    except UnicodeError:
        if force_text or path.suffix.lower() in TEXT_EXTENSIONS | {".swift", ".py", ".sh", ".mjs", ".js", ".plist"}:
            return [(0, "PC004 expected UTF-8 text")]
        return []  # Registered binary product assets; no rewriting or metadata stripping.
    findings = scan_text(text)
    if WORK_HEADINGS.search(text):
        findings.append((1, "PC005 private development process document"))
    json_path = PurePosixPath("payload.json") if force_text else path
    if prompt_record(text, json_path):
        findings.append((1, "PC006 raw generation prompt/call record"))
    # Decode JSON string values as well, so escaped paths and multi-line bodies are covered.
    if json_path.suffix.lower() == ".json":
        try:
            pending = [json.loads(text)]
            while pending:
                item = pending.pop()
                if isinstance(item, dict):
                    pending.extend(item.keys())
                    pending.extend(item.values())
                elif isinstance(item, list):
                    pending.extend(item)
                elif isinstance(item, str):
                    findings.extend(scan_text(item))
                    if WORK_HEADINGS.search(item):
                        findings.append((1, "PC005 private development process document"))
        except (ValueError, RecursionError):
            pass
    return sorted(set(findings))


def policy_paths(data):
    try:
        paths = data.decode("utf-8").splitlines()
    except UnicodeError:
        raise CheckError("Publication path registry must be UTF-8") from None
    if not paths or len(set(paths)) != len(paths) or POLICY not in paths or any(path_rules(p) for p in paths):
        raise CheckError("Invalid publication path registry")
    return set(paths)


class Review:
    def __init__(self, root):
        self.root = root
        self.objects = Objects(root)
        self.failures = []
        self.seen = set()
        self.checked = 0

    def add(self, label, findings):
        self.failures.extend((label, line, rule) for line, rule in findings)

    def entries(self, entries, scope):
        entries = list(entries)
        registry = next((oid for mode, oid, name in entries if name == POLICY and mode == "100644"), None)
        if registry is None:
            raise CheckError("Publication path registry is missing from the reviewed snapshot")
        allowed = policy_paths(self.objects.get(registry)[1])
        for mode, oid, name in entries:
            if name not in allowed:
                self.add(scope + ":" + name, [(0, "PC007 file is outside the reviewed publication path registry")])
                continue
            key = (mode, oid, name)
            if key in self.seen:
                continue
            self.seen.add(key)
            kind, data = self.objects.get(oid)
            self.add(scope + ":" + name, scan_content(name, data, mode) if kind == "blob" else [(0, "PC003 non-file object")])
            self.checked += 1

    def tree(self, oid):
        rows = git(self.root, "ls-tree", "-rz", "--full-tree", oid).split(b"\0")
        entries = []
        for row in filter(None, rows):
            meta, name = row.split(b"\t", 1)
            mode, kind, blob = meta.decode().split()
            entries.append((mode, blob, name.decode("utf-8")))
        self.entries(entries, oid[:12])

    def index(self):
        entries = []
        for row in filter(None, git(self.root, "ls-files", "--stage", "-z").split(b"\0")):
            meta, name = row.split(b"\t", 1)
            mode, oid, stage = meta.decode().split()
            if stage != "0":
                raise CheckError("Resolve the unmerged index before publication")
            entries.append((mode, oid, name.decode("utf-8")))
        self.entries(entries, "index")

    def metadata(self, oid, kind, data):
        text = data.decode("utf-8")
        self.add(oid[:12] + ":" + kind, scan_text(text))
        headers, _, message = text.partition("\n\n")
        self.add(oid[:12] + ":" + kind, scan_content("metadata.json", message.encode(), force_text=True))
        keys = ("author ", "committer ") if kind == "commit" else ("tagger ",)
        for key in keys:
            header = next((s for s in headers.splitlines() if s.startswith(key)), "")
            match = re.search(r"<([^<>]+)>", header)
            if not match or not NO_REPLY.fullmatch(match.group(1)):
                self.add(oid[:12] + ":" + kind, [(0, "PC008 use a public GitHub noreply author/committer/tagger identity")])
        for email in re.findall(r"(?im)^co-authored-by:.*<([^<>]+)>", message):
            if not NO_REPLY.fullmatch(email):
                self.add(oid[:12] + ":" + kind, [(0, "PC008 use public noreply co-author identity")])

    def history(self, tips, excludes):
        if git(self.root, "rev-parse", "--is-shallow-repository").strip() != b"false":
            raise CheckError("Full Git history is required; shallow review is refused")
        commits = []
        for tip in tips:
            kind, data = self.objects.get(tip)
            visited = set()
            while kind == "tag":
                if tip in visited:
                    raise CheckError("Cyclic tag")
                visited.add(tip)
                self.metadata(tip, kind, data)
                tip = data.split(b"\n", 1)[0].removeprefix(b"object ").decode()
                kind, data = self.objects.get(tip)
            if kind != "commit":
                raise CheckError("Published refs must resolve to commits")
            self.tree(tip)  # Check the tip even if it was already reachable on the remote.
            commits.append(tip)
        revisions = "\n".join(commits + ["^" + oid for oid in excludes]) + "\n"
        for oid in git(self.root, "rev-list", "--stdin", data=revisions.encode()).decode().splitlines():
            kind, data = self.objects.get(oid)
            self.metadata(oid, kind, data)
            self.tree(oid)  # Includes files added then removed before the final tip.

    def worktree(self, names):
        if (self.root / ".github").is_symlink() or (self.root / POLICY).is_symlink():
            raise CheckError("Publication registry must not traverse symlinks")
        allowed = policy_paths((self.root / POLICY).read_bytes())
        for name in names:
            self.add(name, path_rules(name))
            if name not in allowed:
                self.add(name, [(0, "PC007 file is outside the reviewed publication path registry")])
                continue
            path = self.root / name
            if any((self.root / Path(*PurePosixPath(name).parts[:i])).is_symlink() for i in range(1, len(PurePosixPath(name).parts) + 1)):
                self.add(name, [(0, "PC003 symbolic link")])
            elif path.exists():
                if path.stat().st_size > 64 * 1024 * 1024:
                    raise CheckError("File exceeds the review size limit")
                self.add(name, scan_content(name, path.read_bytes()))
                self.checked += 1

    def report(self):
        for label, line, rule in self.failures[:40]:
            # A filename can itself contain a private path/session. Hide such labels too.
            if scan_text(label) or any(ord(c) < 32 for c in label):
                label = "location-" + hashlib.sha256(label.encode()).hexdigest()[:12]
            print(f"{json.dumps(label, ensure_ascii=True)}:{line}: {rule}", file=sys.stderr)
        if self.failures:
            print(f"Public content check failed: {len(self.failures)} findings. Matched values are omitted.", file=sys.stderr)
            return 1
        print(f"Public content check passed: {self.checked} unique files checked.")
        return 0


def remote_excludes(root, remote):
    # Query actual advertised refs; stale local tracking refs must not hide outgoing commits.
    output = git(root, "ls-remote", "--heads", "--tags", remote)
    excludes = set()
    for line in output.decode().splitlines():
        oid = line.split()[0]
        result = subprocess.run(["git", "rev-parse", "--verify", oid + "^{commit}"], cwd=root,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if result.returncode == 0:
            excludes.add(result.stdout.decode().strip())
        # An unavailable remote commit cannot cover a locally reachable outgoing commit.
    return sorted(excludes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--index", action="store_true", help="read exact staged blobs, not working files")
    modes.add_argument("--ref", help="review a commit/tag tree and its new history")
    modes.add_argument("--pre-push", metavar="REMOTE", help="read Git pre-push updates from stdin")
    modes.add_argument("--files-from", type=Path, help="NUL-separated worktree file list")
    modes.add_argument("--payload", type=Path, action="append", help="final UTF-8 publication file; repeatable")
    parser.add_argument("--exclude", action="append", default=[], help="already reviewed commit, full SHA only")
    args = parser.parse_args()
    review = None
    try:
        root = args.root.resolve()
        review = Review(root)
        if args.payload:
            for number, path in enumerate(args.payload, 1):
                if path.is_symlink() or path.stat().st_size > 64 * 1024 * 1024:
                    raise CheckError("Invalid publication payload")
                review.add(f"payload-{number}", scan_content("payload" + path.suffix, path.read_bytes(), force_text=True))
                review.checked += 1
        elif args.index:
            review.index()
        elif args.ref or args.pre_push:
            excludes = []
            for value in args.exclude:
                if not re.fullmatch(r"[0-9a-f]{40,64}", value):
                    raise CheckError("Exclusions require full commit IDs")
                excludes.append(value)
            tips = []
            if args.pre_push:
                updates = sys.stdin.read().splitlines()
                for row in updates:
                    fields = row.split()
                    if len(fields) != 4:
                        raise CheckError("Invalid pre-push update")
                    local_ref, oid, remote_ref, old = fields
                    review.add("ref-name", scan_text(local_ref + "\n" + remote_ref))
                    if oid != ZERO:
                        tips.append(oid)
                if tips:
                    excludes.extend(remote_excludes(root, args.pre_push))
            else:
                tips = [git(root, "rev-parse", "--verify", args.ref).decode().strip()]
            if tips:
                review.history(tips, excludes)
        else:
            raw = args.files_from.read_bytes() if args.files_from else git(root, "ls-files", "-z", "--cached")
            if raw and not raw.endswith(b"\0"):
                raise CheckError("File list requires NUL-terminated relative paths")
            review.worktree(sorted(set(p.decode("utf-8") for p in raw.split(b"\0") if p)))
        return review.report()
    except CheckError as error:
        print(f"Public content check unavailable (PC009): {error}.", file=sys.stderr)
        return 2
    except (OSError, ValueError, UnicodeError, RecursionError):
        # No raw exception/command text: it may contain private content or local paths.
        print("Public content check could not complete (PC009 input, registry or Git history unavailable).", file=sys.stderr)
        return 2
    finally:
        if review:
            review.objects.close()


if __name__ == "__main__":
    raise SystemExit(main())
