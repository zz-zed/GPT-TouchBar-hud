#!/usr/bin/env python3
"""Compile the unchanged v0.1.22 release model; never launch/install an app."""
import argparse
import datetime
import hashlib
import json
import platform
from pathlib import Path
import re
import subprocess
import sys

TAG = "v0.1.22"
TAG_OBJECT = "df4a1be67085c6fc9763aca737574278ff196922"
COMMIT = "caf32ecebc1a069c930027cb239fb8bafb8ef1da"
SOURCE = "Sources/AppUpdateModels.swift"
BLOB = "8ed62e087f9a070769ef39dbb16ffd1d26a2760f"
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Current DMG version, without v")
    parser.add_argument("--arch", required=True, choices=["arm64", "x86_64"])
    parser.add_argument("--checksums", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="New isolated directory")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", args.version):
        parser.error("--version must contain 2 to 4 numeric components without v")
    checksums = args.checksums.resolve(strict=True)
    if not checksums.is_file():
        parser.error("--checksums must be a regular file")
    # mkdir(exist_ok=False) rejects reuse, including a pre-existing symlink.
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    evidence = {
        "status": "failed", "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "historical_source": {"tag": TAG, "tag_object": TAG_OBJECT, "commit": COMMIT,
                              "path": SOURCE, "blob": BLOB},
        "inputs": {"version": args.version, "architecture": args.arch,
                   "checksums_path": str(checksums),
                   "checksums_sha256": hashlib.sha256(checksums.read_bytes()).hexdigest()},
        "scope": "Unmodified historical AppUpdateModels compiled and executed with synthetic Release metadata and supplied checksum text",
        "limitations": ["No DMG bytes downloaded, mounted, hashed, or installed by this test",
                        "No historical updater discovery, package preparation, installer, rollback, application launch, or receipt tested",
                        "No real application, preferences, LaunchAgent, or Hooks accessed"],
        "commands": [],
    }

    def run(command):
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        evidence["commands"].append({"argv": command, "returncode": result.returncode,
                                     "stdout": result.stdout, "stderr": result.stderr})
        if result.returncode:
            raise RuntimeError(f"Command failed: {command[0]}")
        return result.stdout

    try:
        for expression, expected in [(TAG, TAG_OBJECT), (TAG + "^{}", COMMIT),
                                     (COMMIT + ":" + SOURCE, BLOB)]:
            actual = run(["git", "rev-parse", expression]).strip()
            if actual != expected:
                raise RuntimeError(f"Historical source identity mismatch: {expression}")
        source = run(["git", "show", COMMIT + ":" + SOURCE])
        extracted = output / "AppUpdateModels.swift"
        extracted.write_text(source)
        evidence["historical_source"]["sha256"] = hashlib.sha256(extracted.read_bytes()).hexdigest()
        fixture = ROOT / "Tests/EarliestUpdateCompatibility/main.swift"
        evidence["harness_sha256"] = hashlib.sha256(fixture.read_bytes()).hexdigest()
        compiler = run(["xcrun", "--find", "swiftc"]).strip()
        evidence["compiler"] = run([compiler, "--version"]).strip()
        sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        native_arch = {"arm64": "arm64", "x86_64": "x86_64"}.get(platform.machine())
        if native_arch is None:
            raise RuntimeError("This historical Foundation harness requires native macOS arm64 or x86_64")
        # --arch selects a release asset; the model harness always runs natively.
        evidence["harness_architecture"] = native_arch
        executable = output / "EarliestUpdateContract"
        run([compiler, "-sdk", sdk, "-target", native_arch + "-apple-macosx11.0",
             "-module-cache-path", str(output / "module-cache"), str(extracted),
             str(fixture), "-o", str(executable)])
        results = run([str(executable), args.version, args.arch, str(checksums)])
        evidence["results"] = json.loads(results)
        evidence["status"] = "passed"
    except Exception as error:
        evidence["error"] = str(error)
    finally:
        (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"{evidence['status'].upper()}: v0.1.22 model contract; evidence: {output / 'evidence.json'}")
    return 0 if evidence["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
