#!/usr/bin/env python3
"""Digest build inputs, including uncommitted files, without exporting paths or Git metadata."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
files = [root / 'Package.swift', root / 'scripts/build-app.sh', Path(__file__).resolve()]
for folder in ('Sources', 'HookCore', 'ResetNewsCore', 'HookHelper', 'Resources'):
    files += [p for p in (root / folder).rglob('*') if p.is_file() and not p.is_symlink()]
entries = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(files))}
digest = hashlib.sha256(json.dumps(entries, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
if '--digest' in sys.argv:
    print(digest)
else:
    print(json.dumps({'algorithm': 'SHA-256', 'sourceDigest': digest, 'files': entries}, indent=2))
