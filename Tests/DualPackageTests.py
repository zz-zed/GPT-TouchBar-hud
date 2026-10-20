#!/usr/bin/env python3
"""Dual-package schema and validation workflow trust-boundary tests (offline)."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import release_artifacts as release

spec = importlib.util.spec_from_file_location('public_verifier', ROOT / 'scripts/verify-public-release.py')
public = importlib.util.module_from_spec(spec)
spec.loader.exec_module(public)
VERSION, BUILD, SOURCE = '0.1.46', '49', 'a' * 40
SELECTION = dict(repository='owner/project', source_sha=SOURCE, workflow_sha=SOURCE,
                 run_id=123, run_attempt=1, event='push')


class DualPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = self.directory / 'source'
        (self.source / 'Resources').mkdir(parents=True)
        (self.source / 'scripts').mkdir()
        import plistlib
        (self.source / 'Resources/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': VERSION, 'CFBundleVersion': BUILD}))
        (self.source / 'scripts/package-dmg.sh').write_text('DUAL_PACKAGE_SCHEMA=2')
        self.download = self.directory / 'download'
        self.download.mkdir()
        for arch in release.ARCHES:
            folder = self.download / arch
            folder.mkdir()
            for name in release.package_names(VERSION, arch):
                (folder / name).write_bytes(('inert fixture ' + name).encode())
            with mock.patch.object(release, 'git', return_value=SOURCE):
                release.create_manifest(self.source, folder, arch, SELECTION['repository'], 123, 1,
                                        'push', 'refs/heads/main', SOURCE)

    def verify(self):
        return release.verify_download(self.download, SELECTION, VERSION, BUILD, 'v' + VERSION)

    def rewrite(self, mutate, arch='arm64'):
        path = self.download / arch / 'manifest.json'
        manifest = json.loads(path.read_text())
        mutate(manifest)
        path.write_text(json.dumps(manifest))

    def test_exact_dual_payload_records_and_shared_source(self):
        report = self.verify()
        for arch, item in report['manifests'].items():
            self.assertEqual(item['schema_version'], 2)
            self.assertEqual(set(item['files']), set(release.package_names(VERSION, arch)) | {'SHA256SUMS.txt'})
            for name, kind in release.package_names(VERSION, arch).items():
                self.assertEqual(item['files'][name]['kind'], kind)
                self.assertEqual(item['files'][name]['architecture'], arch)

    def test_rejects_missing_primary_payload(self):
        (self.download / 'arm64' / f'GPT-HUD-{VERSION}-arm64.dmg').unlink()
        with self.assertRaises(release.ReleaseError):
            self.verify()

    def test_rejects_misbound_kind_architecture_and_extra_fields(self):
        path = self.download / 'arm64/manifest.json'
        original = path.read_text()
        for key, value in [('kind', 'compatibility'), ('architecture', 'x86_64'), ('unknown', True)]:
            with self.subTest(key=key):
                path.write_text(original)
                self.rewrite(lambda item: item['files'][f'GPT-HUD-{VERSION}-arm64.dmg'].update({key: value}))
                with self.assertRaises(release.ReleaseError):
                    self.verify()

    def test_rejects_schema_downgrade_and_mixed_architecture_schema(self):
        self.rewrite(lambda item: item.update(schema_version=1))
        with self.assertRaises(release.ReleaseError):
            self.verify()

    def test_source_contract_drives_historical_recovery_schema(self):
        self.assertEqual(release.source_package_schema(self.source), 2)
        (self.source / 'scripts/package-dmg.sh').write_text('original historical packaging')
        self.assertEqual(release.source_package_schema(self.source), 1)
        self.assertEqual(list(release.package_names(VERSION, 'arm64', 1)),
                         [f'GPT-TouchBar-HUD-{VERSION}-arm64.dmg'])

    def public_fixture(self):
        report = self.verify()
        target = self.directory / 'public'
        target.mkdir()
        sums = []
        for arch in release.ARCHES:
            for name in release.package_names(VERSION, arch):
                data = (self.download / arch / name).read_bytes()
                (target / name).write_bytes(data)
                sums.append(f'{hashlib.sha256(data).hexdigest()}  {name}\n')
        (target / 'SHA256SUMS.txt').write_text(''.join(sums))
        (target / 'build-manifest.json').write_text(json.dumps(report))
        assets = [{'name': path.name, 'digest': 'sha256:' + release.file_record(path)['sha256'],
                   'size': path.stat().st_size, 'state': 'uploaded'} for path in target.iterdir()]
        return target, {'assets': assets}, report

    def test_public_four_dmg_contract_and_checksum_provenance(self):
        target, metadata, _ = self.public_fixture()
        manifest, records = public.verify_public_files(target, metadata, VERSION, 'v' + VERSION,
                                                        SOURCE, SELECTION['repository'])
        self.assertEqual(len(records), 6)
        metadata.update(tag_name='v' + VERSION, draft=False, prerelease=False, published_at='2026-10-20')
        self.assertEqual(public.validate_release_metadata(metadata, {'tag_name': 'v' + VERSION}, 'v' + VERSION),
                         (VERSION, True))

    def test_public_rejects_missing_compatibility_asset(self):
        target, metadata, _ = self.public_fixture()
        metadata['assets'] = [item for item in metadata['assets'] if item['name'] != f'GPT-TouchBar-HUD-{VERSION}-arm64.dmg']
        (target / f'GPT-TouchBar-HUD-{VERSION}-arm64.dmg').unlink()
        with self.assertRaises(release.ReleaseError):
            public.verify_public_files(target, metadata, VERSION, 'v' + VERSION, SOURCE, SELECTION['repository'])

    def test_public_rejects_manifest_kind_tampering_with_fresh_github_digest(self):
        target, metadata, report = self.public_fixture()
        report['manifests']['arm64']['files'][f'GPT-HUD-{VERSION}-arm64.dmg']['kind'] = 'compatibility'
        path = target / 'build-manifest.json'
        path.write_text(json.dumps(report))
        asset = next(item for item in metadata['assets'] if item['name'] == path.name)
        asset.update(size=path.stat().st_size, digest='sha256:' + release.file_record(path)['sha256'])
        with self.assertRaises(release.ReleaseError):
            public.verify_public_files(target, metadata, VERSION, 'v' + VERSION, SOURCE, SELECTION['repository'])

    def test_validation_provenance_cannot_pass_release_acceptance(self):
        self.rewrite(lambda item: item.update(workflow_path=release.VALIDATION_WORKFLOW_PATH,
                     ref='refs/heads/validation/gpt-hud-phase2-20261020'))
        with self.assertRaises(release.ReleaseError):
            self.verify()

    def test_validation_workflow_native_integration_and_packages_are_independent(self):
        workflow = (ROOT / '.github/workflows/validate-gpt-hud-phase2.yml').read_text()
        regression, package = workflow.split('\n  regression:\n', 1)[1].split('\n  package:\n', 1)
        self.assertEqual(regression.count('- arch:'), 2)
        self.assertEqual(package.count('- arch:'), 2)
        self.assertEqual(regression.count('suite: migration'), 2)
        for script in ('test-installation-maintenance', 'test-installation-migration',
                       'test-host-auto-launcher', 'test-app-update-progress',
                       'test-migration-process-integration.sh', 'test-launch-entry-integration.sh --run'):
            self.assertIn(script, regression)
        for job in (regression, package):
            self.assertNotIn('needs:', job)
            self.assertIn('test "$(git rev-parse HEAD)" = "$GITHUB_SHA"', job)
            self.assertIn('test "$GITHUB_REF" = refs/heads/validation/gpt-hud-phase2-20261020', job)
        self.assertNotIn('package-dmg.sh', regression)
        self.assertNotIn('ci_regression.py', package)
        self.assertIn('Upload isolated integration evidence', regression)
        self.assertEqual(workflow.count('--label offline-release-policy -- bash scripts/test-release-workflows.sh'), 1)

    def test_validation_workflow_cannot_publish_or_run_other_refs(self):
        workflow = (ROOT / '.github/workflows/validate-gpt-hud-phase2.yml').read_text()
        self.assertIn('branches: [validation/gpt-hud-phase2-20261020]', workflow)
        self.assertIn("github.ref == 'refs/heads/validation/gpt-hud-phase2-20261020'", workflow)
        self.assertIn('contents: read', workflow)
        for forbidden in ('secrets.', 'contents: write', 'release.yml', 'publish-release', 'git push', 'tags:'):
            self.assertNotIn(forbidden, workflow)
        for required in ('verify-dual-packages.py', 'test-earliest-update-contract.py',
                         'test-legacy-update-compatibility.py', 'persist-credentials: false'):
            self.assertIn(required, workflow)


if __name__ == '__main__':
    unittest.main()
