#!/usr/bin/env python3
"""Independently verify a published GPT TouchBar HUD release on macOS.

Requires the GitHub CLI and native macOS tools. This command only reads public
GitHub data and writes downloaded evidence to a new local directory.
"""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

from release_artifacts import ARCHES, WORKFLOW_PATH, ReleaseError, require, sha


REPOSITORY = "zz-zed/GPT-TouchBar-hud"
APP_NAME = "GPT TouchBar HUD.app"
BUNDLE_ID = "io.github.zz-zed.GPTTouchBarHUD"
EXPECTED_MIN_OS = "11.0"


def command(*args):
    try:
        return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", b"") or b""
        raise ReleaseError(f"Command failed: {args[0]} {args[1] if len(args) > 1 else ''}: "
                           + detail.decode("utf-8", "replace").strip()) from error


def github_json(repository, path):
    return json.loads(command("gh", "api", f"repos/{repository}/{path}"))


def file_record(path):
    data = path.read_bytes()
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def tag_commit(repository, tag):
    ref = github_json(repository, f"git/ref/tags/{tag}")
    target = ref.get("object", {})
    require(target.get("type") == "tag", "Release tag must be annotated")
    annotated = github_json(repository, f"git/tags/{sha(target['sha'])}")
    commit = annotated.get("object", {})
    require(commit.get("type") == "commit", "Annotated tag must point to a commit")
    return sha(commit.get("sha"))


def validate_release_metadata(release, latest, tag, allow_not_latest=False):
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag) is not None, "Expected vMAJOR.MINOR.PATCH tag")
    require(release.get("tag_name") == tag, "Release tag mismatch")
    require(release.get("draft") is False and release.get("prerelease") is False,
            "Release must be public and non-prerelease")
    require(release.get("published_at"), "Release publication time is missing")
    is_latest = latest.get("tag_name") == tag
    require(is_latest or allow_not_latest, "Release is not Latest")
    version = tag[1:]
    expected = {f"GPT-TouchBar-HUD-{version}-{arch}.dmg" for arch in ARCHES}
    expected.update({"SHA256SUMS.txt", "build-manifest.json"})
    assets = release.get("assets", [])
    require({entry.get("name") for entry in assets} == expected and len(assets) == len(expected),
            "Public release attachments are missing, duplicate, or unexpected")
    for entry in assets:
        require(entry.get("state") == "uploaded", f"Asset is not uploaded: {entry.get('name')}")
        require(re.fullmatch(r"sha256:[0-9a-f]{64}", entry.get("digest") or "") is not None,
                f"Asset digest is missing: {entry.get('name')}")
        require(isinstance(entry.get("size"), int) and entry["size"] > 0,
                f"Asset size is invalid: {entry.get('name')}")
    return version, is_latest


def verify_public_files(directory, release, version, tag, source_sha, repository):
    assets = {entry["name"]: entry for entry in release["assets"]}
    require({path.name for path in directory.iterdir()} == set(assets), "Downloaded file set differs from release")
    records = {}
    for name, asset in assets.items():
        path = directory / name
        require(path.is_file() and not path.is_symlink(), f"Missing public file: {name}")
        record = file_record(path)
        require(record["bytes"] == asset["size"] and "sha256:" + record["sha256"] == asset["digest"],
                f"Public asset size or GitHub digest mismatch: {name}")
        records[name] = {"name": name, **record}

    manifest = json.loads((directory / "build-manifest.json").read_text(encoding="utf-8"))
    require(manifest.get("tag") == tag and manifest.get("version") == version, "Public manifest version mismatch")
    require(manifest.get("source_sha") == source_sha, "Public manifest source commit mismatch")
    build = manifest.get("build")
    require(isinstance(build, str) and build.isdecimal(), "Public manifest build number is invalid")
    selection = manifest.get("selection", {})
    require(selection.get("repository") == repository and selection.get("source_sha") == source_sha,
            "Public manifest selection source mismatch")
    run_id, attempt = selection.get("run_id"), selection.get("run_attempt")
    require(isinstance(run_id, int) and run_id > 0 and isinstance(attempt, int) and attempt > 0,
            "Public manifest build run is invalid")
    require(selection.get("event") in ("push", "workflow_dispatch"), "Public build event is untrusted")
    workflow_sha = sha(selection.get("workflow_sha"))
    require(set(manifest.get("manifests", {})) == set(ARCHES), "Public manifest architectures mismatch")

    expected_sums = []
    for arch in ARCHES:
        name = f"GPT-TouchBar-HUD-{version}-{arch}.dmg"
        record = records[name]
        expected_sums.append(f"{record['sha256']}  {name}\n")
        item = manifest["manifests"][arch]
        require(item.get("schema_version") == 1 and item.get("architecture") == arch
                and item.get("version") == version and item.get("build") == build
                and item.get("repository") == repository and item.get("source_sha") == source_sha
                and item.get("workflow_sha") == workflow_sha and item.get("run_id") == run_id
                and item.get("run_attempt") == attempt and item.get("event") == selection["event"]
                and item.get("ref") == "refs/heads/main" and item.get("workflow_path") == WORKFLOW_PATH,
                f"Public manifest provenance mismatch: {arch}")
        dmg_entry = item.get("files", {}).get(name, {})
        require(dmg_entry == {"sha256": record["sha256"], "size": record["bytes"]},
                f"Public manifest DMG record mismatch: {arch}")
    require((directory / "SHA256SUMS.txt").read_text(encoding="utf-8") == "".join(expected_sums),
            "Combined public checksums mismatch")
    return manifest, records


def verify_build_run(repository, selection):
    run = github_json(repository, f"actions/runs/{selection['run_id']}/attempts/{selection['run_attempt']}")
    require(run.get("run_attempt") == selection["run_attempt"]
            and run.get("status") == "completed" and run.get("conclusion") == "success"
            and run.get("head_branch") == "main" and run.get("event") == selection["event"]
            and run.get("head_sha") == selection["workflow_sha"],
            "Selected main build is not a successful matching run")
    return run.get("html_url")


def verify_dmg(path, arch, version, build):
    command("hdiutil", "verify", str(path))
    with tempfile.TemporaryDirectory(prefix="hud-public-mount-") as temporary:
        mount = Path(temporary) / "mount"
        mount.mkdir()
        command("hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mount), str(path))
        try:
            disk = plistlib.loads(command("diskutil", "info", "-plist", str(mount)))
            require(disk.get("WritableVolume") is False or disk.get("ReadOnlyVolume") is True,
                    f"DMG is not mounted read-only: {arch}")
            app = mount / APP_NAME
            helper = app / "Contents/Helpers/HookEmitter"
            executable = app / "Contents/MacOS/GPTTouchBarHUD"
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            require(info.get("CFBundleShortVersionString") == version
                    and str(info.get("CFBundleVersion")) == build
                    and info.get("CFBundleIdentifier") == BUNDLE_ID
                    and info.get("LSMinimumSystemVersion") == EXPECTED_MIN_OS,
                    f"Bundle identity or minimum system mismatch: {arch}")
            for binary in (executable, helper):
                require(command("lipo", "-archs", str(binary)).decode().split() == [arch],
                        f"Binary architecture mismatch: {binary.name}")
                output = command("xcrun", "vtool", "-show-build", "-arch", arch, str(binary)).decode()
                require(re.search(r"\bminos\s+11\.0(?:\.0)?\b", output),
                        f"Mach-O minimum system mismatch: {binary.name}")
            command("codesign", "--verify", "--deep", "--strict", str(app))
            command("codesign", "--verify", "--all-architectures", "--strict", str(helper))
            signature = subprocess.run(["codesign", "-dvvv", str(app)], stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, check=True).stderr.decode("utf-8", "replace")
            match = re.search(r"^CDHash=([0-9a-f]{40})$", signature, re.MULTILINE)
            require(match is not None, f"App CDHash is missing: {arch}")
            first_open = mount / "首次打开助手.command"
            require(first_open.is_file() and match.group(1) in first_open.read_text(encoding="utf-8"),
                    f"First-open helper CDHash mismatch: {arch}")
            command("bash", "-n", str(first_open))
            return {"architecture": arch, "cdhash": match.group(1), "readOnlyMount": True,
                    "minimumSystem": EXPECTED_MIN_OS}
        finally:
            command("hdiutil", "detach", str(mount))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="Published version tag, for example v0.1.36")
    parser.add_argument("--repo", default=REPOSITORY, help="GitHub owner/repository")
    parser.add_argument("--output", type=Path, help="New directory for downloaded assets and report")
    parser.add_argument("--reuse-download", action="store_true",
                        help="Recheck an existing download after a failed verification")
    parser.add_argument("--allow-not-latest", action="store_true", help="Verify a historical release")
    parser.add_argument("--allow-notes-edit", action="store_true", help="Allow an authorized online notes correction")
    args = parser.parse_args()
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo) is not None, "Invalid repository")
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", args.tag) is not None,
            "Expected vMAJOR.MINOR.PATCH tag")
    release = github_json(args.repo, f"releases/tags/{args.tag}")
    latest = github_json(args.repo, "releases/latest")
    version, is_latest = validate_release_metadata(release, latest, args.tag, args.allow_not_latest)
    source_sha = tag_commit(args.repo, args.tag)
    notes = github_json(args.repo, f"contents/RELEASE_NOTES.md?ref={source_sha}")
    require(notes.get("encoding") == "base64", "Tagged release notes unavailable")
    tagged_notes = base64.b64decode(notes["content"]).decode("utf-8")
    notes_match = release.get("body") == tagged_notes
    require(notes_match or args.allow_notes_edit, "Public release notes differ from the tagged source")

    output = args.output or Path("build/release-evidence") / f"public-{args.tag}"
    if args.reuse_download:
        require(output.is_dir() and not (output / "verification.json").exists(),
                "Reuse requires an incomplete verification directory")
    else:
        require(not output.exists() or (output.is_dir() and not any(output.iterdir())),
                "Output directory must be new or empty")
        output.mkdir(parents=True, exist_ok=True)
        command("gh", "release", "download", args.tag, "--repo", args.repo, "--dir", str(output))
    manifest, records = verify_public_files(output, release, version, args.tag, source_sha, args.repo)
    run_url = verify_build_run(args.repo, manifest["selection"])
    checks = [verify_dmg(output / f"GPT-TouchBar-HUD-{version}-{arch}.dmg", arch, version,
                         manifest["build"]) for arch in ARCHES]
    report = {
        "tag": args.tag, "version": version, "build": manifest["build"],
        "sourceCommit": source_sha, "releaseURL": release.get("html_url"),
        "publishedAt": release["published_at"], "verifiedAtUTC": datetime.now(timezone.utc).isoformat(),
        "latestVerified": is_latest, "releaseNotesMatch": notes_match,
        "mainCI": {"id": manifest["selection"]["run_id"], "url": run_url, "conclusion": "success"},
        "assets": [records[entry["name"]] for entry in release["assets"]],
        "dmgChecks": checks, "installedAppModifiedDuringVerification": False,
    }
    report_path = output / "verification.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(report_path)


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Release verification failed: {error}") from error
