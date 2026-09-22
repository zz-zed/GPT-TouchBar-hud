#!/usr/bin/env python3
"""Offline release trust-boundary regression tests; Python standard library only."""
import copy
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
import warnings
import zipfile
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_artifacts", ROOT / "scripts/release_artifacts.py")
release = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release
SPEC.loader.exec_module(release)

REPOSITORY = "owner/trusted-project"
WORKFLOW_ID = 7301
SOURCE_SHA = "a" * 40
WORKFLOW_SHA = "b" * 40
VERSION = "0.1.32"
BUILD = "35"
TAG = "v" + VERSION
WORKFLOW_PATH = ".github/workflows/build-dmg.yml"
NOW = datetime(2026, 9, 22, 12, tzinfo=timezone.utc)
ARCHES = ("arm64", "x86_64")


def timestamp(value):
    return value.isoformat().replace("+00:00", "Z")


def run_fixture(run_id=200, attempt=1, event="push", source_sha=SOURCE_SHA):
    return {
        "id": run_id, "run_attempt": attempt, "workflow_id": WORKFLOW_ID,
        "path": WORKFLOW_PATH, "head_branch": "main",
        "head_sha": source_sha if event == "push" else WORKFLOW_SHA,
        "event": event, "status": "completed", "conclusion": "success",
        "display_title": "Build DMG source " + source_sha,
        "repository": {"full_name": REPOSITORY},
        "head_repository": {"full_name": REPOSITORY},
        "created_at": timestamp(NOW - timedelta(hours=2) + timedelta(seconds=run_id)),
        "updated_at": timestamp(NOW - timedelta(hours=1) + timedelta(seconds=run_id)),
    }


def jobs_fixture(run):
    return [{"name": "Build DMG (" + arch + ")", "status": "completed",
             "conclusion": "success", "run_id": run["id"], "run_attempt": run["run_attempt"]}
            for arch in ARCHES]


def artifacts_fixture(run, source_sha=SOURCE_SHA):
    return [{"id": index + 901,
             "name": release.artifact_name(source_sha, arch, run["id"], run["run_attempt"]),
             "expired": False, "expires_at": timestamp(NOW + timedelta(days=28)),
             "workflow_run": {"id": run["id"], "head_sha": run["head_sha"]}}
            for index, arch in enumerate(ARCHES)]


def valid_selection(event="push", attempt=1):
    run = run_fixture(event=event, attempt=attempt)
    return release.validate_run(run, jobs_fixture(run), artifacts_fixture(run),
                                REPOSITORY, WORKFLOW_ID, SOURCE_SHA, now=NOW)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_download(directory, selection, version=VERSION, build=BUILD):
    """Write tiny non-executable DMG stand-ins with fully bound manifests."""
    for arch in ARCHES:
        target = directory / arch
        target.mkdir()
        filename = "GPT-TouchBar-HUD-" + version + "-" + arch + ".dmg"
        payload = ("fixture, not an installer: " + arch).encode()
        checksums = (digest(payload) + "  " + filename + "\n").encode()
        (target / filename).write_bytes(payload)
        (target / "SHA256SUMS.txt").write_bytes(checksums)
        manifest = {
            "schema_version": 1, "repository": selection["repository"],
            "source_sha": selection["source_sha"], "workflow_sha": selection["workflow_sha"],
            "version": version, "build": build, "architecture": arch,
            "run_id": selection["run_id"], "run_attempt": selection["run_attempt"],
            "event": selection["event"], "ref": "refs/heads/main", "workflow_path": WORKFLOW_PATH,
            "files": {filename: {"sha256": digest(payload), "size": len(payload)},
                      "SHA256SUMS.txt": {"sha256": digest(checksums), "size": len(checksums)}},
        }
        (target / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")


class OfflineCase(unittest.TestCase):
    def setUp(self):
        # Fail immediately if a supposedly pure validator tries to execute gh or
        # reach a service. Nothing in this suite publishes or downloads assets.
        for target in ("subprocess.run", "subprocess.Popen", "socket.create_connection", "urllib.request.urlopen"):
            blocker = mock.patch(target, side_effect=AssertionError("Offline test attempted external IO: " + target))
            blocker.start()
            self.addCleanup(blocker.stop)


class RunTrustTests(OfflineCase):
    def test_accepts_dual_architecture_trusted_main_push(self):
        selection = valid_selection()
        self.assertEqual(selection["source_sha"], SOURCE_SHA)
        self.assertEqual(selection["workflow_sha"], SOURCE_SHA)
        self.assertEqual(selection["run_id"], 200)
        self.assertEqual(set(selection["artifacts"]), set(ARCHES))

    def test_artifact_identity_binds_source_arch_run_and_attempt(self):
        self.assertEqual(release.artifact_name(SOURCE_SHA, "arm64", 200, 3),
                         "release-" + SOURCE_SHA + "-arm64-200-3")
        self.assertNotEqual(release.artifact_name(SOURCE_SHA, "arm64", 200, 1),
                            release.artifact_name(SOURCE_SHA, "arm64", 200, 2))

    def test_rejects_untrusted_or_incomplete_runs(self):
        changes = {
            "PR": {"event": "pull_request"},
            "pull_request_target": {"event": "pull_request_target"},
            "non-main": {"head_branch": "feature/unsafe"},
            "fork": {"head_repository": {"full_name": "attacker/fork"}},
            "wrong-repository": {"repository": {"full_name": "attacker/project"}},
            "wrong-source-SHA": {"head_sha": "c" * 40},
            "wrong-workflow-id": {"workflow_id": WORKFLOW_ID + 1},
            "wrong-workflow-path": {"path": ".github/workflows/untrusted.yml"},
            "failed-run": {"conclusion": "failure"},
            "in-progress": {"status": "in_progress", "conclusion": None},
            "cancelled": {"conclusion": "cancelled"},
        }
        for name, replacement in changes.items():
            with self.subTest(name=name):
                run = run_fixture()
                run.update(replacement)
                with self.assertRaises(release.ReleaseError):
                    release.validate_run(run, jobs_fixture(run), artifacts_fixture(run),
                                         REPOSITORY, WORKFLOW_ID, SOURCE_SHA, now=NOW)

    def test_push_binds_immutable_head_sha_not_the_display_title(self):
        run = run_fixture()
        run["display_title"] = "A normal push commit message"
        selection = release.validate_run(run, jobs_fixture(run), artifacts_fixture(run),
                                         REPOSITORY, WORKFLOW_ID, SOURCE_SHA, now=NOW)
        self.assertEqual(selection["source_sha"], SOURCE_SHA)

    def test_manual_rejects_source_title_mismatch(self):
        run = run_fixture(event="workflow_dispatch")
        run["display_title"] = "Build DMG source " + "c" * 40
        with self.assertRaises(release.ReleaseError):
            release.validate_run(run, jobs_fixture(run), artifacts_fixture(run),
                                 REPOSITORY, WORKFLOW_ID, SOURCE_SHA, now=NOW)

    def test_rejects_failed_missing_duplicate_or_wrong_attempt_job(self):
        for failure in ("failed", "cancelled", "skipped", "missing", "duplicate", "wrong-run", "wrong-attempt"):
            with self.subTest(failure=failure):
                run = run_fixture(attempt=2)
                jobs = jobs_fixture(run)
                if failure in ("failed", "cancelled", "skipped"):
                    jobs[1]["conclusion"] = "failure" if failure == "failed" else failure
                elif failure == "missing":
                    jobs.pop()
                elif failure == "duplicate":
                    jobs.append(copy.deepcopy(jobs[0]))
                elif failure == "wrong-run":
                    jobs[1]["run_id"] = 999
                else:
                    jobs[1]["run_attempt"] = 1
                with self.assertRaises(release.ReleaseError):
                    release.validate_run(run, jobs, artifacts_fixture(run),
                                         REPOSITORY, WORKFLOW_ID, SOURCE_SHA, now=NOW)

    def test_rejects_missing_duplicate_expired_or_misbound_artifact(self):
        for failure in ("missing", "duplicate", "expired-flag", "expired-date", "wrong-run", "wrong-head-SHA", "wrong-attempt-name"):
            with self.subTest(failure=failure):
                run = run_fixture(attempt=2)
                artifacts = artifacts_fixture(run)
                if failure == "missing":
                    artifacts.pop()
                elif failure == "duplicate":
                    artifacts.append(copy.deepcopy(artifacts[0]))
                elif failure == "expired-flag":
                    artifacts[0]["expired"] = True
                elif failure == "expired-date":
                    artifacts[0]["expires_at"] = timestamp(NOW - timedelta(seconds=1))
                elif failure == "wrong-run":
                    artifacts[0]["workflow_run"]["id"] = 999
                elif failure == "wrong-head-SHA":
                    artifacts[0]["workflow_run"]["head_sha"] = "c" * 40
                else:
                    artifacts[0]["name"] = release.artifact_name(SOURCE_SHA, "arm64", 200, 1)
                with self.assertRaises(release.ReleaseError):
                    release.validate_run(run, jobs_fixture(run), artifacts,
                                         REPOSITORY, WORKFLOW_ID, SOURCE_SHA, now=NOW)

    def test_selects_latest_matching_trusted_run(self):
        older = run_fixture(100)
        older["created_at"] = timestamp(NOW - timedelta(days=1))
        latest = run_fixture(200)
        unrelated = run_fixture(300, source_sha="d" * 40)
        selected = release.select_run([older, unrelated, latest], REPOSITORY, WORKFLOW_ID, SOURCE_SHA)
        self.assertEqual(selected["id"], latest["id"])

    def test_failed_latest_matching_run_does_not_fallback(self):
        older = run_fixture(100)
        latest = run_fixture(200)
        latest["conclusion"] = "failure"
        with self.assertRaises(release.ReleaseError):
            release.select_run([older, latest], REPOSITORY, WORKFLOW_ID, SOURCE_SHA)

    def test_bad_latest_artifact_does_not_fallback_to_older_success(self):
        latest = run_fixture(200)
        selected = release.select_run([run_fixture(100), latest], REPOSITORY, WORKFLOW_ID, SOURCE_SHA)
        self.assertEqual(selected["id"], 200)
        artifacts = artifacts_fixture(selected)
        artifacts[1]["expired"] = True
        with self.assertRaises(release.ReleaseError):
            release.validate_run(selected, jobs_fixture(selected), artifacts,
                                 REPOSITORY, WORKFLOW_ID, SOURCE_SHA, now=NOW)

    def test_no_matching_run_is_a_hard_failure(self):
        with self.assertRaises(release.ReleaseError):
            release.select_run([run_fixture(source_sha="d" * 40)], REPOSITORY, WORKFLOW_ID, SOURCE_SHA)


class SourceRecoveryTests(OfflineCase):
    def test_push_accepts_only_its_own_main_sha(self):
        self.assertEqual(release.validate_source("push", "refs/heads/main", "", SOURCE_SHA,
                                               lambda _: False), SOURCE_SHA)

    def test_manual_accepts_explicit_main_ancestor_without_replacing_workflow_sha(self):
        observed = []
        self.assertEqual(release.validate_source("workflow_dispatch", "refs/heads/main", SOURCE_SHA, WORKFLOW_SHA,
                                               lambda sha: observed.append(sha) or sha == SOURCE_SHA), SOURCE_SHA)
        self.assertEqual(observed, [SOURCE_SHA])
        selection = valid_selection(event="workflow_dispatch")
        self.assertEqual(selection["source_sha"], SOURCE_SHA)
        self.assertEqual(selection["workflow_sha"], WORKFLOW_SHA)

    def test_manual_rejects_nonancestor_nonmain_missing_or_abbreviated_sha(self):
        for ref, requested, ancestor in (("refs/heads/main", SOURCE_SHA, False),
                                         ("refs/heads/feature", SOURCE_SHA, True),
                                         ("refs/tags/v0.1.32", SOURCE_SHA, True),
                                         ("refs/heads/main", "", True),
                                         ("refs/heads/main", "abcd123", True),
                                         ("refs/heads/main", "z" * 40, True)):
            with self.subTest(ref=ref, requested=requested, ancestor=ancestor):
                with self.assertRaises(release.ReleaseError):
                    release.validate_source("workflow_dispatch", ref, requested, WORKFLOW_SHA, lambda _: ancestor)

    def test_pr_and_fork_like_refs_cannot_choose_release_source(self):
        for event, ref in (("pull_request", "refs/pull/1/merge"), ("pull_request_target", "refs/heads/main"),
                           ("push", "refs/heads/feature"), ("push", "refs/tags/v0.1.32")):
            with self.subTest(event=event, ref=ref):
                with self.assertRaises(release.ReleaseError):
                    release.validate_source(event, ref, SOURCE_SHA, WORKFLOW_SHA, lambda _: True)


class DownloadVerificationTests(OfflineCase):
    def setUp(self):
        super().setUp()
        temporary = tempfile.TemporaryDirectory(prefix="release-workflow-tests-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.selection = valid_selection()
        write_download(self.directory, self.selection)

    def verify(self):
        return release.verify_download(self.directory, self.selection, VERSION, BUILD, TAG)

    def change_manifest(self, replacement, arch="arm64"):
        path = self.directory / arch / "manifest.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        manifest.update(replacement)
        path.write_text(json.dumps(manifest), encoding="utf-8")

    def test_accepts_two_bound_architectures_and_verifiable_bytes(self):
        self.assertIsInstance(self.verify(), dict)

    def test_accepts_manual_ancestor_artifacts_with_distinct_workflow_sha(self):
        self.selection = valid_selection(event="workflow_dispatch")
        for arch in ARCHES:
            self.change_manifest({"event": "workflow_dispatch", "workflow_sha": WORKFLOW_SHA}, arch)
        self.assertIsInstance(self.verify(), dict)

    def test_rejects_tag_version_mismatch(self):
        for tag in ("v0.1.31", "0.1.32", "v0.1.32-rc.1"):
            with self.subTest(tag=tag), self.assertRaises(release.ReleaseError):
                release.verify_download(self.directory, self.selection, VERSION, BUILD, tag)

    def test_rejects_dmg_checksum_mismatch(self):
        (self.directory / "arm64" / ("GPT-TouchBar-HUD-" + VERSION + "-arm64.dmg")).write_bytes(b"tampered")
        with self.assertRaises(release.ReleaseError):
            self.verify()

    def test_rejects_checksum_file_mismatch(self):
        (self.directory / "x86_64" / "SHA256SUMS.txt").write_text("0" * 64 + "  wrong.dmg\n", encoding="utf-8")
        with self.assertRaises(release.ReleaseError):
            self.verify()

    def test_checksum_semantics_are_verified_even_when_its_own_hash_matches(self):
        folder = self.directory / "arm64"
        filename = "GPT-TouchBar-HUD-" + VERSION + "-arm64.dmg"
        bad_checksum = ("0" * 64 + "  " + filename + "\n").encode()
        (folder / "SHA256SUMS.txt").write_bytes(bad_checksum)
        manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
        manifest["files"]["SHA256SUMS.txt"] = {"sha256": digest(bad_checksum), "size": len(bad_checksum)}
        (folder / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaises(release.ReleaseError):
            self.verify()

    def test_rejects_manifest_identity_mismatches(self):
        changes = {"schema_version": 2, "repository": "attacker/fork", "source_sha": "c" * 40,
                   "workflow_sha": WORKFLOW_SHA, "version": "0.1.31", "build": "999", "architecture": "x86_64",
                   "run_id": 199, "run_attempt": 2, "event": "pull_request", "ref": "refs/heads/feature",
                   "workflow_path": ".github/workflows/foreign.yml"}
        path = self.directory / "arm64" / "manifest.json"
        original = path.read_text(encoding="utf-8")
        for field, value in changes.items():
            with self.subTest(field=field):
                path.write_text(original, encoding="utf-8")
                self.change_manifest({field: value})
                with self.assertRaises(release.ReleaseError):
                    self.verify()

    def test_rejects_missing_architecture_payload(self):
        (self.directory / "x86_64" / "manifest.json").unlink()
        with self.assertRaises(release.ReleaseError):
            self.verify()

    def test_rejects_undeclared_extra_file(self):
        (self.directory / "arm64" / "unexpected.dmg").write_bytes(b"not selected")
        with self.assertRaises(release.ReleaseError):
            self.verify()

    def test_rejects_symlink_payload_even_when_bytes_are_correct(self):
        folder = self.directory / "arm64"
        name = "GPT-TouchBar-HUD-" + VERSION + "-arm64.dmg"
        outside = self.directory / "same-bytes.dmg"
        (folder / name).rename(outside)
        (folder / name).symlink_to(outside)
        with self.assertRaises(release.ReleaseError):
            self.verify()


class ReleaseMutationGuardTests(OfflineCase):
    def setUp(self):
        super().setUp()
        self.expected = {"GPT-arm64.dmg": "a" * 64, "GPT-x86_64.dmg": "b" * 64, "SHA256SUMS.txt": "c" * 64}

    def existing(self, draft=True, assets=None, tag=TAG):
        return {"tag_name": tag, "draft": draft, "assets": assets or []}

    def asset(self, name, checksum=None):
        return {"name": name, "state": "uploaded", "digest": "sha256:" + (checksum or self.expected[name])}

    def test_new_release_plan_contains_only_expected_assets(self):
        self.assertCountEqual(release.release_plan(None, self.expected, TAG), self.expected)

    def test_public_release_is_never_overwritten_even_if_hashes_match(self):
        for assets in ([], [self.asset(name) for name in self.expected]):
            with self.subTest(assets=bool(assets)), self.assertRaises(release.ReleaseError):
                release.release_plan(self.existing(draft=False, assets=assets), self.expected, TAG)

    def test_valid_draft_resumes_only_missing_assets(self):
        existing = self.existing(assets=[self.asset("GPT-arm64.dmg")])
        self.assertCountEqual(release.release_plan(existing, self.expected, TAG), ["GPT-x86_64.dmg", "SHA256SUMS.txt"])
        self.assertEqual(release.release_plan(self.existing(assets=[self.asset(name) for name in self.expected]), self.expected, TAG), [])

    def test_draft_rejects_duplicate_unknown_incomplete_or_conflicting_assets(self):
        first = self.asset("GPT-arm64.dmg")
        invalid_assets = {
            "duplicate": [first, copy.deepcopy(first)],
            "unexpected": [{"name": "unexpected.dmg", "state": "uploaded", "digest": "sha256:" + "f" * 64}],
            "hash-conflict": [self.asset("GPT-arm64.dmg", "d" * 64)],
            "missing-digest": [{"name": "GPT-arm64.dmg", "state": "uploaded"}],
            "wrong-digest-algorithm": [{"name": "GPT-arm64.dmg", "state": "uploaded", "digest": "md5:" + "a" * 32}],
            "incomplete-upload": [dict(first, state="starter")],
        }
        for name, assets in invalid_assets.items():
            with self.subTest(name=name), self.assertRaises(release.ReleaseError):
                release.release_plan(self.existing(assets=assets), self.expected, TAG)

    def test_draft_tag_conflict_is_not_resumed(self):
        with self.assertRaises(release.ReleaseError):
            release.release_plan(self.existing(tag="v0.1.31"), self.expected, TAG)


class ArchiveSafetyTests(OfflineCase):
    def setUp(self):
        super().setUp()
        temporary = tempfile.TemporaryDirectory(prefix="release-archive-tests-")
        self.addCleanup(temporary.cleanup)
        self.destination = Path(temporary.name) / "extracted"
        self.names = {"installer.dmg", "SHA256SUMS.txt", "manifest.json"}

    def archive(self, entries):
        result = io.BytesIO()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(result, "w") as archive:
                for name, data in entries:
                    archive.writestr(name, data)
        return result.getvalue()

    def test_unpack_accepts_exactly_three_root_regular_files(self):
        release.safe_unpack(self.archive([(name, name.encode()) for name in self.names]), self.destination, self.names)
        self.assertEqual({entry.name for entry in self.destination.iterdir()}, self.names)

    def test_unpack_rejects_traversal_absolute_nested_duplicate_and_extra_entries(self):
        valid = [(name, b"data") for name in sorted(self.names)]
        cases = {
            "traversal": [("../installer.dmg", b"data")] + valid[1:],
            "absolute": [("/tmp/installer.dmg", b"data")] + valid[1:],
            "nested": [("folder/installer.dmg", b"data")] + valid[1:],
            "duplicate": valid + [valid[0]],
            "extra": valid + [("unexpected", b"data")],
            "missing": valid[:2],
        }
        for name, entries in cases.items():
            with self.subTest(name=name), self.assertRaises(release.ReleaseError):
                release.safe_unpack(self.archive(entries), self.destination, self.names)
        self.assertFalse(self.destination.exists())

    def test_unpack_rejects_symlink_and_special_file_modes(self):
        for mode in (0o120777, 0o020666, 0o010666):
            with self.subTest(mode=oct(mode)):
                special = zipfile.ZipInfo("installer.dmg")
                special.create_system = 3
                special.external_attr = mode << 16
                data = self.archive([(special, b"outside"), ("SHA256SUMS.txt", b"sum"), ("manifest.json", b"{}")])
                with self.assertRaises(release.ReleaseError):
                    release.safe_unpack(data, self.destination, self.names)
        self.assertFalse(self.destination.exists())

    def test_unpack_never_overwrites_an_existing_destination(self):
        self.destination.mkdir()
        marker = self.destination / "keep.txt"
        marker.write_text("user data", encoding="utf-8")
        with self.assertRaises(release.ReleaseError):
            release.safe_unpack(self.archive([(name, b"new") for name in self.names]), self.destination, self.names)
        self.assertEqual(marker.read_text(encoding="utf-8"), "user data")

    def test_unpack_rejects_oversized_archive_before_extracting(self):
        entries = [zipfile.ZipInfo(name) for name in self.names]
        entries[0].file_size = 2 * 1024 ** 3 + 1
        fake_archive = mock.MagicMock()
        fake_archive.__enter__.return_value = fake_archive
        fake_archive.infolist.return_value = entries
        with mock.patch.object(release.zipfile, "ZipFile", return_value=fake_archive):
            with self.assertRaises(release.ReleaseError):
                release.safe_unpack(b"fixture", self.destination, self.names)
        fake_archive.open.assert_not_called()
        self.assertFalse(self.destination.exists())


class TransportBoundaryTests(OfflineCase):
    def setUp(self):
        super().setUp()
        self.api = release.GitHub(REPOSITORY, "fixture-token-never-sent")
        self.path = self.api.prefix + "/actions/artifacts/901/zip"

    def redirect(self, location, code=302):
        error = urllib.error.HTTPError("https://api.github.com" + self.path, code, "fixture redirect", {"Location": location}, io.BytesIO())
        self.addCleanup(error.close)
        return error

    def test_binary_https_redirect_uses_fresh_unauthenticated_request(self):
        opener = mock.Mock()
        opener.open.side_effect = self.redirect("https://fixture-blob.example/artifact.zip?sig=example")
        with mock.patch.object(release.urllib.request, "build_opener", return_value=opener) as build_opener:
            with mock.patch.object(release.urllib.request, "urlopen", return_value=io.BytesIO(b"ZIP fixture")) as download:
                self.assertEqual(self.api.request("GET", self.path, binary=True), b"ZIP fixture")
        initial = opener.open.call_args.args[0]
        redirected = download.call_args.args[0]
        self.assertEqual(initial.get_header("Authorization"), "Bearer fixture-token-never-sent")
        self.assertIsNone(redirected.get_header("Authorization"))
        self.assertEqual(redirected.header_items(), [])
        self.assertIsInstance(build_opener.call_args.args[0], release.NoRedirect)

    def test_insecure_redirects_are_rejected_without_download(self):
        for location in ("http://example.test/file", "file:///tmp/fixture", "//example.test/file", ""):
            with self.subTest(location=location):
                opener = mock.Mock()
                opener.open.side_effect = self.redirect(location)
                with mock.patch.object(release.urllib.request, "build_opener", return_value=opener):
                    with mock.patch.object(release.urllib.request, "urlopen") as download:
                        with self.assertRaises(release.ReleaseError):
                            self.api.request("GET", self.path, binary=True)
                        download.assert_not_called()

    def test_api_redirects_and_permission_failures_do_not_become_not_found(self):
        for code in (302, 401, 403, 500):
            with self.subTest(code=code):
                opener = mock.Mock()
                opener.open.side_effect = self.redirect("https://example.test", code)
                with mock.patch.object(release.urllib.request, "build_opener", return_value=opener):
                    with self.assertRaises(release.ReleaseError):
                        self.api.request("GET", self.api.prefix + "/releases/tags/v0.1.32")

    def test_foreign_repository_path_is_rejected_before_transport(self):
        with mock.patch.object(release.urllib.request, "build_opener") as opener:
            with self.assertRaises(release.ReleaseError):
                self.api.request("POST", "/repos/attacker/fork/releases", {"draft": False})
            opener.assert_not_called()

    def test_jobs_are_fetched_from_selected_run_attempt_endpoint(self):
        run = run_fixture(attempt=3)
        with mock.patch.object(self.api, "pages", side_effect=[[], []]) as pages:
            self.api.run_inputs(run)
        self.assertEqual(pages.call_args_list[0].args,
                         (self.api.prefix + "/actions/runs/200/attempts/3/jobs", "jobs"))

    def test_release_listing_paginates_raw_json_arrays(self):
        first = [{"id": number} for number in range(100)]
        last = [{"id": 100}]
        with mock.patch.object(self.api, "request", side_effect=[first, last]) as request:
            self.assertEqual(self.api.pages(self.api.prefix + "/releases", None), first + last)
        self.assertTrue(request.call_args_list[1].args[1].endswith("per_page=100&page=2"))

    def test_redirect_handler_never_forwards_authenticated_request(self):
        request = urllib.request.Request("https://api.github.com", headers={"Authorization": "secret-fixture"})
        self.assertIsNone(release.NoRedirect().redirect_request(request, None, 302, "Found", {}, "https://example.test"))


class MemoryGitHub:
    """Strict GitHub route fake: all reads and writes remain in process memory."""
    repository = REPOSITORY
    prefix = "/repos/" + REPOSITORY

    def __init__(self, run, jobs, artifacts, archives, notes):
        self.run, self.jobs, self.artifacts = run, jobs, artifacts
        self.archives, self.notes = archives, notes
        self.runs = [run]
        self.existing = None
        self.requests = []
        self.writes = []
        self.downloads = []
        self.run_input_ids = []
        self.commit_sha = SOURCE_SHA
        self.tag_exists = True
        self.annotated_tag = False
        self.tag_lookups = 0
        self.draft_visible_by_tag = True
        self.listed_releases = None

    def request(self, method, path, data=None, binary=False):
        self.requests.append((method, path, copy.deepcopy(data)))
        if method in ("POST", "PATCH", "DELETE", "PUT"):
            self.writes.append((method, path, copy.deepcopy(data)))
        if method == "GET" and path == self.prefix + "/actions/workflows/build-dmg.yml":
            return {"id": WORKFLOW_ID, "path": WORKFLOW_PATH}
        if method == "GET" and path == self.prefix + "/actions/runs/200":
            return copy.deepcopy(self.run)
        if method == "GET" and path.startswith(self.prefix + "/actions/artifacts/"):
            self.downloads.append(path)
            artifact_id = int(path.split("/")[-2])
            return self.archives.get(artifact_id)
        if method == "GET" and path == self.prefix + "/git/ref/tags/" + TAG:
            self.tag_lookups += 1
            if not self.tag_exists:
                return None
            target = {"type": "tag", "sha": "f" * 40} if self.annotated_tag else {"type": "commit", "sha": self.commit_sha}
            return {"ref": "refs/tags/" + TAG, "object": target}
        if method == "GET" and path == self.prefix + "/git/tags/" + "f" * 40:
            return {"object": {"type": "commit", "sha": self.commit_sha}}
        if method == "GET" and path == self.prefix + "/contents/RELEASE_NOTES.md?ref=" + SOURCE_SHA:
            return {"encoding": "base64", "content": base64.b64encode(self.notes.encode()).decode()}
        if method == "GET" and path == self.prefix + "/releases/tags/" + TAG:
            if self.existing and self.existing.get("draft") and not self.draft_visible_by_tag:
                return None
            return copy.deepcopy(self.existing)
        if method == "GET" and path == self.prefix + "/releases/7701":
            return copy.deepcopy(self.existing)
        if method == "POST" and path == self.prefix + "/releases":
            self.existing = dict(data, id=7701, assets=[], target_commitish="main")
            return copy.deepcopy(self.existing)
        if method == "PATCH" and path == self.prefix + "/releases/7701":
            self.existing.update(data)
            return copy.deepcopy(self.existing)
        raise AssertionError("Unexpected fake GitHub route: " + method + " " + path)

    def pages(self, path, key):
        if key is None and path == self.prefix + "/releases":
            if self.listed_releases is not None:
                return copy.deepcopy(self.listed_releases)
            return [copy.deepcopy(self.existing)] if self.existing else []
        if key != "workflow_runs":
            raise AssertionError("Unexpected fake collection")
        return copy.deepcopy(self.runs if "event=push" in path else [])

    def run_inputs(self, run):
        self.run_input_ids.append(run["id"])
        return copy.deepcopy(self.jobs), copy.deepcopy(self.artifacts)

    def upload(self, release_id, name, path):
        self.writes.append(("upload", name, release_id))
        asset = {"name": name, "state": "uploaded", "digest": "sha256:" + digest(Path(path).read_bytes())}
        self.existing["assets"].append(asset)
        return copy.deepcopy(asset)


class ReleaseOrchestrationTests(OfflineCase):
    def setUp(self):
        super().setUp()
        temporary = tempfile.TemporaryDirectory(prefix="release-e2e-tests-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.source, self.output = root / "source", root / "stage"
        self.source.mkdir()
        self.notes = "# Immutable tag notes\n\nFixture release only.\n"
        (self.source / "RELEASE_NOTES.md").write_text(self.notes, encoding="utf-8")
        run = run_fixture()
        artifacts = artifacts_fixture(run)
        for artifact in artifacts:
            artifact["expires_at"] = "2099-01-01T00:00:00Z"
        selection = release.validate_run(run, jobs_fixture(run), artifacts, REPOSITORY, WORKFLOW_ID, SOURCE_SHA, now=NOW)
        unpacked = root / "payload"
        unpacked.mkdir()
        write_download(unpacked, selection)
        archives = {}
        for arch, artifact in zip(ARCHES, artifacts):
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                for payload in (unpacked / arch).iterdir():
                    archive.writestr(payload.name, payload.read_bytes())
            archives[artifact["id"]] = buffer.getvalue()
            artifact["digest"] = "sha256:" + digest(buffer.getvalue())
        self.api = MemoryGitHub(run, jobs_fixture(run), artifacts, archives, self.notes)
        git_patch = mock.patch.object(release, "git", return_value=SOURCE_SHA)
        self.git = git_patch.start()
        self.addCleanup(git_patch.stop)
        metadata_patch = mock.patch.object(release, "source_metadata", return_value=(VERSION, BUILD))
        metadata_patch.start()
        self.addCleanup(metadata_patch.stop)

    def prepare(self):
        return release.prepare_release(self.api, TAG, SOURCE_SHA, self.source, self.output)

    def publish(self):
        return release.publish_release(self.api, self.output, TAG, SOURCE_SHA, VERSION, BUILD)

    def test_successful_prepare_and_publish_uses_tag_notes_and_exactly_missing_uploads(self):
        report = self.prepare()
        self.assertEqual(report["source_sha"], SOURCE_SHA)
        self.assertEqual(self.api.writes, [])
        self.assertEqual(len(self.api.downloads), 2)
        self.git.assert_called_once_with("rev-parse", "HEAD", cwd=self.source)
        result = self.publish()
        self.assertFalse(result["draft"])
        self.assertEqual(result["body"], self.notes)
        self.assertEqual(result["target_commitish"], "main")
        self.assertNotIn("target_commitish", self.api.writes[0][2])
        self.assertEqual(self.api.tag_lookups, 3)
        self.assertEqual([call[0] for call in self.api.writes], ["POST", "upload", "upload", "upload", "upload", "PATCH"])
        self.assertTrue(any(path.endswith("RELEASE_NOTES.md?ref=" + SOURCE_SHA) for _, path, _ in self.api.requests))
        self.assertFalse(any("ref=main" in path for _, path, _ in self.api.requests))

    def test_latest_failed_run_never_downloads_or_falls_back(self):
        older = run_fixture(100)
        self.api.runs = [older, dict(self.api.run, conclusion="failure")]
        with self.assertRaises(release.ReleaseError):
            self.prepare()
        self.assertEqual(self.api.run_input_ids, [])
        self.assertEqual(self.api.downloads, [])
        self.assertEqual(self.api.writes, [])

    def test_latest_bad_artifact_never_downloads_from_older_success(self):
        self.api.runs = [run_fixture(100), self.api.run]
        self.api.artifacts[1]["expired"] = True
        with self.assertRaises(release.ReleaseError):
            self.prepare()
        self.assertEqual(self.api.run_input_ids, [200])
        self.assertEqual(self.api.downloads, [])
        self.assertEqual(self.api.writes, [])

    def test_archive_digest_failure_prevents_all_release_mutations(self):
        self.api.archives[901] += b"tampered archive trailer"
        with self.assertRaises(release.ReleaseError):
            self.prepare()
        self.assertEqual(self.api.writes, [])

    def test_source_checkout_mismatch_fails_before_api_access(self):
        self.git.return_value = "d" * 40
        with self.assertRaises(release.ReleaseError):
            self.prepare()
        self.assertEqual(self.api.requests, [])
        self.assertEqual(self.api.writes, [])

    def test_moved_tag_fails_before_any_publish_write(self):
        self.prepare()
        self.api.commit_sha = "c" * 40
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assertEqual(self.api.writes, [])

    def test_annotated_tag_resolves_to_exact_source_commit(self):
        self.prepare()
        self.api.annotated_tag = True
        self.assertFalse(self.publish()["draft"])
        self.assertEqual(self.api.tag_lookups, 3)

    def test_missing_tag_cannot_fall_back_to_same_named_branch_or_create_tag(self):
        self.prepare()
        self.api.tag_exists = False
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assertEqual(self.api.writes, [])

    def test_tag_disappearing_before_create_does_not_create_release(self):
        self.prepare()
        original_request = self.api.request

        def remove_tag_after_release_lookup(method, path, data=None, binary=False):
            result = original_request(method, path, data, binary)
            if path == self.api.prefix + "/releases/tags/" + TAG:
                self.api.tag_exists = False
            return result

        self.api.request = remove_tag_after_release_lookup
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assertEqual(self.api.writes, [])

    def test_tag_moved_during_upload_leaves_draft_unpublished(self):
        self.prepare()
        original_upload = self.api.upload

        def move_tag_after_upload(release_id, name, path):
            result = original_upload(release_id, name, path)
            self.api.commit_sha = "c" * 40
            return result

        self.api.upload = move_tag_after_upload
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assertTrue(self.api.existing["draft"])
        self.assertFalse(any(entry[0] == "PATCH" for entry in self.api.writes))

    def test_tampered_tag_notes_fail_before_any_publish_write(self):
        self.prepare()
        (self.output / "RELEASE_NOTES.md").write_text("Mutable main notes", encoding="utf-8")
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assertEqual(self.api.writes, [])

    def test_revalidated_run_failure_prevents_publish(self):
        self.prepare()
        self.api.run["conclusion"] = "failure"
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assertEqual(self.api.writes, [])

    def test_public_release_or_conflicting_draft_is_not_modified(self):
        self.prepare()
        cases = [dict(draft=False), dict(draft=True, tag_name="v0.1.31"),
                 dict(draft=True, body="Different notes"),
                 dict(draft=True, assets=[{"name": "unexpected", "state": "uploaded", "digest": "sha256:" + "a" * 64}])]
        for replacement in cases:
            with self.subTest(replacement=replacement):
                self.api.existing = dict(id=7701, draft=True, tag_name=TAG, target_commitish=SOURCE_SHA,
                                         body=self.notes, assets=[])
                self.api.existing.update(replacement)
                with self.assertRaises(release.ReleaseError):
                    self.publish()
                self.assertEqual(self.api.writes, [])

    def test_matching_partial_draft_uploads_only_missing_assets_without_overwrite(self):
        self.prepare()
        name = "GPT-TouchBar-HUD-" + VERSION + "-arm64.dmg"
        self.api.existing = dict(id=7701, draft=True, tag_name=TAG, target_commitish="main", body=self.notes,
                                 assets=[{"name": name, "state": "uploaded", "digest": "sha256:" + digest((self.output / name).read_bytes())}])
        result = self.publish()
        self.assertFalse(result["draft"])
        self.assertEqual([entry[0] for entry in self.api.writes], ["upload", "upload", "upload", "PATCH"])
        self.assertNotIn(name, [entry[1] for entry in self.api.writes if entry[0] == "upload"])

    def test_draft_missing_from_tag_endpoint_resumes_through_release_listing(self):
        self.prepare()
        self.api.existing = dict(id=7701, draft=True, tag_name=TAG, target_commitish="main", body=self.notes, assets=[])
        self.api.draft_visible_by_tag = False
        self.assertFalse(self.publish()["draft"])
        self.assertFalse(any(entry[0] == "POST" for entry in self.api.writes))

    def test_duplicate_listed_drafts_fail_before_any_mutation(self):
        self.prepare()
        self.api.listed_releases = [dict(id=7701, draft=True, tag_name=TAG), dict(id=7702, draft=True, tag_name=TAG)]
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assertEqual(self.api.writes, [])

    def test_published_release_found_only_by_listing_is_never_overwritten(self):
        self.prepare()
        self.api.listed_releases = [dict(id=7701, draft=False, tag_name=TAG)]
        with self.assertRaises(release.ReleaseError):
            self.publish()
        self.assertEqual(self.api.writes, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
