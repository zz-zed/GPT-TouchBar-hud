#!/usr/bin/env python3
"""Fingerprint the complete inputs of a job-local UI test module build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys


def fingerprint(configuration, paths):
    digest = hashlib.sha256(json.dumps(configuration, sort_keys=True).encode())
    for path in sorted(map(Path, paths)):
        digest.update(str(path).encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def main():
    arguments = sys.argv[1:]
    boundary = arguments.index("--")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True)
    parser.add_argument("--dependency", action="append", default=[])
    parser.add_argument("--sources", nargs="+", required=True)
    args = parser.parse_args(arguments[:boundary])
    flags = arguments[boundary + 1:]
    output = lambda *cmd: subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT).strip()
    configuration = {
        "architecture": platform.machine(), "compiler": args.compiler,
        "compilerVersion": output(args.compiler, "--version"),
        "selectedCompiler": output("xcrun", "--find", "swiftc"),
        "sdkVersion": output("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "flags": flags,
        "sourceOrder": args.sources, "dependencyOrder": args.dependency,
        "environment": {key: os.environ.get(key) for key in
                        ("SDKROOT", "DEVELOPER_DIR", "TOOLCHAINS", "MACOSX_DEPLOYMENT_TARGET")},
    }
    sdk = Path(flags[flags.index("-sdk") + 1])
    sdk_metadata = [str(path) for path in (sdk / "SDKSettings.json", sdk / "SDKSettings.plist") if path.is_file()]
    if not sdk_metadata:
        raise ValueError("Cannot fingerprint the selected SDK metadata")
    print(fingerprint(configuration, args.sources + args.dependency + sdk_metadata +
                      [__file__, "scripts/ui-test-shared-build.sh"]))


if __name__ == "__main__":
    main()
