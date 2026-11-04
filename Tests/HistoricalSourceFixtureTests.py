#!/usr/bin/env python3
"""Historical compatibility tests must use exact sources and fail without them."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from historical_sources import HistoricalSourceError, read_source


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


earliest = load("earliest", "test-earliest-update-contract.py")
legacy = load("legacy", "test-legacy-update-compatibility.py")


class HistoricalSourceFixtureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="historical-source-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name in ("EarliestUpdateCompatibility", "LegacyUpdateCompatibility"):
            shutil.copytree(ROOT / "Tests" / name, self.root / "Tests" / name)
        self.earliest_snapshot = self.root / "Tests/EarliestUpdateCompatibility/snapshot"
        self.legacy_fixture = self.root / "Tests/LegacyUpdateCompatibility"
        self.legacy_snapshot = self.legacy_fixture / "snapshot"
        self.manifest_path = self.legacy_fixture / "manifest.json"
        self.manifest = json.loads(self.manifest_path.read_text())
        self.output_index = 0

    def earliest_source(self):
        with mock.patch.object(earliest, "ROOT", self.root):
            return earliest.historical_model()

    def legacy_sources(self):
        self.output_index += 1
        output = self.root / f"output-{self.output_index}"
        output.mkdir()
        with mock.patch.object(legacy, "FIXTURE", self.legacy_fixture):
            return legacy.extract_sources(output)

    def test_complete_sources_work_without_git_metadata_or_subprocesses(self):
        self.assertFalse((self.root / ".git").exists())
        with mock.patch.object(subprocess, "run", side_effect=AssertionError("No Git or network fallback")), \
                mock.patch.object(subprocess, "check_output", side_effect=AssertionError("No Git or network fallback")):
            data = self.earliest_source()
            manifest, extracted, swift_sources = self.legacy_sources()
        self.assertEqual(hashlib.sha256(data).hexdigest(), earliest.SHA256)
        self.assertEqual(len(swift_sources), 8)
        for path in manifest["files"]:
            self.assertEqual((extracted / path).read_bytes(), (self.legacy_snapshot / path).read_bytes())
        self.assertEqual((extracted / "LICENSE").read_bytes(), (self.legacy_snapshot / "LICENSE").read_bytes())

    def test_missing_earliest_snapshot_never_uses_current_source(self):
        original = self.earliest_snapshot / earliest.SOURCE
        current = self.root / earliest.SOURCE
        current.parent.mkdir(parents=True)
        shutil.copyfile(original, current)
        original.unlink()
        with self.assertRaisesRegex(HistoricalSourceError, "snapshot is missing"):
            self.earliest_source()

    def test_missing_legacy_snapshot_never_uses_current_source(self):
        path = "Resources/install-update.sh"
        current = self.root / path
        current.parent.mkdir(parents=True)
        shutil.copyfile(self.legacy_snapshot / path, current)
        (self.legacy_snapshot / path).unlink()
        with self.assertRaisesRegex(HistoricalSourceError, "snapshot is missing"):
            self.legacy_sources()

    def test_tampering_with_any_source_or_license_fails_before_extraction(self):
        files = [(self.earliest_snapshot / path, self.earliest_source)
                 for path in (earliest.SOURCE, "LICENSE")]
        files += [(self.legacy_snapshot / path, self.legacy_sources)
                  for path in [*self.manifest["files"], "LICENSE"]]
        for path, extract in files:
            with self.subTest(path=str(path.relative_to(self.root))):
                original = path.read_bytes()
                path.write_bytes(original + b"\nchanged fixture\n")
                try:
                    with self.assertRaisesRegex(HistoricalSourceError, "SHA-256 mismatch"):
                        extract()
                finally:
                    path.write_bytes(original)

    def test_original_git_blob_is_required_even_when_sha256_matches(self):
        with self.assertRaisesRegex(HistoricalSourceError, "Git blob mismatch"):
            read_source(self.earliest_snapshot, earliest.SOURCE, earliest.SHA256, "0" * 40)

    def test_both_snapshots_require_the_original_license(self):
        for snapshot, extract in [(self.earliest_snapshot, self.earliest_source),
                                  (self.legacy_snapshot, self.legacy_sources)]:
            with self.subTest(snapshot=snapshot.name):
                (snapshot / "LICENSE").unlink()
                with self.assertRaisesRegex(HistoricalSourceError, "snapshot is missing"):
                    extract()

    def test_source_paths_cannot_escape_the_snapshot(self):
        for path in ["../source.swift", "/source.swift", "Sources/../source.swift", "./source.swift",
                     "Sources//source.swift", "Sources\\source.swift", ""]:
            with self.subTest(path=path), self.assertRaises(HistoricalSourceError):
                read_source(self.earliest_snapshot, path, earliest.SHA256, earliest.BLOB)

    def test_source_and_parent_directory_symlinks_are_rejected(self):
        source = self.earliest_snapshot / earliest.SOURCE
        outside = self.root / "original.swift"
        source.rename(outside)
        source.symlink_to(outside)
        with self.assertRaisesRegex(HistoricalSourceError, "symbolic links"):
            self.earliest_source()
        source.unlink()
        outside.rename(source)
        directory = source.parent
        outside_directory = self.root / "sources"
        directory.rename(outside_directory)
        directory.symlink_to(outside_directory, target_is_directory=True)
        with self.assertRaisesRegex(HistoricalSourceError, "symbolic links"):
            self.earliest_source()

    def test_snapshot_directory_symlink_is_rejected(self):
        outside = self.root / "earliest-snapshot"
        self.earliest_snapshot.rename(outside)
        self.earliest_snapshot.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(HistoricalSourceError, "snapshot directory is unavailable"):
            self.earliest_source()

    def test_legacy_manifest_requires_a_complete_blob_inventory(self):
        self.manifest["blobs"].pop(next(iter(self.manifest["blobs"])))
        self.manifest_path.write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(RuntimeError, "blob inventory mismatch"):
            self.legacy_sources()

    def test_legacy_manifest_rejects_unsupported_source_storage(self):
        self.manifest["sourceStorage"] = "current-checkout"
        self.manifest_path.write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(RuntimeError, "Unsupported historical source storage"):
            self.legacy_sources()


if __name__ == "__main__":
    unittest.main()
