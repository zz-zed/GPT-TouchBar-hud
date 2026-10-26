#!/usr/bin/env python3
"""Small, local release identity and per-architecture artifact helpers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ARCHES = ("arm64", "x86_64")


class ReleaseError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def sha(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value), "Expected a full commit SHA")
    return value


def validate_tag(tag, version):
    require(isinstance(tag, str) and re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag),
            "Expected a stable vMAJOR.MINOR.PATCH tag")
    require(tag == f"v{version}", "Tag does not match the application version")


def git(*args, cwd=None):
    result = subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True)
    require(result.returncode == 0, f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def version_fields(data):
    info = plistlib.loads(data)
    version, build = info["CFBundleShortVersionString"], str(info["CFBundleVersion"])
    validate_tag(f"v{version}", version)
    require(build.isdecimal(), "Invalid application build number")
    return version, build


def source_metadata(source):
    return version_fields((Path(source) / "Resources/Info.plist").read_bytes())


def resolve_tag(source, tag, expected_sha=None):
    validate_tag(tag, tag.removeprefix("v"))
    reference = f"refs/tags/{tag}"
    kind = git("cat-file", "-t", reference, cwd=source)
    require(kind in ("commit", "tag"), "Release tag must point to a commit")
    if kind == "tag":
        header = git("cat-file", "-p", reference, cwd=source).split("\n\n", 1)[0].splitlines()
        require("type commit" in header, "Release tag must point directly to a commit")
    commit = sha(git("rev-parse", "--verify", reference + "^{commit}", cwd=source))
    if expected_sha:
        require(commit == sha(expected_sha), "Tag moved since the triggering push")
    git("merge-base", "--is-ancestor", commit, "origin/main", cwd=source)
    version, build = version_fields(git("show", f"{commit}:Resources/Info.plist", cwd=source).encode())
    validate_tag(tag, version)
    return {"source_sha": commit, "version": version, "build": build, "tag": tag}


def tag_reference_commit(reference, load_tag):
    """Resolve an existing lightweight or directly annotated version tag."""
    require(isinstance(reference, dict), "Release tag is missing")
    target = reference.get("object", {})
    if target.get("type") == "tag":
        target = load_tag(sha(target.get("sha"))).get("object", {})
    require(target.get("type") == "commit", "Release tag must point to a commit")
    return sha(target.get("sha"))


def file_record(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), f"Not a regular file: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"sha256": digest.hexdigest(), "size": path.stat().st_size}


def asset_name(version, arch):
    require(arch in ARCHES, "Unsupported architecture")
    return f"GPT-TouchBar-HUD-{version}-{arch}.dmg"


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def github_output(path, values):
    if path:
        with open(path, "a", encoding="utf-8") as output:
            for key, value in values.items():
                value = str(value)
                require("\n" not in value and "\r" not in value, "Unsafe workflow output")
                output.write(f"{key}={value}\n")


def create_artifact(source, source_sha, repository, run_id, arch, dmg, output):
    require(git("rev-parse", "HEAD", cwd=source) == sha(source_sha), "Source checkout does not match the locked SHA")
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository), "Invalid repository")
    require(isinstance(run_id, int) and run_id > 0, "Invalid workflow run ID")
    version, build = source_metadata(source)
    dmg, output = Path(dmg), Path(output)
    name = asset_name(version, arch)
    require(dmg.name == name, "DMG filename does not match the version and architecture")
    record = file_record(dmg)
    require(record["size"] > 0, "DMG is empty")
    require(not output.exists() or not any(output.iterdir()), "Artifact output must be empty")
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(dmg, output / name)
    (output / "SHA256SUMS.txt").write_text(f"{record['sha256']}  {name}\n", encoding="utf-8")
    manifest = {"schema_version": 2, "repository": repository, "source_sha": source_sha,
                "version": version, "build": build, "architecture": arch, "run_id": run_id,
                "file": {"name": name, **record}}
    write_json(output / "manifest.json", manifest)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    resolve = commands.add_parser("resolve")
    resolve.add_argument("--source", type=Path, default=Path("."))
    resolve.add_argument("--tag", required=True)
    resolve.add_argument("--expected-sha", help="Original push commit; reject a tag moved while queued")
    resolve.add_argument("--github-output")
    create = commands.add_parser("create")
    create.add_argument("--source", type=Path, default=Path("."))
    for name in ("source-sha", "repository", "arch"):
        create.add_argument("--" + name, required=True)
    create.add_argument("--run-id", type=int, required=True)
    create.add_argument("--dmg", type=Path, required=True)
    create.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "resolve":
        expected = args.expected_sha
        if os.environ.get("GITHUB_EVENT_NAME") == "push":
            require(os.environ.get("GITHUB_REF") == f"refs/tags/{args.tag}", "Release push must be its version tag")
            expected = expected or os.environ.get("GITHUB_SHA")
        result = resolve_tag(args.source, args.tag, expected)
        github_output(args.github_output, result)
    else:
        result = create_artifact(args.source, args.source_sha, args.repository, args.run_id,
                                 args.arch, args.dmg, args.output)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f"Release metadata failed: {error}", file=sys.stderr)
        sys.exit(1)
