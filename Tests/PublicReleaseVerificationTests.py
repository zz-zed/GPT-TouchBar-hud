#!/usr/bin/env python3
"""Offline tampering checks for downloaded public release verification."""

import hashlib
import base64
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


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

    def test_public_and_publisher_accept_existing_stable_version_tags(self):
        with mock.patch.object(verifier, "github_json", side_effect=[
                {"object": {"type": "tag", "sha": "f" * 40}},
                {"object": {"type": "commit", "sha": SOURCE}}]):
            self.assertEqual(verifier.tag_commit(REPOSITORY, TAG), SOURCE)
        with mock.patch.object(verifier, "github_json", return_value={"object": {"type": "commit", "sha": SOURCE}}):
            self.assertEqual(verifier.tag_commit(REPOSITORY, TAG), SOURCE)
        with self.assertRaisesRegex(verifier.ReleaseError, "stable"):
            verifier.validate_release_metadata({}, {}, "v0.1.43-beta.1")

    def replace_manifest(self, manifest):
        data = json.dumps(manifest).encode()
        (self.directory / "build-manifest.json").write_bytes(data)
        asset = next(entry for entry in self.assets if entry["name"] == "build-manifest.json")
        asset.update(size=len(data), digest="sha256:" + digest(data))

    def test_current_manifest_remains_verifiable_without_actions_history(self):
        manifest = {"schema_version": 2, "tag": TAG, "version": VERSION, "build": "39",
                    "repository": REPOSITORY, "source_sha": SOURCE, "run_id": 123, "artifacts": {}}
        for arch, old in self.manifest["manifests"].items():
            name, record = next(iter(old["files"].items()))
            manifest["artifacts"][arch] = {"name": name, **record}
        self.replace_manifest(manifest)
        with mock.patch.object(verifier, "github_json", side_effect=AssertionError("No CI history lookup")):
            verified, _ = verifier.verify_public_files(self.directory, self.release, VERSION, TAG, SOURCE, REPOSITORY)
        self.assertEqual(verified, manifest)
        manifest["artifacts"]["arm64"]["sha256"] = "0" * 64
        self.replace_manifest(manifest)
        with self.assertRaisesRegex(verifier.ReleaseError, "DMG record mismatch"):
            verifier.verify_public_files(self.directory, self.release, VERSION, TAG, SOURCE, REPOSITORY)

    def test_unknown_manifest_schema_is_rejected(self):
        self.manifest["schema_version"] = 99
        self.replace_manifest(self.manifest)
        with self.assertRaisesRegex(verifier.ReleaseError, "Unsupported"):
            verifier.verify_public_files(self.directory, self.release, VERSION, TAG, SOURCE, REPOSITORY)

    def mapping_document(self):
        from release_source_map import FINGERPRINT_ALGORITHM, PRODUCTION_SCOPE, ENGINEERING_SCOPE
        self.release.update(id=456, tag_name=TAG, draft=False, prerelease=False,
                            published_at="2026-09-28T12:42:21Z", body="release notes")
        for index, asset in enumerate(self.assets):
            asset["id"] = 1001 + index
        proof = {
            "algorithm": FINGERPRINT_ALGORITHM, "old_commit": SOURCE, "new_commit": "b" * 40,
            "old_tag_object": "d" * 40, "new_tag_object": "c" * 40,
            "production": {"scope": copy.deepcopy(PRODUCTION_SCOPE),
                           "old": {"file_count": 10, "sha256": "e" * 64},
                           "new": {"file_count": 10, "sha256": "e" * 64}},
            "protected_engineering": {"scope": copy.deepcopy(ENGINEERING_SCOPE),
                                      "old": {"file_count": 20, "sha256": "f" * 64},
                                      "new": {"file_count": 20, "sha256": "f" * 64}},
        }
        return {"schema_version": 1, "repository": REPOSITORY, "releases": [{
            "tag": TAG, "release_id": 456, "original_tag_object": "d" * 40,
            "original_source_sha": SOURCE, "rewritten_tag_object": "c" * 40,
            "rewritten_source_sha": "b" * 40, "input_proof": proof,
            "assets": [{"id": asset["id"], "name": asset["name"], "size": asset["size"],
                        "sha256": asset["digest"].removeprefix("sha256:")} for asset in self.assets],
        }]}

    def load_mapping(self, document):
        if not hasattr(self, "mapping_path"):
            temporary = tempfile.TemporaryDirectory(prefix="source-map-tests-")
            self.addCleanup(temporary.cleanup)
            self.mapping_path = Path(temporary.name) / "source-map.json"
        self.mapping_path.write_text(json.dumps(document))
        return verifier.load_source_map(self.mapping_path)

    def current_tag(self):
        return {"ref": "refs/tags/" + TAG, "kind": "tag", "object_sha": "c" * 40, "commit_sha": "b" * 40}

    def check_mapping(self, document, *, current_tag=None, release=None):
        return verifier.verify_public_files(self.directory, release or self.release, VERSION, TAG,
                                            "b" * 40, REPOSITORY, source_map=self.load_mapping(document),
                                            current_tag=current_tag or self.current_tag())

    def test_explicit_source_map_verifies_unchanged_schema_one_assets(self):
        for schema in (None, 1):
            with self.subTest(schema=schema):
                if schema is not None:
                    self.manifest["schema_version"] = schema
                    self.replace_manifest(self.manifest)
                original_manifest = (self.directory / "build-manifest.json").read_bytes()
                manifest, records = self.check_mapping(self.mapping_document())
                self.assertEqual(manifest["source_sha"], SOURCE)
                self.assertEqual(manifest["selection"]["source_sha"], SOURCE)
                self.assertEqual(len(records), 4)
                self.assertEqual((self.directory / "build-manifest.json").read_bytes(), original_manifest)

    def test_source_mapping_is_never_implicit(self):
        self.mapping_document()
        with self.assertRaisesRegex(verifier.ReleaseError, "source commit mismatch"):
            verifier.verify_public_files(self.directory, self.release, VERSION, TAG, "b" * 40, REPOSITORY)

    def test_explicit_source_map_verifies_unchanged_schema_two_assets(self):
        manifest = {"schema_version": 2, "tag": TAG, "version": VERSION, "build": "39",
                    "repository": REPOSITORY, "source_sha": SOURCE, "run_id": 123, "artifacts": {}}
        for arch, old in self.manifest["manifests"].items():
            name, record = next(iter(old["files"].items()))
            manifest["artifacts"][arch] = {"name": name, **record}
        self.replace_manifest(manifest)
        with mock.patch.object(verifier, "github_json", side_effect=AssertionError("No CI lookup")):
            result, _ = self.check_mapping(self.mapping_document())
        self.assertEqual(result, manifest)

    def test_mapping_cannot_bypass_unknown_manifest_schema(self):
        self.manifest["schema_version"] = 99
        self.replace_manifest(self.manifest)
        with self.assertRaisesRegex(verifier.ReleaseError, "Unsupported public manifest schema"):
            self.check_mapping(self.mapping_document())

    def test_mapping_binds_repository_release_and_live_tag(self):
        original = self.mapping_document()
        for field, value in [("ref", "refs/tags/v0.1.35"), ("kind", "commit"),
                             ("object_sha", "9" * 40), ("commit_sha", "8" * 40)]:
            current = self.current_tag()
            current[field] = value
            with self.subTest(field=field), self.assertRaises(verifier.ReleaseError):
                self.check_mapping(original, current_tag=current)
        document = copy.deepcopy(original)
        document["repository"] = "another/project"
        with self.assertRaisesRegex(verifier.ReleaseError, "repository mismatch"):
            self.check_mapping(document)
        for field, value in [("id", 457), ("id", True), ("tag_name", "v0.1.35")]:
            release = copy.deepcopy(self.release)
            release[field] = value
            with self.subTest(field=field, value=value), self.assertRaisesRegex(verifier.ReleaseError, "release identity"):
                self.check_mapping(original, release=release)

    def test_mapping_binds_all_original_asset_ids(self):
        document = self.mapping_document()
        for index in range(4):
            release = copy.deepcopy(self.release)
            release["assets"][index]["id"] += 100
            with self.subTest(index=index), self.assertRaisesRegex(verifier.ReleaseError, "asset ID mismatch"):
                self.check_mapping(document, release=release)

    def test_mapping_rejects_changed_bytes_even_with_new_github_digest(self):
        document = self.mapping_document()
        for asset in self.assets:
            path = self.directory / asset["name"]
            original = path.read_bytes()
            original_metadata = copy.deepcopy(asset)
            data = original + b"\n"
            path.write_bytes(data)
            asset.update(size=len(data), digest="sha256:" + digest(data))
            try:
                with self.subTest(name=asset["name"]), self.assertRaisesRegex(verifier.ReleaseError, "original public asset digest"):
                    self.check_mapping(document)
            finally:
                path.write_bytes(original)
                asset.update(original_metadata)

    def test_mapping_still_requires_every_original_manifest_source(self):
        document = self.mapping_document()
        entry = document["releases"][0]
        entry["original_source_sha"] = entry["input_proof"]["old_commit"] = "9" * 40
        with self.assertRaisesRegex(verifier.ReleaseError, "source commit mismatch"):
            self.check_mapping(document)
        self.manifest["manifests"]["arm64"]["source_sha"] = "8" * 40
        self.replace_manifest(self.manifest)
        with self.assertRaisesRegex(verifier.ReleaseError, "provenance mismatch"):
            self.check_mapping(self.mapping_document())

    def test_mapping_requires_identity_bound_equal_input_proofs(self):
        original = self.mapping_document()
        changes = [
            ("missing", lambda proof: proof.pop("production")),
            ("algorithm", lambda proof: proof.update(algorithm="unknown")),
            ("old commit", lambda proof: proof.update(old_commit="1" * 40)),
            ("new commit", lambda proof: proof.update(new_commit="2" * 40)),
            ("old tag", lambda proof: proof.update(old_tag_object="3" * 40)),
            ("new tag", lambda proof: proof.update(new_tag_object="4" * 40)),
            ("scope", lambda proof: proof["production"]["scope"]["prefixes"].pop()),
            ("attribution scope", lambda proof: proof["protected_engineering"]["scope"].pop("attribution_basenames")),
            ("changed hash", lambda proof: proof["production"]["new"].update(sha256="0" * 64)),
            ("changed count", lambda proof: proof["protected_engineering"]["new"].update(file_count=19)),
            ("boolean count", lambda proof: proof["production"]["old"].update(file_count=True)),
        ]
        for name, mutate in changes:
            document = copy.deepcopy(original)
            mutate(document["releases"][0]["input_proof"])
            with self.subTest(name=name), self.assertRaises(verifier.ReleaseError):
                self.load_mapping(document)

    def test_mapping_rejects_unknown_schema_missing_fields_and_duplicate_entries(self):
        original = self.mapping_document()
        changes = [
            ("schema", lambda doc: doc.update(schema_version=2)),
            ("boolean schema", lambda doc: doc.update(schema_version=True)),
            ("extra field", lambda doc: doc.update(allow_any_source=True)),
            ("missing proof", lambda doc: doc["releases"][0].pop("input_proof")),
            ("invalid original tag", lambda doc: doc["releases"][0].update(original_tag_object="bad")),
            ("duplicate entry", lambda doc: doc["releases"].append(copy.deepcopy(doc["releases"][0]))),
            ("missing manifest", lambda doc: doc["releases"][0]["assets"].pop()),
            ("duplicate asset", lambda doc: doc["releases"][0]["assets"].__setitem__(3, copy.deepcopy(doc["releases"][0]["assets"][0]))),
            ("unexpected asset", lambda doc: doc["releases"][0]["assets"][0].update(name="other.dmg")),
        ]
        for name, mutate in changes:
            document = copy.deepcopy(original)
            mutate(document)
            with self.subTest(name=name), self.assertRaises(verifier.ReleaseError):
                self.load_mapping(document)

    def test_mapping_rejects_duplicate_json_keys(self):
        self.load_mapping(self.mapping_document())
        text = self.mapping_path.read_text().replace('"schema_version": 1', '"schema_version": 1, "schema_version": 1')
        self.mapping_path.write_text(text)
        with self.assertRaisesRegex(verifier.ReleaseError, "duplicate JSON keys"):
            verifier.load_source_map(self.mapping_path)

    def test_unsupported_historical_release_is_rejected_before_network_access(self):
        self.load_mapping(self.mapping_document())
        argv = ["verify-public-release.py", "v0.1.32", "--repo", REPOSITORY,
                "--source-map", str(self.mapping_path)]
        with mock.patch.object(sys, "argv", argv), \
                mock.patch.object(verifier, "github_json", side_effect=AssertionError("No remote calls")), \
                self.assertRaisesRegex(verifier.ReleaseError, "does not support this release"):
            verifier.main()

    def test_mapping_report_keeps_original_build_and_cleaned_source_separate(self):
        source_map = self.load_mapping(self.mapping_document())
        responses = [self.release, {"tag_name": TAG},
                     {"ref": "refs/tags/" + TAG, "object": {"type": "tag", "sha": "c" * 40}},
                     {"object": {"type": "commit", "sha": "b" * 40}},
                     {"encoding": "base64", "content": base64.b64encode(b"release notes").decode()}]
        argv = ["verify-public-release.py", TAG, "--repo", REPOSITORY, "--source-map", str(self.mapping_path),
                "--output", str(self.directory), "--reuse-download"]
        with mock.patch.object(sys, "argv", argv), mock.patch.object(verifier, "github_json", side_effect=responses), \
                mock.patch.object(verifier, "command", side_effect=AssertionError("No commands or publication")), \
                mock.patch.object(verifier, "verify_dmg", return_value={"fixture": True}):
            verifier.main()
        report = json.loads((self.directory / "verification.json").read_text())
        self.assertEqual(report["sourceCommit"], SOURCE)
        self.assertEqual(report["cleanedSourceCommit"], "b" * 40)
        self.assertEqual(report["sourceMapping"]["mapSHA256"], source_map["sha256"])
        self.assertEqual(report["sourceMapping"]["originalTagObject"], "d" * 40)


if __name__ == "__main__":
    unittest.main()
