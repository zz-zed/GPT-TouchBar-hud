#!/usr/bin/env python3
"""Check the retained updater wire contract independently of display branding."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
# Independent acceptance values: do not derive these from the display product name.
CONTRACT = {'installedBundleFileName': 'GPT TouchBar HUD.app', 'executableName': 'GPTTouchBarHUD',
            'bundleIdentifier': 'io.github.zz-zed.GPTTouchBarHUD',
            'launchAgentLabel': 'io.github.zz-zed.GPTTouchBarHUD.CodexLauncher',
            'appSupportDirectoryName': 'GPT TouchBar HUD',
            'primaryInstalledBundleFileName': 'GPT HUD.app',
            'installerAssetPrefix': 'GPT-TouchBar-HUD', 'checksumFileName': 'SHA256SUMS.txt',
            'repository': 'zz-zed/GPT-TouchBar-hud'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_source(root):
    identity = (root / 'Sources/AppIdentity.swift').read_text()
    release = (root / 'Sources/AppUpdateModels.swift').read_text()
    values = dict(re.findall(r'static let (\w+) = "([^"\n]*)"', identity + '\n' + release))
    for key, expected in CONTRACT.items():
        require(values.get(key) == expected, f'Updater compatibility contract changed: {key}')
    info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
    require(info['CFBundleName'] == info['CFBundleDisplayName'] == values['productName'], 'Display names disagree')
    require(info['CFBundleIdentifier'] == CONTRACT['bundleIdentifier'], 'Bundle identity changed')
    require(info['CFBundleExecutable'] == CONTRACT['executableName'], 'Executable identity changed')
    require('https://github.com/\\(repository)/releases/latest' in release
            and 'https://api.github.com/repos/\\(repository)/releases/latest' in release, 'Update entry points changed')
    # Shell scripts retain literal wire paths; no extra cross-language configuration is needed.
    require('GPT TouchBar HUD.app' in (root / 'scripts/build-app.sh').read_text(), 'Build app filename changed')
    packaging = (root / 'scripts/package-dmg.sh').read_text()
    require("APP_NAME='GPT TouchBar HUD.app'" in packaging and "PREFIX='GPT-TouchBar-HUD'" in packaging,
            'Compatibility DMG contract changed')
    require("APP_NAME='GPT HUD.app'" in packaging and "PREFIX='GPT-HUD'" in packaging,
            'Primary DMG contract changed')
    return {'displayName': values['productName'], 'version': info['CFBundleShortVersionString'],
            'build': str(info['CFBundleVersion']), 'contract': CONTRACT}


def validate_checksums(text, version, arch, digest):
    compatibility = f"GPT-TouchBar-HUD-{version}-{arch}.dmg"
    names = {f"{prefix}-{version}-{candidate}.dmg" for prefix in ('GPT-HUD', 'GPT-TouchBar-HUD')
             for candidate in ('arm64', 'x86_64')}
    local = {f"{prefix}-{version}-{arch}.dmg" for prefix in ('GPT-HUD', 'GPT-TouchBar-HUD')}
    lines = text.splitlines()
    require(text == ''.join(line + '\n' for line in lines), 'Checksum file must use newline-terminated records')
    records = [re.fullmatch(r'([0-9a-f]{64})  ([^/]+\.dmg)', line) for line in lines]
    require(all(records), 'Malformed checksum record')
    actual = [record[2] for record in records]
    require(len(actual) == len(set(actual)) and set(actual) in ({compatibility}, local, names),
            'Unexpected or duplicate checksum asset set')
    require(lines.count(f'{digest}  {compatibility}') == 1, 'Checksum file does not bind this exact asset')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT)
    parser.add_argument('--dmg', type=Path)
    parser.add_argument('--arch', choices=('arm64', 'x86_64'))
    parser.add_argument('--checksums', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = check_source(args.source)
    if args.dmg:
        require(args.arch is not None and args.checksums is not None, 'DMG checks need --arch and --checksums')
        expected_name = f"{CONTRACT['installerAssetPrefix']}-{report['version']}-{args.arch}.dmg"
        require(args.dmg.name == expected_name, 'DMG asset filename changed')
        digest = hashlib.sha256(args.dmg.read_bytes()).hexdigest()
        validate_checksums(args.checksums.read_text(), report['version'], args.arch, digest)
        spec = importlib.util.spec_from_file_location('package_verify', ROOT / 'scripts/verify-public-release.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        report['package'] = module.verify_dmg(args.dmg, args.arch, report['version'], report['build'],
                                               product_name=report['displayName'])
        require(report['package']['executable'] == CONTRACT['executableName'], 'Package executable changed')
        report['sha256'] = digest
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: retained update names, identity, repository, display consistency' + (' and real DMG/checksums' if args.dmg else ''))


if __name__ == '__main__':
    main()
