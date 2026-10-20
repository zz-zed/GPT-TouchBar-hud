#!/usr/bin/env python3
"""Keep display-only changes independent of the existing client wire contract."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('contract', ROOT / 'scripts/check-update-compatibility.py')
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


class UpdateCompatibilityContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ['Sources/AppIdentity.swift', 'Sources/AppUpdateModels.swift', 'Resources/Info.plist',
                     'scripts/build-app.sh', 'scripts/package-dmg.sh']:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)

    def test_current_contract(self):
        contract.check_source(self.root)

    def test_display_branding_can_change_without_moving_installation(self):
        path = self.root / 'Sources/AppIdentity.swift'
        path.write_text(path.read_text().replace('productName = "GPT HUD"', 'productName = "Future display name"'))
        path = self.root / 'Resources/Info.plist'
        info = plistlib.loads(path.read_bytes())
        info['CFBundleName'] = info['CFBundleDisplayName'] = 'Future display name'
        path.write_bytes(plistlib.dumps(info))
        contract.check_source(self.root)

    def test_wire_identity_and_asset_changes_fail(self):
        for key in ['installedBundleFileName', 'bundleIdentifier', 'appSupportDirectoryName',
                    'launchAgentLabel', 'executableName', 'primaryInstalledBundleFileName', 'installerAssetPrefix', 'checksumFileName', 'repository']:
            with self.subTest(key=key):
                filename = 'Sources/AppIdentity.swift' if key in ['installedBundleFileName', 'bundleIdentifier',
                           'appSupportDirectoryName', 'launchAgentLabel', 'executableName', 'primaryInstalledBundleFileName'] else 'Sources/AppUpdateModels.swift'
                path = self.root / filename
                original = path.read_text()
                path.write_text(original.replace(f'{key} = "{contract.CONTRACT[key]}"', f'{key} = "changed"'))
                with self.assertRaises(ValueError):
                    contract.check_source(self.root)
                path.write_text(original)

    def test_display_metadata_must_match(self):
        path = self.root / 'Resources/Info.plist'
        info = plistlib.loads(path.read_bytes())
        info['CFBundleDisplayName'] = 'stale display name'
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError):
            contract.check_source(self.root)

    def test_checksum_contract_accepts_single_dual_and_full_exact_sets(self):
        version, digest = '0.1.46', 'a' * 64
        single = [f'GPT-TouchBar-HUD-{version}-arm64.dmg']
        dual = single + [f'GPT-HUD-{version}-arm64.dmg']
        full = dual + [f'GPT-TouchBar-HUD-{version}-x86_64.dmg', f'GPT-HUD-{version}-x86_64.dmg']
        for names in (single, dual, full):
            contract.validate_checksums(''.join(f'{digest}  {name}\n' for name in names), version, 'arm64', digest)
        for names in (dual + dual[:1], full[:-1], single + ['unknown.dmg']):
            with self.subTest(names=names), self.assertRaises(ValueError):
                contract.validate_checksums(''.join(f'{digest}  {name}\n' for name in names), version, 'arm64', digest)
        with self.assertRaises(ValueError):
            contract.validate_checksums(f'{digest}  {single[0]}', version, 'arm64', digest)

    def test_packaged_bundle_cannot_follow_display_name(self):
        path = self.root / 'scripts/package-dmg.sh'
        path.write_text(path.read_text().replace("APP_NAME='GPT TouchBar HUD.app'", "APP_NAME='GPT HUD.app'"))
        with self.assertRaises(ValueError):
            contract.check_source(self.root)


if __name__ == '__main__':
    unittest.main()
