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
import time
from urllib.parse import quote

from release_metadata import (ARCHES, ReleaseError, asset_name, file_record, git,
                              require, resolve_tag, sha, source_metadata, tag_reference_commit,
                              validate_tag, write_json)


_content_spec = importlib.util.spec_from_file_location("public_content", Path(__file__).with_name("check-public-content.py"))
public_content = importlib.util.module_from_spec(_content_spec)
_content_spec.loader.exec_module(public_content)


def check_payload(name, data):
    require(not public_content.scan_content(name, data, force_text=True),
            "Publication payload failed the public content check; matched values omitted")


READ_BACKOFF_SECONDS = (0, 1, 2, 4, 8)


def release_identifier(release):
    require(isinstance(release, dict), "Release response is invalid")
    identifier = release.get("id")
    require(type(identifier) is int and identifier > 0, "Release ID is invalid")
    return identifier


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
        if payload is not None and method != "GET":
            check_payload("payload.json", json.dumps(payload).encode())
        args = ["api", "--hostname", "github.com", "--method", method, f"repos/{self.repository}/{path}"]
        if paginate:
            args += ["--paginate", "--slurp"]
        if payload is not None:
            args += ["--input", "-"]
        result = self.command(*args, payload=None if payload is None else json.dumps(payload), missing_ok=missing_ok)
        return None if result is None else json.loads(result)

    def release(self, tag):
        # Like gh release view, resolve draft pending tags through GraphQL.
        # An empty REST tag/list lookup does not establish that a draft is absent.
        owner, name = self.repository.split("/")
        query = """query ReleaseForPublication($owner: String!, $name: String!, $tag: String!) {
          repository(owner: $owner, name: $name) {
            nameWithOwner
            release(tagName: $tag) { databaseId tagName isDraft isPrerelease }
          }
        }"""
        response = json.loads(self.command("api", "--hostname", "github.com", "graphql",
            "-f", f"query={query}", "-f", f"owner={owner}", "-f", f"name={name}", "-f", f"tag={tag}"))
        require(isinstance(response, dict), "Release lookup response is invalid")
        errors = response.get("errors")
        require(errors is None or (isinstance(errors, list) and not errors), "Release lookup returned GraphQL errors")
        data = response.get("data")
        require(isinstance(data, dict), "Release lookup data is missing")
        repository = data.get("repository")
        require(isinstance(repository, dict)
                and isinstance(repository.get("nameWithOwner"), str)
                and repository["nameWithOwner"].casefold() == self.repository.casefold()
                and "release" in repository, "Release lookup repository is unavailable or mismatched")
        release = repository["release"]
        if release is None:
            return None
        require(isinstance(release, dict) and release.get("tagName") == tag
                and type(release.get("isDraft")) is bool and type(release.get("isPrerelease")) is bool,
                "Release lookup identity is invalid")
        result = {"id": release.get("databaseId"), "tag_name": release["tagName"],
                  "draft": release["isDraft"], "prerelease": release["isPrerelease"]}
        release_identifier(result)
        return result

    def by_id(self, identifier):
        release_identifier({"id": identifier})
        return self.api(f"releases/{identifier}", missing_ok=True)

    def source(self, tag):
        reference = self.api(f"git/ref/tags/{tag}")
        require(reference.get("ref") == f"refs/tags/{tag}", "Release tag is missing")
        return tag_reference_commit(reference, lambda value: self.api(f"git/tags/{value}"))

    def create(self, tag, notes, source_sha):
        # Preserve --verify-tag semantics: never create a missing or moved tag.
        require(self.source(tag) == sha(source_sha), "Tag moved before draft creation")
        return self.api("releases", method="POST", payload={
            "tag_name": tag, "target_commitish": source_sha, "name": f"GPT HUD {tag}",
            "body": Path(notes).read_text(encoding="utf-8"), "draft": True, "prerelease": False})

    def upload(self, release, path):
        identifier, path = release_identifier(release), Path(path)
        if path.suffix.lower() in {".json", ".txt", ".md"}:
            check_payload(path.name, path.read_bytes())
        # Use the validated ID on a fixed GitHub host, never a response-provided URL.
        # No overwrite or write retries: uncertain uploads are reconciled on rerun.
        url = (f"https://uploads.github.com/repos/{self.repository}/releases/{identifier}/assets"
               f"?name={quote(path.name, safe='')}")
        self.command("api", "--hostname", "github.com", "--method", "POST", url,
                     "--header", "Content-Type: application/octet-stream",
                     "--header", f"Content-Length: {path.stat().st_size}", "--input", str(path))

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
    release_identifier(release)
    require(release.get("tag_name") == tag and release.get("prerelease") is False, "Release tag or channel conflicts")
    require(type(release.get("draft")) is bool, "Release draft state is missing")
    require(release.get("body") == notes, "Release notes conflict; refusing to overwrite")
    require(isinstance(release.get("assets"), list), "Release assets response is invalid")
    seen = set()
    for asset in release["assets"]:
        require(isinstance(asset, dict), "Release asset response is invalid")
        name = asset.get("name")
        require(name in expected and name not in seen, "Unexpected or duplicate release asset")
        seen.add(name)
        require(asset.get("state") == "uploaded" and asset.get("size") == expected[name]["size"]
                and asset.get("digest") == f"sha256:{expected[name]['sha256']}",
                f"Release asset conflicts: {name}; reset the unpublished draft explicitly, never clobber")
    return sorted(set(expected) - seen)


def read_release(api, identifier, expected, tag, notes, complete=False):
    """Retry read visibility only; identity, content and channel conflicts fail immediately."""
    for delay in READ_BACKOFF_SECONDS:
        if delay:
            time.sleep(delay)
        release = api.by_id(identifier)
        if release is None:
            continue
        require(release_identifier(release) == identifier, "Release ID changed during read-back")
        missing = missing_assets(release, expected, tag, notes)
        if complete and missing:
            require(release["draft"] is True, "Published release is incomplete; refusing all changes")
            continue
        return release
    raise ReleaseError("Release read-back is unavailable or incomplete after bounded retries; "
                       "leaving draft unpublished; retry this publish job")


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
    for name in ("RELEASE_NOTES.md", "SHA256SUMS.txt", "build-manifest.json"):
        check_payload(name, (directory / name).read_bytes())
    release = api.release(tag)
    if release is None:
        release = api.create(tag, directory / "RELEASE_NOTES.md", source_sha)
        missing_assets(release, expected, tag, notes)
        require(release["draft"] is True, "Create response does not confirm a draft")
    identifier = release_identifier(release)
    release = read_release(api, identifier, expected, tag, notes)
    missing = missing_assets(release, expected, tag, notes)
    if release.get("draft") is False:
        require(not missing, "Published release is incomplete; refusing all changes")
        return {"status": "already-published", "url": release.get("html_url")}
    require(release.get("draft") is True, "Release draft state is missing")
    for name in missing:
        api.upload(release, directory / name)
    release = read_release(api, identifier, expected, tag, notes, complete=True)
    require(not missing_assets(release, expected, tag, notes), "Draft is incomplete; leaving it unpublished")
    require(release.get("draft") is True, "Release changed during upload; retry verification")
    require(api.source(tag) == source_sha, "Tag moved during upload; leaving the draft unpublished")
    result = api.api(f"releases/{release['id']}", method="PATCH", payload={"draft": False, "make_latest": "legacy"})
    require(release_identifier(result) == identifier, "Publication response has a different release ID")
    remaining = missing_assets(result, expected, tag, notes)
    require(result.get("draft") is False and not remaining,
            "GitHub response does not confirm a complete public release; retry verification")
    return {"status": "published", "url": result.get("html_url")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("."))
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--tag")
    parser.add_argument("--artifacts", type=Path, default=Path("artifacts"))
    parser.add_argument("--output", type=Path, default=Path("release-stage"))
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--publish", action="store_true")
    modes.add_argument("--prepare-only", action="store_true", help="Default: local verification, no remote writes")
    args = parser.parse_args()
    version, _ = source_metadata(args.source)
    tag = args.tag or f"v{version}"
    validate_tag(tag, version)
    require(git("rev-parse", "HEAD", cwd=args.source) == sha(args.source_sha), "Source checkout does not match the locked SHA")
    if args.publish:
        event, ref = os.environ.get("GITHUB_EVENT_NAME"), os.environ.get("GITHUB_REF")
        require((event == "push" and ref == f"refs/tags/{tag}")
                or (event == "workflow_dispatch" and ref == "refs/heads/main"), "Publication requires a version tag push or a main retry")
        require(resolve_tag(args.source, tag)["source_sha"] == args.source_sha, "Release tag does not match the locked SHA")
    report = prepare(args.source, args.source_sha, args.repository, args.run_id, args.artifacts, args.output, tag)
    if args.publish:
        review = public_content.Review(args.source.resolve())
        try:
            tag_object = public_content.git(args.source, "rev-parse", "refs/tags/" + tag).decode().strip()
            review.history([tag_object], [args.source_sha])
            require(review.report() == 0, "Release source failed the public content check")
        finally:
            review.objects.close()
        print(json.dumps(publish(GitHub(args.repository), report, args.output)))
    else:
        print(json.dumps({"status": "prepared", "directory": str(args.output), "manifest": report}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, public_content.CheckError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"Release preparation/publication failed: {error}", file=sys.stderr)
        sys.exit(1)
