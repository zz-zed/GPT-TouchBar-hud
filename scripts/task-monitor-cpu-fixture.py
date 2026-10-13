#!/usr/bin/env python3
"""Copy only local task metadata and required logs into a private benchmark fixture.

Source access is read-only. The copy contains private session content and must stay
under ignored build storage; only aggregate results may be committed or shared.
Calling this again with a fixture as source clones the same frozen input.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
from urllib.parse import unquote, urlparse

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
source = args.source.absolute()
destination = args.destination.absolute()
if destination.exists():
    raise SystemExit("Destination must be new; existing files are never replaced")
os.umask(0o077)
destination.mkdir(parents=True, mode=0o700)
checkpoint_name = ".hud-task-state/checkpoint-v1.json"
checkpoint = json.loads((source / checkpoint_name).read_bytes())

def mapped(path):
    original = Path(path)
    try:
        relative = original.relative_to(source)
    except ValueError:
        raise ValueError("Source contains an out-of-home path") from None
    if not relative.parts or relative.parts[0] not in ("sessions", "archived_sessions"):
        raise ValueError("Unexpected task log directory")
    return destination / relative

database = sqlite3.connect((source / "state_5.sqlite").as_uri() + "?mode=ro", uri=True)
rows = database.execute("SELECT id, rollout_path, source, archived, updated_at FROM threads").fetchall()
database.close()
needed = {unquote(urlparse(e["inventory"]["path"]).path) for e in checkpoint["entries"]}
needed.update(row[1] for row in rows if not row[3] and row[2] in ("cli", "exec", "vscode"))
copied = 0
total_bytes = 0
digest = hashlib.sha256()
for path in sorted(needed):
    original = Path(path)
    target = mapped(path)
    digest.update(str(target.relative_to(destination)).encode())
    if not original.exists():
        digest.update(b"missing")
        continue
    if original.is_symlink() or not original.is_file() or not original.resolve().is_relative_to(source.resolve()):
        raise ValueError("Unsafe source log")
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    shutil.copy2(original, target)
    target.chmod(0o600)
    copied += 1
    total_bytes += target.stat().st_size
    with target.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)

out = sqlite3.connect(destination / "state_5.sqlite")
out.execute("CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, source TEXT, archived INT, updated_at INT)")
out.executemany("INSERT INTO threads VALUES(?,?,?,?,?)", [(r[0], str(mapped(r[1])), *r[2:]) for r in rows])
out.commit()
out.close()
for entry in checkpoint["entries"]:
    entry["inventory"]["path"] = mapped(unquote(urlparse(entry["inventory"]["path"]).path)).as_uri()
    if journal := entry.get("journal"):
        target = mapped(journal["path"])
        journal["path"] = str(target)
        if target.exists():
            info = target.stat()
            journal["identity"] = {"device": info.st_dev & 0xffffffff, "inode": info.st_ino}
state = destination / checkpoint_name
state.parent.mkdir(mode=0o700)
state.write_text(json.dumps(checkpoint, separators=(",", ":")))
print(json.dumps({"entries": len(checkpoint["entries"]), "indexed_rows": len(rows),
                  "copied_logs": copied, "copied_bytes": total_bytes,
                  "missing_logs": len(needed) - copied, "log_input_sha256": digest.hexdigest()}))
