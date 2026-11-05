#!/usr/bin/env python3
"""Install per-clone publication hooks without replacing existing hooks/config."""
from pathlib import Path
import subprocess
import sys


def install(root):
    configured = subprocess.run(["git", "config", "--get", "core.hooksPath"], cwd=root, capture_output=True)
    if configured.returncode != 1:
        raise ValueError("Existing hooksPath retained; integrate scripts/git-hooks into that hook manager.")
    hook_dir = Path(subprocess.check_output(["git", "rev-parse", "--git-path", "hooks"], cwd=root, text=True).strip())
    if not hook_dir.is_absolute():
        hook_dir = root / hook_dir
    targets = [(hook_dir / name, root / "scripts/git-hooks" / name) for name in ("pre-commit", "commit-msg", "pre-push")]
    for link, source in targets:
        if (link.exists() or link.is_symlink()) and not (link.is_symlink() and link.resolve() == source.resolve()):
            raise ValueError("Existing hook retained; integrate scripts/git-hooks into that hook manager.")
    hook_dir.mkdir(parents=True, exist_ok=True)
    for link, source in targets:
        if not link.is_symlink():
            link.symlink_to(source)
    print("Publication hooks installed for this clone; existing configuration was preserved.")


if __name__ == "__main__":
    try:
        install(Path(__file__).resolve().parents[1])
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(str(error) if isinstance(error, ValueError) else "Hook installation failed.", file=sys.stderr)
        raise SystemExit(1)
