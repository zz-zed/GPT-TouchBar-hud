#!/usr/bin/env python3
"""Offline tampering checks for downloaded public release verification."""

import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("verify_public_release", ROOT / "scripts/verify-public-release.py")
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)

TAG = "v0.1.36"
VERSION = "0.1.36"
SOURCE = "a" * 40
REPOSITORY = "owner/project"


def digest(data):
    return hashlib.sha256(data).hexdigest()


class PublicReleaseVerificationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="public-release-tests-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.assets = []
        manifests = {}
        checksums = []
        for arch in verifier.ARCHES:
            name = f"GPT-TouchBar-HUD-{VERSION}-{arch}.dmg"
            data = ("fixture-" + arch).encode()
            self.add_asset(name, data)
            checksums.append(f"{digest(data)}  {name}\n")
            manifests[arch] = {
                "schema_version": 1, "architecture": arch, "version": VERSION, "build": "39",
                "repository": REPOSITORY, "source_sha": SOURCE, "workflow_sha": SOURCE,
                "run_id": 123, "run_attempt": 1, "event": "push", "ref": "refs/heads/main",
                "workflow_path": verifier.WORKFLOW_PATH,
                "files": {name: {"sha256": digest(data), "size": len(data)}},
            }
        self.add_asset("SHA256SUMS.txt", "".join(checksums).encode())
        manifest = {
            "tag": TAG, "version": VERSION, "build": "39", "source_sha": SOURCE,
            "selection": {"repository": REPOSITORY, "source_sha": SOURCE,
                          "workflow_sha": SOURCE, "run_id": 123, "run_attempt": 1, "event": "push"},
            "manifests": manifests,
        }
        self.manifest = manifest
        self.add_asset("build-manifest.json", json.dumps(manifest).encode())
        self.release = {"assets": self.assets}

    def add_asset(self, name, data):
        (self.directory / name).write_bytes(data)
        self.assets.append({"name": name, "size": len(data), "digest": "sha256:" + digest(data),
                            "state": "uploaded"})

    def test_valid_public_bytes_and_provenance(self):
        manifest, records = verifier.verify_public_files(self.directory, self.release, VERSION, TAG,
                                                         SOURCE, REPOSITORY)
        self.assertEqual(manifest["source_sha"], SOURCE)
        self.assertEqual(len(records), 4)

    def test_rejects_public_dmg_tampering(self):
        (self.directory / f"GPT-TouchBar-HUD-{VERSION}-arm64.dmg").write_bytes(b"tampered")
        with self.assertRaisesRegex(verifier.ReleaseError, "digest mismatch"):
            verifier.verify_public_files(self.directory, self.release, VERSION, TAG, SOURCE, REPOSITORY)

    def test_rejects_manifest_source_even_if_asset_digest_matches(self):
        self.manifest["source_sha"] = "b" * 40
        data = json.dumps(self.manifest).encode()
        (self.directory / "build-manifest.json").write_bytes(data)
        asset = next(entry for entry in self.assets if entry["name"] == "build-manifest.json")
        asset.update(size=len(data), digest="sha256:" + digest(data))
        with self.assertRaisesRegex(verifier.ReleaseError, "source commit mismatch"):
            verifier.verify_public_files(self.directory, self.release, VERSION, TAG, SOURCE, REPOSITORY)

    def test_rejects_draft_or_incomplete_public_release(self):
        release = {"tag_name": TAG, "draft": True, "prerelease": False,
                   "published_at": "2026-09-28T12:42:21Z", "assets": self.assets}
        with self.assertRaisesRegex(verifier.ReleaseError, "public"):
            verifier.validate_release_metadata(release, {"tag_name": TAG}, TAG)
        release["draft"] = False
        release["assets"] = self.assets[:-1]
        with self.assertRaisesRegex(verifier.ReleaseError, "attachments"):
            verifier.validate_release_metadata(release, {"tag_name": TAG}, TAG)


if __name__ == "__main__":
    unittest.main()
