#!/usr/bin/env python3
"""Offline release identity, interrupted upload, and immutable publication tests."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import release_metadata as metadata

SPEC = importlib.util.spec_from_file_location("publish_release", ROOT / "scripts/publish-release.py")
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)

SOURCE = "a" * 40
REPOSITORY = "owner/project"
VERSION, BUILD, TAG, RUN_ID = "0.1.49", "49", "v0.1.49", 123


class MemoryGitHub:
    def __init__(self):
        self.repository = REPOSITORY
        self.current = None
        self.blobs = {}
        self.writes = []
        self.sources = [SOURCE]
        self.lose_upload_response = False
        self.lose_publish_response = False

    def source(self, tag):
        return self.sources.pop(0) if len(self.sources) > 1 else self.sources[0]

    def release(self, tag):
        return self.current

    def create(self, tag, notes):
        self.writes.append("create")
        self.current = {"id": 42, "tag_name": tag, "body": Path(notes).read_text(),
                        "draft": True, "prerelease": False, "assets": [], "html_url": "https://example.test/release"}

    def upload(self, tag, path):
        path = Path(path)
        self.writes.append("upload:" + path.name)
        if path.name in self.blobs:
            raise AssertionError("An existing file must never be overwritten")
        data = path.read_bytes()
        self.blobs[path.name] = data
        self.current["assets"].append({"name": path.name, "state": "uploaded", "size": len(data),
                                       "digest": "sha256:" + hashlib.sha256(data).hexdigest()})
        if self.lose_upload_response:
            self.lose_upload_response = False
            raise metadata.ReleaseError("Upload response lost")

    def api(self, path, method="GET", payload=None):
        assert path == "releases/42" and method == "PATCH"
        assert payload == {"draft": False, "make_latest": "legacy"}
        self.writes.append("publish")
        self.current["draft"] = False
        self.current["published_at"] = "2026-10-26T00:00:00Z"
        if self.lose_publish_response:
            self.lose_publish_response = False
            raise metadata.ReleaseError("Publication response lost")
        return self.current

class ReleasePublishTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="release-publish-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "source"
        (self.source / "Resources").mkdir(parents=True)
        (self.source / "Resources/Info.plist").write_bytes(plistlib.dumps(
            {"CFBundleShortVersionString": VERSION, "CFBundleVersion": BUILD}))
        (self.source / "RELEASE_NOTES.md").write_text("## Changes\n\nA tested release.\n")
        self.artifacts = self.root / "artifacts"
        self.output = self.root / "release-stage"
        for arch in metadata.ARCHES:
            dmg = self.root / metadata.asset_name(VERSION, arch)
            dmg.write_bytes(("DMG fixture " + arch).encode())
            with mock.patch.object(metadata, "git", return_value=SOURCE):
                metadata.create_artifact(self.source, SOURCE, REPOSITORY, RUN_ID, arch, dmg, self.artifacts / arch)

    def prepare(self):
        with mock.patch.object(publisher, "git", return_value=SOURCE):
            return publisher.prepare(self.source, SOURCE, REPOSITORY, RUN_ID, self.artifacts, self.output, TAG)

    def change_manifest(self, arch, key, value):
        path = self.artifacts / arch / "manifest.json"
        data = json.loads(path.read_text())
        data[key] = value
        metadata.write_json(path, data)

    def test_local_preparation_keeps_legacy_download_names_and_checksums(self):
        with mock.patch.object(publisher, "GitHub", side_effect=AssertionError("Local preparation cannot use GitHub")):
            report = self.prepare()
        self.assertEqual(report["source_sha"], SOURCE)
        self.assertEqual(report["schema_version"], 2)
        self.assertEqual(set(report["artifacts"]), set(metadata.ARCHES))
        self.assertNotIn("run_attempt", report)
        self.assertEqual(len(list(self.output.iterdir())), 5)
        self.assertEqual((self.output / "SHA256SUMS.txt").read_text(), "".join(
            f"{record['sha256']}  {record['name']}\n" for record in report["artifacts"].values()))

    def test_successful_artifact_from_earlier_attempt_of_same_run_is_accepted(self):
        self.change_manifest("arm64", "run_attempt", 1)
        self.change_manifest("x86_64", "run_attempt", 2)
        self.assertEqual(self.prepare()["run_id"], RUN_ID)

    def test_wrong_source_run_version_architecture_or_bytes_are_refused(self):
        original = (self.artifacts / "arm64/manifest.json").read_bytes()
        for key, value in (("source_sha", "b" * 40), ("run_id", RUN_ID + 1), ("version", "0.1.48"),
                           ("architecture", "x86_64"), ("repository", "other/project")):
            with self.subTest(key=key):
                (self.artifacts / "arm64/manifest.json").write_bytes(original)
                self.change_manifest("arm64", key, value)
                with self.assertRaisesRegex(metadata.ReleaseError, "manifest mismatch"):
                    self.prepare()
        (self.artifacts / "arm64/manifest.json").write_bytes(original)
        (self.artifacts / "arm64" / metadata.asset_name(VERSION, "arm64")).write_bytes(b"tampered")
        with self.assertRaisesRegex(metadata.ReleaseError, "digest or size mismatch"):
            self.prepare()

    def test_missing_architecture_and_symlink_payload_are_refused(self):
        dmg = self.artifacts / "arm64" / metadata.asset_name(VERSION, "arm64")
        dmg.unlink()
        dmg.symlink_to(self.root / metadata.asset_name(VERSION, "arm64"))
        with self.assertRaisesRegex(metadata.ReleaseError, "regular file"):
            self.prepare()
        (self.artifacts / "x86_64").rename(self.root / "intel")
        with self.assertRaisesRegex(metadata.ReleaseError, "two architecture"):
            self.prepare()

    def test_draft_is_filled_completely_before_publication(self):
        report, api = self.prepare(), MemoryGitHub()
        self.assertEqual(publisher.publish(api, report, self.output)["status"], "published")
        self.assertEqual(api.writes[0], "create")
        self.assertEqual(api.writes[-1], "publish")
        self.assertEqual(len(api.blobs), 4)

    def test_lost_upload_response_resumes_without_overwriting_acknowledged_bytes(self):
        report, api = self.prepare(), MemoryGitHub()
        api.lose_upload_response = True
        with self.assertRaisesRegex(metadata.ReleaseError, "Upload response lost"):
            publisher.publish(api, report, self.output)
        self.assertTrue(api.current["draft"])
        first = next(iter(api.blobs))
        publisher.publish(api, report, self.output)
        self.assertEqual(api.writes.count("upload:" + first), 1)
        self.assertEqual(api.writes.count("create"), 1)

    def test_lost_publication_response_retry_has_no_remote_writes(self):
        report, api = self.prepare(), MemoryGitHub()
        api.lose_publish_response = True
        with self.assertRaisesRegex(metadata.ReleaseError, "Publication response lost"):
            publisher.publish(api, report, self.output)
        before = list(api.writes)
        self.assertEqual(publisher.publish(api, report, self.output)["status"], "already-published")
        self.assertEqual(api.writes, before)

    def test_publication_response_must_confirm_a_complete_public_release(self):
        report, api = self.prepare(), MemoryGitHub()
        for response in ({"draft": True}, {"draft": False, "assets": []}):
            with self.subTest(response=response), mock.patch.object(
                    api, "api", side_effect=lambda *args, **kwargs: {**api.current, **response}):
                with self.assertRaisesRegex(metadata.ReleaseError, "does not confirm a complete public release"):
                    publisher.publish(api, report, self.output)

    def test_conflicting_draft_or_public_asset_is_never_modified(self):
        report, api = self.prepare(), MemoryGitHub()
        api.create(TAG, self.output / "RELEASE_NOTES.md")
        api.upload(TAG, self.output / "SHA256SUMS.txt")
        api.current["assets"][0]["digest"] = "sha256:" + "0" * 64
        for draft in (True, False):
            with self.subTest(draft=draft):
                api.current["draft"] = draft
                before = list(api.writes)
                with self.assertRaisesRegex(metadata.ReleaseError, "asset conflicts"):
                    publisher.publish(api, report, self.output)
                self.assertEqual(api.writes, before)

    def test_notes_conflict_and_moved_tag_prevent_publication(self):
        report, api = self.prepare(), MemoryGitHub()
        api.create(TAG, self.output / "RELEASE_NOTES.md")
        api.current["body"] = "Someone edited this draft"
        with self.assertRaisesRegex(metadata.ReleaseError, "notes conflict"):
            publisher.publish(api, report, self.output)
        self.assertEqual(api.writes, ["create"])
        api.current["body"] = (self.output / "RELEASE_NOTES.md").read_text()
        api.sources = [SOURCE, "b" * 40]
        with self.assertRaisesRegex(metadata.ReleaseError, "Tag moved during upload"):
            publisher.publish(api, report, self.output)
        self.assertTrue(api.current["draft"])
        self.assertNotIn("publish", api.writes)

    def test_modified_prepared_payload_never_reaches_release_creation(self):
        report, api = self.prepare(), MemoryGitHub()
        (self.output / metadata.asset_name(VERSION, "arm64")).write_bytes(b"changed after prepare")
        with self.assertRaisesRegex(metadata.ReleaseError, "Prepared DMG changed"):
            publisher.publish(api, report, self.output)
        self.assertEqual(api.writes, [])

    def test_tag_resolver_locks_existing_main_ancestor_and_matching_version(self):
        def git(*args):
            return subprocess.run(["git", *args], cwd=self.source, check=True, text=True, capture_output=True).stdout.strip()
        git("init", "-b", "main")
        git("config", "user.email", "release-test@example.invalid")
        git("config", "user.name", "Release Tests")
        git("add", ".")
        git("commit", "-m", "release fixture")
        commit = git("rev-parse", "HEAD")
        git("update-ref", "refs/remotes/origin/main", commit)
        git("tag", "-a", TAG, "-m", "fixture")
        self.assertEqual(metadata.resolve_tag(self.source, TAG, commit)["source_sha"], commit)
        git("tag", "-a", "v0.1.51", TAG, "-m", "nested tag")
        with self.assertRaisesRegex(metadata.ReleaseError, "directly to a commit"):
            metadata.resolve_tag(self.source, "v0.1.51")
        nested = {"object": {"type": "tag", "sha": "b" * 40}}
        with self.assertRaisesRegex(metadata.ReleaseError, "point to a commit"):
            metadata.tag_reference_commit(nested, lambda _: nested)
        git("tag", "-d", TAG)
        git("tag", TAG)
        self.assertEqual(metadata.resolve_tag(self.source, TAG, commit)["source_sha"], commit)
        with self.assertRaisesRegex(metadata.ReleaseError, "Tag moved"):
            metadata.resolve_tag(self.source, TAG, "b" * 40)
        git("tag", "v0.1.48")
        with self.assertRaisesRegex(metadata.ReleaseError, "application version"):
            metadata.resolve_tag(self.source, "v0.1.48")
        git("checkout", "--orphan", "unrelated")
        git("commit", "-m", "unrelated source")
        git("tag", "v0.1.50")
        with self.assertRaisesRegex(metadata.ReleaseError, "merge-base"):
            metadata.resolve_tag(self.source, "v0.1.50")


if __name__ == "__main__":
    unittest.main()
