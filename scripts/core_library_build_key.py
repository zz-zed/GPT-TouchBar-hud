#!/usr/bin/env python3
"""Fingerprint one local optimized core-library build; no cross-run cache."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def build_key(compiler, sdk, helper, sources, flags):
    compiler, sdk = Path(compiler).resolve(), Path(sdk).resolve()
    metadata = [path for path in (sdk / "SDKSettings.json", sdk / "SDKSettings.plist") if path.is_file()]
    if not metadata:
        raise ValueError("Selected SDK has no SDKSettings metadata")
    configuration = {
        "compiler": str(compiler),
        "compilerVersion": subprocess.check_output([str(compiler), "--version"], text=True).strip(),
        "selectedCompiler": subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip(),
        "sdk": str(sdk), "flags": flags, "sources": [str(Path(path).resolve()) for path in sources],
        "environment": {key: os.environ.get(key) for key in
                        ("SDKROOT", "DEVELOPER_DIR", "TOOLCHAINS", "MACOSX_DEPLOYMENT_TARGET")},
    }
    digest = hashlib.sha256(json.dumps(configuration, sort_keys=True).encode())
    for path in [Path(__file__), Path(helper), *metadata, *map(Path, sources)]:
        digest.update(str(path.resolve()).encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def main():
    arguments = sys.argv[1:]
    boundary = arguments.index("--")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True)
    parser.add_argument("--sdk", required=True)
    parser.add_argument("--helper", required=True)
    parser.add_argument("--sources", nargs="+", required=True)
    args = parser.parse_args(arguments[:boundary])
    print(build_key(args.compiler, args.sdk, args.helper, args.sources, arguments[boundary + 1:]))


if __name__ == "__main__":
    main()
