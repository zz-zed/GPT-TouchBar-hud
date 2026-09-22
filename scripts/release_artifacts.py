#!/usr/bin/env python3
"""Fail-closed build provenance and release helpers. No third-party Python modules."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ARCHES = ("arm64", "x86_64")
WORKFLOW_PATH = ".github/workflows/build-dmg.yml"
SHA_RE = re.compile(r"[0-9a-f]{40}")
HASH_RE = re.compile(r"[0-9a-f]{64}")


class ReleaseError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def sha(value):
    require(isinstance(value, str) and SHA_RE.fullmatch(value), "Expected a full lowercase commit SHA")
    return value


def timestamp(value):
    try:
        result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        require(result.tzinfo is not None, "Timestamp must include a timezone")
        return result
    except (AttributeError, TypeError, ValueError) as error:
        raise ReleaseError("Invalid timestamp") from error


def artifact_name(source_sha, arch, run_id, run_attempt):
    sha(source_sha)
    require(arch in ARCHES, "Unsupported architecture")
    return f"release-{source_sha}-{arch}-{int(run_id)}-{int(run_attempt)}"


def validate_source(event, ref, requested_sha, workflow_sha, is_main_ancestor):
    """workflow_sha here is the event's immutable GITHUB_SHA (before source checkout)."""
    sha(workflow_sha)
    if event == "pull_request":
        require(not requested_sha, "PR builds cannot choose another source")
        return workflow_sha
    require(ref == "refs/heads/main", "Build/recovery must use the main workflow")
    if event == "push":
        require(not requested_sha, "Push builds cannot override their source")
        return workflow_sha
    require(event == "workflow_dispatch", "Untrusted build event")
    target = sha(requested_sha)
    require(is_main_ancestor(target), "Recovery SHA must be an ancestor of origin/main")
    return target


def trusted_match(run, repository, workflow_id, source_sha):
    if (run.get("repository", {}).get("full_name", "").lower() != repository.lower()
            or run.get("head_repository", {}).get("full_name", "").lower() != repository.lower()
            or run.get("workflow_id") != workflow_id
            or run.get("path", "").split("@")[0] != WORKFLOW_PATH
            or run.get("head_branch") != "main"):
        return False
    if run.get("event") == "push":
        return run.get("head_sha") == source_sha
    return (run.get("event") == "workflow_dispatch"
            and run.get("display_title") == f"Build DMG source {source_sha}")


def select_run(runs, repository, workflow_id, source_sha):
    sha(source_sha)
    matching = [run for run in runs if trusted_match(run, repository, workflow_id, source_sha)]
    require(matching, "No trusted main build matches this tag commit; build that exact SHA first")
    # Pick once, BEFORE testing status/artifacts. A bad latest run never falls back to an older one.
    chosen = max(matching, key=lambda run: (timestamp(run["updated_at"]), int(run["id"])))
    require(chosen.get("status") == "completed" and chosen.get("conclusion") == "success",
            "Latest matching run is not successful; retry after a successful full rebuild")
    return chosen


def validate_run(run, jobs, artifacts, repository, workflow_id, source_sha, now=None):
    require(trusted_match(run, repository, workflow_id, sha(source_sha)), "Untrusted workflow run")
    require(run.get("status") == "completed" and run.get("conclusion") == "success", "Run is not successful")
    run_id, attempt = int(run["id"]), int(run["run_attempt"])
    require(run_id > 0 and attempt > 0, "Invalid run identity")
    workflow_sha = sha(run["head_sha"])
    for arch in ARCHES:
        matching_jobs = [job for job in jobs if job.get("name") == f"Build DMG ({arch})"]
        require(len(matching_jobs) == 1, f"Missing or duplicate {arch} job in the selected attempt")
        job = matching_jobs[0]
        require(job.get("run_id") == run_id and job.get("run_attempt", attempt) == attempt
                and job.get("status") == "completed" and job.get("conclusion") == "success",
                f"{arch} job was not successful in this run attempt")
    now = now or dt.datetime.now(dt.timezone.utc)
    selected = {}
    for arch in ARCHES:
        name = artifact_name(source_sha, arch, run_id, attempt)
        found = [artifact for artifact in artifacts if artifact.get("name") == name]
        require(len(found) == 1, f"Missing or duplicate artifact: {name}; rebuild both architectures")
        artifact = found[0]
        require(artifact.get("expired") is False and timestamp(artifact["expires_at"]) > now,
                f"Artifact expired: {name}; dispatch main recovery for the same source SHA")
        origin = artifact.get("workflow_run", {})
        require(origin.get("id") == run_id and origin.get("head_sha") == workflow_sha,
                "Artifact belongs to a different workflow run")
        require(isinstance(artifact.get("id"), int) and artifact["id"] > 0, "Invalid artifact ID")
        selected[arch] = artifact
    return dict(repository=repository, workflow_id=workflow_id, source_sha=source_sha,
                workflow_sha=workflow_sha, run_id=run_id, run_attempt=attempt,
                event=run["event"], artifacts=selected)


def file_record(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), f"Not a regular file: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return {"sha256": digest.hexdigest(), "size": path.stat().st_size}


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ReleaseError(f"Invalid JSON: {path}") from error


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def validate_tag(tag, version):
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", tag) is not None,
            "Invalid release tag")
    require(tag == f"v{version}", "Tag does not match the source version")


def verify_download(directory, selection, version, build, tag):
    validate_tag(tag, version)
    require(isinstance(build, str) and build.isdigit(), "Invalid build number")
    directory = Path(directory)
    manifests = {}
    for arch in ARCHES:
        folder = directory / arch
        require(folder.is_dir() and not folder.is_symlink(), f"Missing architecture directory: {arch}")
        dmg = f"GPT-TouchBar-HUD-{version}-{arch}.dmg"
        require({entry.name for entry in folder.iterdir()} == {dmg, "SHA256SUMS.txt", "manifest.json"},
                f"Unexpected or missing files in {arch} artifact")
        file_record(folder / "manifest.json")
        manifest = read_json(folder / "manifest.json")
        expected = {"schema_version": 1, "repository": selection["repository"],
                    "source_sha": selection["source_sha"], "workflow_sha": selection["workflow_sha"],
                    "run_id": selection["run_id"], "run_attempt": selection["run_attempt"],
                    "event": selection["event"], "ref": "refs/heads/main", "workflow_path": WORKFLOW_PATH,
                    "version": version, "build": build, "architecture": arch}
        for key, value in expected.items():
            require(manifest.get(key) == value, f"{arch} manifest mismatch: {key}")
        require(set(manifest.get("files", {})) == {dmg, "SHA256SUMS.txt"}, "Unexpected manifest files")
        for name in (dmg, "SHA256SUMS.txt"):
            require(file_record(folder / name) == manifest["files"][name], f"Hash/size mismatch: {arch}/{name}")
        checksum = (folder / "SHA256SUMS.txt").read_text(encoding="utf-8")
        require(checksum == f"{manifest['files'][dmg]['sha256']}  {dmg}\n", "Invalid checksum file")
        manifests[arch] = manifest
    return {"source_sha": selection["source_sha"], "version": version, "build": build,
            "tag": tag, "selection": selection, "manifests": manifests}


def release_plan(existing, expected_assets, tag):
    if existing is None:
        return sorted(expected_assets)
    require(existing.get("draft") is True, "Published releases are immutable; refusing all overwrites")
    require(existing.get("tag_name") == tag, "Draft tag mismatch")
    seen = set()
    for asset in existing.get("assets", []):
        name = asset.get("name")
        require(name in expected_assets and name not in seen, "Unexpected or duplicate draft asset")
        seen.add(name)
        require(asset.get("state") == "uploaded" and asset.get("digest") == f"sha256:{expected_assets[name]}",
                f"Conflicting or unverifiable draft asset: {name}; never clobber")
    return sorted(set(expected_assets) - seen)


def git(*args, cwd=None):
    result = subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True)
    require(result.returncode == 0, f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def create_manifest(source, output, arch, repository, run_id, run_attempt, event, ref, workflow_sha):
    source, output = Path(source), Path(output)
    info = plistlib.loads((source / "Resources/Info.plist").read_bytes())
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    source_sha = sha(git("rev-parse", "HEAD", cwd=source))
    sha(workflow_sha)
    name = f"GPT-TouchBar-HUD-{version}-{arch}.dmg"
    require(arch in ARCHES and output.is_dir(), "Invalid output directory or architecture")
    digest = file_record(output / name)
    (output / "SHA256SUMS.txt").write_text(f"{digest['sha256']}  {name}\n", encoding="utf-8")
    result = dict(schema_version=1, repository=repository, source_sha=source_sha, workflow_sha=workflow_sha,
                  version=version, build=build, architecture=arch, run_id=int(run_id), run_attempt=int(run_attempt),
                  event=event, ref=ref, workflow_path=WORKFLOW_PATH,
                  files={name: digest, "SHA256SUMS.txt": file_record(output / "SHA256SUMS.txt")})
    write_json(output / "manifest.json", result)
    return result


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


class GitHub:
    def __init__(self, repository, token):
        require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) is not None, "Invalid repository")
        require(token, "GH_TOKEN is required for GitHub operations")
        self.repository = repository
        self.token = token
        self.prefix = f"/repos/{repository}"

    def request(self, method, path, data=None, binary=False):
        require(path.startswith(self.prefix + "/"), "GitHub API path outside the selected repository")
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "GPTTouchBarHUD-release-verifier"}
        body = None if data is None else json.dumps(data).encode()
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request("https://api.github.com" + path, data=body, headers=headers, method=method)
        try:
            # An API artifact redirect must NEVER forward Authorization to the blob host.
            with urllib.request.build_opener(NoRedirect()).open(request, timeout=60) as response:
                content = response.read()
        except urllib.error.HTTPError as error:
            if binary and error.code in (301, 302, 303, 307, 308):
                location = error.headers.get("Location", "")
                require(urllib.parse.urlsplit(location).scheme == "https", "Unsafe artifact redirect")
                with urllib.request.urlopen(urllib.request.Request(location), timeout=60) as response:
                    content = response.read()  # Fresh request: no GitHub credentials.
            elif error.code == 404:
                return None
            else:
                raise ReleaseError(f"GitHub {method} failed with HTTP {error.code}: {path}") from error
        return content if binary else json.loads(content)

    def pages(self, path, key):
        result = []
        for page in range(1, 1001):
            separator = "&" if "?" in path else "?"
            payload = self.request("GET", f"{path}{separator}per_page=100&page={page}")
            items = payload if key is None else payload.get(key) if isinstance(payload, dict) else None
            require(isinstance(items, list), f"Missing GitHub collection: {key}")
            result.extend(items)
            if len(items) < 100:
                return result
        raise ReleaseError("GitHub pagination exceeded its safety limit")

    def run_inputs(self, run):
        run_id, attempt = int(run["id"]), int(run["run_attempt"])
        jobs = self.pages(f"{self.prefix}/actions/runs/{run_id}/attempts/{attempt}/jobs", "jobs")
        artifacts = self.pages(f"{self.prefix}/actions/runs/{run_id}/artifacts", "artifacts")
        return jobs, artifacts

    def upload(self, release_id, name, path):
        url = f"https://uploads.github.com{self.prefix}/releases/{int(release_id)}/assets?name={urllib.parse.quote(name, safe='')}"
        request = urllib.request.Request(url, data=Path(path).read_bytes(), method="POST", headers={
            "Authorization": f"Bearer {self.token}", "Content-Type": "application/octet-stream",
            "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
        # Uploads are never retried as an overwrite. A later run verifies the existing digest first.
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=120) as response:
            return json.load(response)


def safe_unpack(data, destination, expected_names):
    import io
    destination = Path(destination)
    require(not destination.exists(), "Refusing to overwrite an artifact extraction directory")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        require(len(entries) == len(expected_names) and {item.filename for item in entries} == set(expected_names),
                "Artifact ZIP must contain exactly the expected three root files")
        require(sum(item.file_size for item in entries) <= 2 * 1024 ** 3, "Artifact ZIP is too large")
        for item in entries:
            mode = (item.external_attr >> 16) & 0o170000
            require(not item.is_dir() and mode in (0, 0o100000), "Artifact ZIP contains a symlink or special file")
        destination.mkdir(parents=True)
        for item in entries:
            # No extractall: only whitelisted basename files can be written.
            with archive.open(item) as source, (destination / item.filename).open("xb") as output:
                shutil.copyfileobj(source, output)


def source_metadata(directory):
    directory = Path(directory)
    file_record(directory / "Resources/Info.plist")
    info = plistlib.loads((directory / "Resources/Info.plist").read_bytes())
    return info["CFBundleShortVersionString"], info["CFBundleVersion"]


def prepare_release(api, tag, source_sha, source, output):
    sha(source_sha)
    require(git("rev-parse", "HEAD", cwd=source) == source_sha, "Source checkout is not the immutable tag commit")
    version, build = source_metadata(source)
    validate_tag(tag, version)
    file_record(Path(source) / "RELEASE_NOTES.md")
    output = Path(output)
    require(not output.exists() or not any(output.iterdir()), "Release staging directory must be empty")
    output.mkdir(parents=True, exist_ok=True)
    workflow = api.request("GET", f"{api.prefix}/actions/workflows/build-dmg.yml")
    require(workflow and workflow.get("path") == WORKFLOW_PATH, "Build workflow identity is unavailable")
    workflow_id = workflow["id"]
    endpoint = f"{api.prefix}/actions/workflows/{workflow_id}/runs"
    runs = api.pages(f"{endpoint}?event=push&branch=main&head_sha={source_sha}", "workflow_runs")
    runs += api.pages(f"{endpoint}?event=workflow_dispatch&branch=main", "workflow_runs")
    run = select_run(runs, api.repository, workflow_id, source_sha)
    jobs, artifacts = api.run_inputs(run)
    selection = validate_run(run, jobs, artifacts, api.repository, workflow_id, source_sha)
    for arch, artifact in selection["artifacts"].items():
        data = api.request("GET", f"{api.prefix}/actions/artifacts/{artifact['id']}/zip", binary=True)
        require(data is not None, "Selected artifact vanished; rebuild the same SHA, never use another run")
        if artifact.get("digest") is not None:
            require(artifact["digest"] == "sha256:" + hashlib.sha256(data).hexdigest(), "Artifact archive digest mismatch")
        safe_unpack(data, output / arch, {f"GPT-TouchBar-HUD-{version}-{arch}.dmg", "SHA256SUMS.txt", "manifest.json"})
    report = verify_download(output, selection, version, build, tag)
    write_json(output / "selection.json", selection)
    shutil.copyfile(Path(source) / "RELEASE_NOTES.md", output / "RELEASE_NOTES.md")
    # Deterministic public provenance: recovery from a partially uploaded draft can compare hashes.
    write_json(output / "build-manifest.json", report)
    checksums = []
    for arch in ARCHES:
        name = f"GPT-TouchBar-HUD-{version}-{arch}.dmg"
        shutil.copyfile(output / arch / name, output / name)
        checksums.append(f"{file_record(output / name)['sha256']}  {name}\n")
    (output / "SHA256SUMS.txt").write_text("".join(checksums), encoding="utf-8")
    return report


def verify_remote_tag(api, tag, source_sha):
    """Resolve only the exact tag namespace, including annotated tags, never a branch."""
    reference = api.request("GET", f"{api.prefix}/git/ref/tags/{urllib.parse.quote(tag, safe='')}")
    require(reference and reference.get("ref") == f"refs/tags/{tag}", "Release tag is missing")
    target = reference.get("object", {})
    seen = set()
    for _ in range(8):
        target_sha = sha(target.get("sha"))
        if target.get("type") == "commit":
            require(target_sha == source_sha, "Release tag moved after verification")
            return
        require(target.get("type") == "tag" and target_sha not in seen, "Invalid release tag target")
        seen.add(target_sha)
        annotated = api.request("GET", f"{api.prefix}/git/tags/{target_sha}")
        require(annotated is not None, "Annotated release tag is unavailable")
        target = annotated.get("object", {})
    raise ReleaseError("Release tag nesting exceeded its safety limit")


def find_existing_release(api, tag):
    existing = api.request("GET", f"{api.prefix}/releases/tags/{urllib.parse.quote(tag, safe='')}")
    if existing is not None:
        return existing
    # The tag endpoint is documented for published releases. Authenticated release
    # listings also include drafts, so a 404 is not permission to create another.
    matches = [entry for entry in api.pages(f"{api.prefix}/releases", None) if entry.get("tag_name") == tag]
    require(len(matches) <= 1, "Multiple releases use this tag; manual review required")
    return matches[0] if matches else None


def publish_release(api, directory, tag, source_sha, version, build):
    directory = Path(directory)
    selection = read_json(directory / "selection.json")
    require(selection["source_sha"] == sha(source_sha) and selection["repository"] == api.repository,
            "Staged source/repository mismatch")
    workflow = api.request("GET", f"{api.prefix}/actions/workflows/build-dmg.yml")
    require(workflow and workflow.get("path") == WORKFLOW_PATH and workflow["id"] == selection["workflow_id"],
            "Staged workflow identity changed")
    run = api.request("GET", f"{api.prefix}/actions/runs/{selection['run_id']}")
    require(run is not None, "Selected run is no longer available")
    current = validate_run(run, *api.run_inputs(run), api.repository, workflow["id"], source_sha)
    require(current == selection, "Selected run/attempt/artifact metadata changed; verify again")
    report = verify_download(directory, selection, version, build, tag)
    require(read_json(directory / "build-manifest.json") == report, "Public provenance mismatch")
    verify_remote_tag(api, tag, source_sha)
    content = api.request("GET", f"{api.prefix}/contents/RELEASE_NOTES.md?ref={source_sha}")
    require(content and content.get("encoding") == "base64", "Immutable release notes are unavailable")
    notes = base64.b64decode(content["content"]).decode("utf-8")
    require((directory / "RELEASE_NOTES.md").read_text(encoding="utf-8") == notes, "Notes must come from tag commit")
    names = [f"GPT-TouchBar-HUD-{version}-{arch}.dmg" for arch in ARCHES] + ["SHA256SUMS.txt", "build-manifest.json"]
    for arch in ARCHES:
        name = f"GPT-TouchBar-HUD-{version}-{arch}.dmg"
        require(file_record(directory / name) == report["manifests"][arch]["files"][name], "Public DMG copy mismatch")
    sums = "".join(f"{file_record(directory / name)['sha256']}  {name}\n" for name in names[:2])
    require((directory / "SHA256SUMS.txt").read_text(encoding="utf-8") == sums, "Combined checksum mismatch")
    expected = {name: file_record(directory / name)["sha256"] for name in names}
    existing = find_existing_release(api, tag)
    release_plan(existing, expected, tag)  # Fail before any write if already public or conflicting.
    if existing is None:
        verify_remote_tag(api, tag, source_sha)
        # The existing tag is authoritative. target_commitish is ignored for an
        # existing tag and is not immutable release provenance (it may be "main").
        existing = api.request("POST", f"{api.prefix}/releases", {
            "tag_name": tag, "name": f"GPT TouchBar HUD {tag}",
            "body": notes, "draft": True, "prerelease": False})
    require(existing.get("body") == notes, "Draft notes conflict; manual review required")
    release_id = existing["id"]
    for name in release_plan(existing, expected, tag):
        latest = api.request("GET", f"{api.prefix}/releases/{release_id}")
        missing = release_plan(latest, expected, tag)
        if name in missing:
            api.upload(release_id, name, directory / name)
    latest = api.request("GET", f"{api.prefix}/releases/{release_id}")
    require(not release_plan(latest, expected, tag), "Draft assets incomplete; leaving draft unpublished")
    require(latest.get("body") == notes, "Draft metadata changed during upload")
    verify_remote_tag(api, tag, source_sha)
    return api.request("PATCH", f"{api.prefix}/releases/{release_id}", {"draft": False, "make_latest": "true"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("resolve-source")
    tag_parser = commands.add_parser("resolve-tag")
    tag_parser.add_argument("--tag", required=True)
    tag_parser.add_argument("--github-output")
    create = commands.add_parser("create-manifest")
    for name in ("source", "output", "arch", "repository", "workflow-sha"):
        create.add_argument("--" + name, required=True)
    for name, env in (("run-id", "GITHUB_RUN_ID"), ("run-attempt", "GITHUB_RUN_ATTEMPT"),
                      ("event", "GITHUB_EVENT_NAME"), ("ref", "GITHUB_REF")):
        create.add_argument("--" + name, default=os.environ.get(env), required=env not in os.environ)
    for command in ("prepare-release", "publish-release"):
        child = commands.add_parser(command)
        for name in ("repository", "tag", "source-sha"):
            child.add_argument("--" + name, required=True)
        if command == "prepare-release":
            child.add_argument("--source", required=True)
            child.add_argument("--output", required=True)
        else:
            for name in ("directory", "version", "build"):
                child.add_argument("--" + name, required=True)
    args = parser.parse_args()
    if args.command == "resolve-source":
        def ancestor(commit):
            return subprocess.run(["git", "merge-base", "--is-ancestor", commit, "origin/main"],
                                  capture_output=True).returncode == 0
        print(validate_source(os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"],
                              os.environ.get("SOURCE_SHA_INPUT", ""), os.environ["GITHUB_SHA"], ancestor))
        return
    if args.command == "resolve-tag":
        validate_tag(args.tag, args.tag.removeprefix("v"))
        require(os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
                or os.environ.get("GITHUB_REF") == "refs/heads/main", "Release retry workflow must run from main")
        commit = sha(git("rev-parse", f"refs/tags/{args.tag}^{{commit}}"))
        git("merge-base", "--is-ancestor", commit, "origin/main")
        info = plistlib.loads(git("show", f"{commit}:Resources/Info.plist").encode())
        version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
        validate_tag(args.tag, version)
        result = {"source_sha": commit, "version": version, "build": build, "tag": args.tag,
                  "tools_sha": sha(git("rev-parse", "HEAD"))}
        if args.github_output:
            with open(args.github_output, "a", encoding="utf-8") as output:
                for key, value in result.items():
                    require(isinstance(value, str) and "\n" not in value and "\r" not in value, "Unsafe output value")
                    output.write(f"{key}={value}\n")
    elif args.command == "create-manifest":
        result = create_manifest(args.source, args.output, args.arch, args.repository, args.run_id,
                                 args.run_attempt, args.event, args.ref, args.workflow_sha)
    else:
        api = GitHub(args.repository, os.environ.get("GH_TOKEN"))
        if args.command == "prepare-release":
            result = prepare_release(api, args.tag, args.source_sha, args.source, args.output)
        else:
            result = publish_release(api, args.directory, args.tag, args.source_sha, args.version, args.build)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, KeyError, zipfile.BadZipFile, ValueError) as error:
        print(f"Release verification failed: {error}", file=sys.stderr)
        sys.exit(1)
