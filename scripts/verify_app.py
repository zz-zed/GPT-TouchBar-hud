#!/usr/bin/env python3
"""Verify an existing production app without rebuilding or launching it."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ARCHES = {"arm64", "x86_64"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*arguments):
    result = subprocess.run(arguments, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return result.stdout.decode("utf-8", "replace")


def verify_app(app, source, arches):
    app, source = Path(app), Path(source)
    require(app.is_dir() and not app.is_symlink(), f"Missing production app: {app}")
    require(arches and len(set(arches)) == len(arches) and set(arches) <= ARCHES,
            "Expected one or both native architectures: arm64, x86_64")
    expected = plistlib.loads((source / "Resources/Info.plist").read_bytes())
    actual = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleName", "CFBundleDisplayName",
                "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"):
        require(key in expected and key in actual and str(actual[key]) == str(expected[key]),
                f"App metadata differs from this source: {key}")
    require(expected["CFBundleIdentifier"] == "io.github.zz-zed.GPTTouchBarHUD"
            and expected["CFBundleExecutable"] == "GPTTouchBarHUD",
            "Installed app identity changed")
    require(expected["LSMinimumSystemVersion"] == "11.0", "Minimum macOS must remain 11.0")
    source_digest = command(sys.executable, str(source / "scripts/diagnostic-source-identity.py"), "--digest").strip()
    require(actual.get("HUDSourceSHA256") == source_digest, "App was built from different source inputs")
    binaries = (app / "Contents/MacOS/GPTTouchBarHUD", app / "Contents/Helpers/HookEmitter")
    for binary in binaries:
        require(binary.is_file() and os.access(binary, os.X_OK), f"Missing executable: {binary.name}")
        actual_arches = command("lipo", "-archs", str(binary)).split()
        require(len(actual_arches) == len(arches) and set(actual_arches) == set(arches),
                f"Binary architecture mismatch: {binary.name}")
        for arch in arches:
            output = command("xcrun", "vtool", "-show-build", "-arch", arch, str(binary))
            require(re.search(r"\bminos\s+11\.0(?:\.0)?\b", output),
                    f"Mach-O minimum macOS differs from 11.0: {binary.name} ({arch})")
    command("codesign", "--verify", "--all-architectures", "--strict", str(binaries[1]))
    command("codesign", "--verify", "--deep", "--strict", str(app))
    signature = subprocess.run(
        ["codesign", "-dvvv", str(binaries[1])], check=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE).stderr.decode("utf-8", "replace")
    require("Identifier=com.gpt-touchbar-hud.hook-emitter" in signature,
            "HookEmitter signing identity changed")
    return {"app": str(app), "architectures": arches,
            "version": actual["CFBundleShortVersionString"], "build": str(actual["CFBundleVersion"]),
            "minimumSystem": "11.0", "sourceDigest": source_digest, "passed": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=os.environ.get("HUD_APP_DIR", ROOT / "build/GPT TouchBar HUD.app"))
    parser.add_argument("--source", type=Path, default=ROOT)
    parser.add_argument("--arch", action="append", choices=sorted(ARCHES))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    arches = args.arch or os.environ.get("HUD_BUILD_ARCHS", platform.machine()).split()
    report = verify_app(args.app, args.source, arches)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    print("PASS: production app identity, source, signatures, architectures and macOS 11 minimum")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"App verification failed: {error}") from error
