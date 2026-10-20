#!/usr/bin/env python3
"""Inspect both isolated installers without installing or launching either app."""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib

from release_artifacts import ReleaseError, package_names, require

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('package_verify', ROOT / 'scripts/verify-public-release.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def verify_pair(directory, arch, version, build):
    records = [verifier.verify_dmg(directory / name, arch, version, build, product_name='GPT HUD', kind=kind, require_user_target=True)
               for name, kind in package_names(version, arch).items()]
    require(len({record['cdhash'] for record in records}) == 1,
            'Primary and compatibility installers must contain the same signed build')
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--arch', required=True, choices=('arm64', 'x86_64'))
    parser.add_argument('--source', type=Path, default=ROOT)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    info = plistlib.loads((args.source / 'Resources/Info.plist').read_bytes())
    records = verify_pair(args.directory, args.arch, info['CFBundleShortVersionString'], str(info['CFBundleVersion']))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(records, ensure_ascii=False, indent=2) + '\n')
    print('PASS: both single-app installers, signatures, shared CDHash, architecture, deployment target and bound helpers')


if __name__ == '__main__':
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        raise SystemExit(f'Dual-package verification failed: {error}')
