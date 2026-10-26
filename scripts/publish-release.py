#!/usr/bin/env python3
"""Prepare this run's release files; remote publication requires explicit --publish."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from release_metadata import (ARCHES, ReleaseError, asset_name, file_record, git, github_output,
                              require, resolve_tag, sha, source_metadata, tag_reference_commit,
                              validate_tag, write_json)


class GitHub:
    """Use the installed gh CLI for authentication, pagination and transport."""
    def __init__(self, repository):
        require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository), "Invalid repository")
        self.repository = repository

    def command(self, *args, payload=None, missing_ok=False):
        result = subprocess.run(["gh", *args], input=payload, text=True, capture_output=True)
        if missing_ok and result.returncode and "HTTP 404" in result.stderr:
            return None
        require(result.returncode == 0, f"GitHub command failed: {result.stderr.strip()}")
        return result.stdout

    def api(self, path, method="GET", payload=None, missing_ok=False, paginate=False):
        args = ["api", "--method", method, f"repos/{self.repository}/{path}"]
        if paginate:
            args += ["--paginate", "--slurp"]
        if payload is not None:
            args += ["--input", "-"]
        result = self.command(*args, payload=None if payload is None else json.dumps(payload), missing_ok=missing_ok)
        return None if result is None else json.loads(result)

    def release(self, tag):
        release = self.api(f"releases/tags/{tag}", missing_ok=True)
        if release is not None:
            return release
        # Authenticated listings include drafts if the tag lookup does not.
        matches = [entry for page in self.api("releases?per_page=100", paginate=True)
                   for entry in page if entry.get("tag_name") == tag]
        require(len(matches) <= 1, "Multiple releases have the same tag")
        return matches[0] if matches else None

    def source(self, tag):
        reference = self.api(f"git/ref/tags/{tag}")
        require(reference.get("ref") == f"refs/tags/{tag}", "Release tag is missing")
        return tag_reference_commit(reference, lambda value: self.api(f"git/tags/{value}"))

    def create(self, tag, notes):
        self.command("release", "create", tag, "--repo", self.repository, "--draft", "--verify-tag",
                     "--title", f"GPT HUD {tag}", "--notes-file", str(notes))

    def upload(self, tag, path):
        # No --clobber: a concurrent or conflicting upload must fail safely.
        self.command("release", "upload", tag, str(path), "--repo", self.repository)

    def download(self, tag, directory):
        self.command("release", "download", tag, "--repo", self.repository, "--dir", str(directory))


def prepare(source, source_sha, repository, run_id, artifacts, output, tag=None):
    require(git("rev-parse", "HEAD", cwd=source) == sha(source_sha), "Source checkout does not match the locked SHA")
    require(isinstance(run_id, int) and run_id > 0, "Invalid workflow run ID")
    version, build = source_metadata(source)
    tag = tag or f"v{version}"
    validate_tag(tag, version)
    artifacts, output = Path(artifacts), Path(output)
    require(artifacts.is_dir() and not artifacts.is_symlink(), "Artifact directory is missing")
    require({entry.name for entry in artifacts.iterdir()} == set(ARCHES), "Expected exactly two architecture directories")
    files = {}
    for arch in ARCHES:
        folder = artifacts / arch
        name = asset_name(version, arch)
        require(folder.is_dir() and not folder.is_symlink(), f"Invalid architecture directory: {arch}")
        require({entry.name for entry in folder.iterdir()} == {name, "SHA256SUMS.txt", "manifest.json"},
                f"Unexpected or missing architecture files: {arch}")
        file_record(folder / "manifest.json")
        manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
        expected = {"schema_version": 2, "repository": repository, "source_sha": source_sha,
                    "version": version, "build": build, "architecture": arch, "run_id": run_id}
        for key, value in expected.items():
            require(manifest.get(key) == value, f"Architecture manifest mismatch: {arch}/{key}")
        files[arch] = {"name": name, **file_record(folder / name)}
        require(manifest.get("file") == files[arch], f"DMG digest or size mismatch: {arch}")
        file_record(folder / "SHA256SUMS.txt")
        require((folder / "SHA256SUMS.txt").read_text(encoding="utf-8") == f"{files[arch]['sha256']}  {name}\n",
                f"Checksum mismatch: {arch}")
    require(not output.exists() or not any(output.iterdir()), "Release output must be empty")
    output.mkdir(parents=True, exist_ok=True)
    for arch, record in files.items():
        shutil.copyfile(artifacts / arch / record["name"], output / record["name"])
    (output / "SHA256SUMS.txt").write_text("".join(f"{item['sha256']}  {item['name']}\n" for item in files.values()), encoding="utf-8")
    report = {"schema_version": 2, "repository": repository, "source_sha": source_sha,
              "tag": tag, "version": version, "build": build, "run_id": run_id, "artifacts": files}
    write_json(output / "build-manifest.json", report)
    file_record(Path(source) / "RELEASE_NOTES.md")
    shutil.copyfile(Path(source) / "RELEASE_NOTES.md", output / "RELEASE_NOTES.md")
    return report


def missing_assets(release, expected, tag, notes):
    require(isinstance(release, dict), "Release is unavailable; retry verification")
    require(release.get("tag_name") == tag and release.get("prerelease") is False, "Release tag or channel conflicts")
    require(release.get("body") == notes, "Release notes conflict; refusing to overwrite")
    seen = set()
    for asset in release.get("assets", []):
        name = asset.get("name")
        require(name in expected and name not in seen, "Unexpected or duplicate release asset")
        seen.add(name)
        require(asset.get("state") == "uploaded" and asset.get("size") == expected[name]["size"]
                and asset.get("digest") == f"sha256:{expected[name]['sha256']}",
                f"Release asset conflicts: {name}; reset the unpublished draft explicitly, never clobber")
    return sorted(set(expected) - seen)


def publish(api, report, directory):
    directory = Path(directory)
    tag, source_sha = report["tag"], report["source_sha"]
    require(api.source(tag) == source_sha, "Tag moved after source resolution")
    names = [asset_name(report["version"], arch) for arch in ARCHES] + ["SHA256SUMS.txt", "build-manifest.json"]
    expected = {name: file_record(directory / name) for name in names}
    require(json.loads((directory / "build-manifest.json").read_text(encoding="utf-8")) == report,
            "Prepared manifest changed")
    for arch in ARCHES:
        name = asset_name(report["version"], arch)
        require(report["artifacts"][arch] == {"name": name, **expected[name]}, "Prepared DMG changed")
    require((directory / "SHA256SUMS.txt").read_text(encoding="utf-8") == "".join(
        f"{expected[name]['sha256']}  {name}\n" for name in names[:2]), "Prepared checksum file changed")
    notes = (directory / "RELEASE_NOTES.md").read_text(encoding="utf-8")
    release = api.release(tag)
    if release is None:
        api.create(tag, directory / "RELEASE_NOTES.md")
        release = api.release(tag)
        require(release is not None, "Created draft is unavailable; retry this publish job")
    missing = missing_assets(release, expected, tag, notes)
    if release.get("draft") is False:
        require(not missing, "Published release is incomplete; refusing all changes")
        return {"status": "already-published", "url": release.get("html_url")}
    require(release.get("draft") is True, "Release draft state is missing")
    for name in missing:
        api.upload(tag, directory / name)
    release = api.release(tag)
    require(not missing_assets(release, expected, tag, notes), "Draft is incomplete; leaving it unpublished")
    require(release.get("draft") is True, "Release changed during upload; retry verification")
    require(api.source(tag) == source_sha, "Tag moved during upload; leaving the draft unpublished")
    result = api.api(f"releases/{release['id']}", method="PATCH", payload={"draft": False, "make_latest": "legacy"})
    return {"status": "published", "url": result.get("html_url")}


def already_published(api, source, source_sha, tag):
    version, build = source_metadata(source)
    validate_tag(tag, version)
    release = api.release(tag)
    if release is None or release.get("draft") is True:
        return False
    require(api.source(tag) == sha(source_sha), "Published release tag moved")
    require(release.get("body") == (Path(source) / "RELEASE_NOTES.md").read_text(encoding="utf-8"),
            "Published release notes conflict")
    spec = importlib.util.spec_from_file_location("public_release", Path(__file__).with_name("verify-public-release.py"))
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    verifier.validate_release_metadata(release, {"tag_name": tag}, tag)
    with tempfile.TemporaryDirectory(prefix="published-release-") as temporary:
        api.download(tag, temporary)
        manifest, _ = verifier.verify_public_files(Path(temporary), release, version, tag, source_sha, api.repository)
    require(manifest["build"] == build, "Published release build number conflicts")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("."))
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--tag")
    parser.add_argument("--artifacts", type=Path, default=Path("artifacts"))
    parser.add_argument("--output", type=Path, default=Path("release-stage"))
    parser.add_argument("--github-output")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--publish", action="store_true")
    modes.add_argument("--check-published", action="store_true")
    modes.add_argument("--prepare-only", action="store_true", help="Default: local verification, no remote writes")
    args = parser.parse_args()
    version, _ = source_metadata(args.source)
    tag = args.tag or f"v{version}"
    validate_tag(tag, version)
    require(git("rev-parse", "HEAD", cwd=args.source) == sha(args.source_sha), "Source checkout does not match the locked SHA")
    if args.check_published:
        result = already_published(GitHub(args.repository), args.source, args.source_sha, tag)
        github_output(args.github_output, {"already_published": str(result).lower()})
        print(json.dumps({"already_published": result}))
        return
    if args.publish:
        event, ref = os.environ.get("GITHUB_EVENT_NAME"), os.environ.get("GITHUB_REF")
        require((event == "push" and ref == f"refs/tags/{tag}")
                or (event == "workflow_dispatch" and ref == "refs/heads/main"), "Publication requires a version tag push or a main retry")
        require(resolve_tag(args.source, tag)["source_sha"] == args.source_sha, "Release tag does not match the locked SHA")
    report = prepare(args.source, args.source_sha, args.repository, args.run_id, args.artifacts, args.output, tag)
    if args.publish:
        print(json.dumps(publish(GitHub(args.repository), report, args.output)))
    else:
        print(json.dumps({"status": "prepared", "directory": str(args.output), "manifest": report}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"Release preparation/publication failed: {error}", file=sys.stderr)
        sys.exit(1)
