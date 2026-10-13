#!/usr/bin/env python3
"""Measure CI commands without hiding failures. Standard library only.

Suite rows include their children: never sum suite and compile rows. SwiftPM's
build/test durations are explicitly tool-reported, not independently timed.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import threading
import time
import uuid


def compiler_inputs(command):
    if Path(command[0]).name != "swiftc":
        return {}
    sources = [value for value in command[1:] if value.endswith(".swift")]
    metadata = {"sourceCount": len(sources), "sourceFiles": sources,
                "argumentsSHA256": hashlib.sha256(json.dumps(command[1:]).encode()).hexdigest()}
    for flag, key in [("-target", "target"), ("-sdk", "sdk"), ("-module-name", "module")]:
        if flag in command:
            index = command.index(flag) + 1
            if index < len(command):
                metadata[key] = command[index]
    metadata["optimization"] = [value for value in command if value in
                                ("-O", "-Onone", "-Osize", "-whole-module-optimization")]
    return metadata


def reported_swift_metrics(line, metrics):
    text = line.decode("utf-8", "replace")
    build = re.search(r"Build complete! \(([\d.]+)(?:s|秒)\)", text)
    tests = re.search(r"Test run with (\d+) tests(?: in (\d+) suites)? passed after ([\d.]+) seconds", text)
    if build:
        metrics["buildSeconds"] = float(build[1])
    if tests:
        run = {"testCount": int(tests[1]), "testSeconds": float(tests[3])}
        if tests[2]:
            run["suiteCount"] = int(tests[2])
        # Some SwiftPM versions run one test bundle per target, others one merged
        # bundle. Retain every summary instead of silently overwriting the first.
        metrics.setdefault("testRuns", []).append(run)


def run(args):
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise ValueError("A command is required")
    directory = Path(os.environ["CI_TIMING_DIR"])
    directory.mkdir(parents=True, exist_ok=True)
    identity = uuid.uuid4().hex
    record = {"schemaVersion": 1, "id": identity, "parentID": os.environ.get("CI_TIMING_PARENT_ID"),
              "phase": args.phase, "label": args.label, "architecture": platform.machine(),
              "startedAtUTC": datetime.now(timezone.utc).isoformat(), "executable": Path(command[0]).name,
              **compiler_inputs(command)}
    if args.phase == "compile-link" and "-emit-library" in command:
        record["phase"] = "dependency-build"
    environment = dict(os.environ, CI_TIMING_PARENT_ID=identity)
    process = None
    received_signal = None
    metrics = {}
    threads = []
    started = time.monotonic()

    def forward(signum, _frame):
        nonlocal received_signal
        received_signal = signum
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signum)
            except ProcessLookupError:
                pass

    original_handlers = {sig: signal.signal(sig, forward) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        capture = args.phase == "core-tests"
        process = subprocess.Popen(command, env=environment, start_new_session=True,
                                   stdout=subprocess.PIPE if capture else None,
                                   stderr=subprocess.PIPE if capture else None)
        if received_signal is not None:
            forward(received_signal, None)
        if capture:
            def pump(stream, destination):
                for line in iter(stream.readline, b""):
                    destination.buffer.write(line)
                    destination.buffer.flush()
                    reported_swift_metrics(line, metrics)
                stream.close()
            for stream, destination in [(process.stdout, sys.stdout), (process.stderr, sys.stderr)]:
                thread = threading.Thread(target=pump, args=(stream, destination))
                thread.start()
                threads.append(thread)
        code = process.wait()
        for thread in threads:
            thread.join()
        code = 128 + received_signal if received_signal else (128 - code if code < 0 else code)
    except OSError as error:
        print(f"Cannot execute {command[0]}: {error}", file=sys.stderr)
        code = 127 if isinstance(error, FileNotFoundError) else 126
    finally:
        for sig, handler in original_handlers.items():
            signal.signal(sig, handler)
    record.update(seconds=round(time.monotonic() - started, 6), exitCode=code)
    if metrics:
        record["swiftReported"] = metrics
    try:
        temporary = directory / (identity + ".tmp")
        temporary.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(directory / (identity + ".json"))
    except OSError as error:
        # The command's failure must never be replaced by a telemetry failure.
        print(f"Could not save timing for {args.label}: {error}", file=sys.stderr)
    return code


def initialize(directory):
    directory.mkdir(parents=True, exist_ok=True)
    def output(*command):
        return subprocess.check_output(command, text=True).strip()
    metadata = {"schemaVersion": 1, "architecture": platform.machine(),
                "sourceCommit": output("git", "rev-parse", "HEAD"),
                "trackedChanges": bool(output("git", "status", "--porcelain", "--untracked-files=no")),
                "compiler": output("xcrun", "swiftc", "--version"),
                "sdk": output("xcrun", "--sdk", "macosx", "--show-sdk-path"),
                "sdkVersion": output("xcrun", "--sdk", "macosx", "--show-sdk-version")}
    (directory / "environment.json").write_text(json.dumps(metadata, indent=2) + "\n")


def report(directory, summary):
    rows = [json.loads(path.read_text()) for path in sorted(directory.glob("*.json"))
            if path.name not in ("environment.json", "summary.json")]
    if not rows:
        raise ValueError("No timing records were produced")
    rows.sort(key=lambda item: item["seconds"], reverse=True)
    (directory / "summary.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
    lines = ["## CI timings", "", "Suite durations include children; do not add them to compile durations.",
             "", "| Phase | Command | Seconds | Exit | Sources |", "| --- | --- | ---: | ---: | ---: |"]
    for row in rows:
        label = row["label"].replace("|", "\\|").replace("\n", " ")
        lines.append(f"| {row['phase']} | {label} | {row['seconds']:.2f} | {row['exitCode']} | {row.get('sourceCount', '—')} |")
        if "swiftReported" in row:
            value = row["swiftReported"]
            lines.append(f"| tool-reported | SwiftPM build | {value.get('buildSeconds', '—')} | | |")
            for index, run in enumerate(value.get("testRuns", []), 1):
                lines.append(f"| tool-reported | Test bundle {index}: {run['testCount']} tests | {run['testSeconds']} | | |")
    text = "\n".join(lines) + "\n"
    (directory / "summary.md").write_text(text)
    if summary:
        with Path(summary).open("a") as output:
            output.write(text)
    print(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    command = commands.add_parser("run")
    command.add_argument("--phase", required=True)
    command.add_argument("--label", required=True)
    command.add_argument("command", nargs=argparse.REMAINDER)
    for name in ("init", "report"):
        command = commands.add_parser(name)
        command.add_argument("--directory", type=Path, default=os.environ.get("CI_TIMING_DIR"))
    args = parser.parse_args()
    if args.action == "run":
        return run(args)
    if args.directory is None:
        parser.error("CI_TIMING_DIR or --directory is required")
    if args.action == "init":
        initialize(args.directory)
    else:
        report(args.directory, os.environ.get("GITHUB_STEP_SUMMARY"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
