#!/usr/bin/env python3
"""Run the pinned v0.1.38 updater against an actual native release DMG."""

import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "Tests/LegacyUpdateCompatibility"
APP_NAME = "GPT TouchBar HUD.app"
BUNDLE_ID = "io.github.zz-zed.GPTTouchBarHUD"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(command, *, log=None, env=None, check=True, timeout=300):
    print("RUN", " ".join(map(str, command)), flush=True)
    if log is not None:
        with log.open("w") as stream:
            return subprocess.run(list(map(str, command)), cwd=ROOT, stdout=stream,
                                  stderr=subprocess.STDOUT, env=env, check=check, timeout=timeout)
    return subprocess.run(list(map(str, command)), cwd=ROOT, check=check, env=env, timeout=timeout)


def git(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=ROOT)


def mounted_paths():
    info = plistlib.loads(subprocess.check_output(["/usr/bin/hdiutil", "info", "-plist"]))
    return {entity["mount-point"] for image in info.get("images", [])
            for entity in image.get("system-entities", []) if "mount-point" in entity}


def group_members(pgid):
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,pgid=,stat="]).decode()
    return [int(pid) for pid, group, state in (line.split() for line in output.splitlines())
            if int(group) == pgid and not state.startswith("Z")]


def run_case_process(command, case, env, *, timeout=300, ready=None):
    """Own one fresh process group; clean only its children and exact case mount paths."""
    print("RUN", " ".join(map(str, command)), flush=True)
    process = None
    cleanup = {"case": str(case), "mountsBefore": [], "mountsAfter": []}
    try:
        with (case / "harness.log").open("w") as stream:
            process = subprocess.Popen(list(map(str, command)), cwd=ROOT, stdout=stream,
                                       stderr=subprocess.STDOUT, env=env, start_new_session=True)
            # start_new_session guarantees the new group identity is this exact child PID.
            cleanup["ownedProcessGroup"] = process.pid
            if ready is not None:
                deadline = time.monotonic() + 30
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                require(ready.exists(), "Controlled timeout child never created its mount/helper")
            result = process.wait(timeout=timeout)
            if result:
                raise subprocess.CalledProcessError(result, command)
    finally:
        errors = []
        if process is not None:
            pgid = process.pid
            # Never kill PIDs read from a file or discovered in another process group.
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(pgid, sig)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
                deadline = time.monotonic() + 2
                while group_members(pgid) and time.monotonic() < deadline:
                    time.sleep(0.05)
                if not group_members(pgid):
                    break
            cleanup["remainingProcessGroupMembers"] = group_members(pgid)
            if cleanup["remainingProcessGroupMembers"]:
                errors.append("Owned process group still has live members")
        # Also detect a helper that unexpectedly escaped the owned group; do not kill it by PID.
        cleanup["remainingFixtureHelpers"] = []
        for pidfile in (case / "home/Applications").glob(".GPTTouchBarHUD-update-*/helper-fixture.pid"):
            pid = int(pidfile.read_text())
            probe = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "pid=,pgid=,stat="],
                                   capture_output=True, text=True)
            fields = probe.stdout.split()
            if fields and not fields[2].startswith("Z"):
                cleanup["remainingFixtureHelpers"].append({"pid": pid, "group": int(fields[1])})
        if cleanup["remainingFixtureHelpers"]:
            errors.append("Fixture helper escaped owned process-group cleanup")
        # Match exact generated channel/mount paths, never every mounted image or a broad prefix.
        applications = case / "home/Applications"
        candidates = {str(path) for path in applications.glob(".GPTTouchBarHUD-update-*/mount")
                      if path.parent.parent == applications and not path.parent.is_symlink()}
        try:
            cleanup["mountsBefore"] = sorted(mounted_paths() & candidates)
            for index, mount in enumerate(cleanup["mountsBefore"]):
                log = case / f"cleanup-detach-{index}.log"
                attempt = run(["/usr/bin/hdiutil", "detach", mount], log=log, check=False, timeout=30)
                if attempt.returncode:
                    run(["/usr/bin/hdiutil", "detach", "-force", mount],
                        log=case / f"cleanup-detach-{index}-force.log", timeout=30)
            cleanup["mountsAfter"] = sorted(mounted_paths() & candidates)
            if cleanup["mountsAfter"]:
                errors.append("Owned case DMG is still mounted")
        except Exception as error:
            errors.append(str(error))
        cleanup["errors"] = errors
        cleanup["passed"] = not errors
        (case / "cleanup.json").write_text(json.dumps(cleanup, indent=2) + "\n")
        require(not errors, "Case cleanup failed: " + "; ".join(errors))


def cleanup_timeout_self_test(dmg, output):
    """Prove the same finally path handles a live mounted DMG and sleep child on timeout."""
    case = output / "cleanup-timeout"
    home = case / "home"
    channel = home / "Applications" / (".GPTTouchBarHUD-update-" + str(uuid.uuid4()).upper())
    mount = channel / "mount"
    mount.mkdir(parents=True)
    ready = case / "ready"
    child = case / "timeout-child.py"
    child.write_text('''import pathlib, subprocess, sys, time
helper = subprocess.Popen(["/bin/sleep", "600"])
try:
    subprocess.run(["/usr/bin/hdiutil", "attach", sys.argv[1], "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", sys.argv[2]], check=True)
    pathlib.Path(sys.argv[3]).write_text(str(helper.pid))
    time.sleep(600)
finally:
    helper.terminate()
    helper.wait()
''')
    try:
        run_case_process([sys.executable, child, dmg, mount, ready], case,
                         dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home)), timeout=0.1, ready=ready)
    except subprocess.TimeoutExpired:
        report = json.loads((case / "cleanup.json").read_text())
        require(report["passed"] and str(mount) in report["mountsBefore"],
                "Timeout self-test did not exercise mounted-image cleanup")
        print("PASS controlled timeout: own process group terminated and exact case DMG detached", flush=True)
        return report
    raise RuntimeError("Controlled timeout child unexpectedly completed")


def sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def tree(path):
    """Include symlink destinations and executable bits as well as file bytes."""
    result = {}
    for item in sorted(path.rglob("*")):
        relative = str(item.relative_to(path))
        if item.is_symlink():
            result[relative] = ["symlink", os.readlink(item)]
        elif item.is_file():
            result[relative] = ["file", item.stat().st_mode & 0o777, sha256(item)]
    return result


def extract_sources(output):
    manifest = json.loads((FIXTURE / "manifest.json").read_text())
    tag_ref = "refs/tags/" + manifest["tag"]
    require(git("rev-parse", tag_ref).decode().strip() == manifest["tagObject"],
            "Historical tag object differs from manifest; use a full checkout with original tags")
    require(git("rev-parse", tag_ref + "^{commit}").decode().strip() == manifest["commit"],
            "Historical tag does not peel to the pinned source commit")
    require(git("cat-file", "-t", manifest["tagObject"]).decode().strip() == "tag",
            "Historical tag must remain the original annotated tag object")
    source_root = output / "historical"
    source_root.mkdir()
    sources = []
    for path, expected in manifest["files"].items():
        data = git("show", manifest["commit"] + ":" + path)
        require(hashlib.sha256(data).hexdigest() == expected, "Historical SHA256 mismatch: " + path)
        destination = source_root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        require(destination.read_bytes() == data, "Historical source extraction changed bytes: " + path)
        if destination.suffix == ".swift":
            sources.append(destination)
    return manifest, source_root, sorted(sources)


def inspect_dmg(dmg, arch, output):
    mount = output / "preflight-mount"
    mount.mkdir()
    run(["/usr/bin/hdiutil", "attach", dmg, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount],
        log=output / "preflight-attach.log")
    try:
        app = mount / APP_NAME
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        require(info["CFBundleIdentifier"] == BUNDLE_ID, "Unexpected DMG bundle identity")
        require(info["CFBundleName"] == "GPT HUD", "DMG does not contain the renamed product")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
        run(["/usr/bin/lipo", app / "Contents/MacOS" / info["CFBundleExecutable"], "-verify_arch", arch])
        version = info["CFBundleShortVersionString"]
        require(dmg.name == f"GPT-TouchBar-HUD-{version}-{arch}.dmg", "Unexpected release asset filename")
        return version
    finally:
        run(["/usr/bin/hdiutil", "detach", mount], log=output / "preflight-detach.log")


def build_harness(arch, output, source_root, sources):
    app = output / "HistoricalUpdaterHarness.app"
    macos = app / "Contents/MacOS"
    resources = app / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "local.legacy-updater.fixture." + arch,
        "CFBundleName": "Historical updater test harness",
        "CFBundleExecutable": "Harness", "CFBundlePackageType": "APPL",
    }))
    historical_installer = source_root / "Resources/install-update.sh"
    shutil.copyfile(historical_installer, resources / "install-update.sh")
    executable = macos / "Harness"
    run(["xcrun", "swiftc", "-target", arch + "-apple-macosx11.0", "-module-cache-path", output / "module-cache",
         *sources, FIXTURE / "Harness.swift", "-o", executable], log=output / "build.log")
    return executable, historical_installer


def create_old_fixture(output, source_version):
    # An inert native binary supplies an installed-version fixture, never a historical app binary.
    old = output / "inert-old.app"
    (old / "Contents/MacOS").mkdir(parents=True)
    source = output / "inert.c"
    source.write_text("int main(void) { return 0; }\n")
    run(["xcrun", "clang", source, "-o", old / "Contents/MacOS/Fixture"])
    (old / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
        "CFBundleName": "INERT OLD VERSION TEST FIXTURE", "CFBundleShortVersionString": source_version,
        "CFBundleVersion": "fixture",
    }))
    run(["/usr/bin/codesign", "--force", "--sign", "-", old])
    return old


def release_metadata(version, arch, size):
    tag = "v" + version
    base = f"https://github.com/zz-zed/GPT-TouchBar-hud/releases/download/{tag}/"
    name = f"GPT-TouchBar-HUD-{version}-{arch}.dmg"
    return {"tag_name": tag, "draft": False, "prerelease": False, "name": "GPT HUD " + version,
            "assets": [{"name": name, "browser_download_url": base + name, "size": size},
                       {"name": "SHA256SUMS.txt", "browser_download_url": base + "SHA256SUMS.txt", "size": 200}]}


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format_string, *arguments):
        print("HTTP", format_string % arguments, flush=True)


def download_case(name, dmg, version, arch, expected, output, old, executable, port, *, bad_checksum=False):
    case = output / name
    home = case / "home"
    (home / "Applications").mkdir(parents=True)
    target = home / "Applications" / APP_NAME
    run(["/usr/bin/ditto", old, target])
    transport = case / "transport"
    transport.mkdir()
    (transport / "package.dmg").symlink_to(dmg)
    asset_name = f"GPT-TouchBar-HUD-{version}-{arch}.dmg"
    digest = "0" * 64 if bad_checksum else sha256(dmg)
    (transport / "SHA256SUMS.txt").write_text(f"{digest}  {asset_name}\n")
    release = case / "release.json"
    release.write_text(json.dumps(release_metadata(version, arch, dmg.stat().st_size), indent=2) + "\n")
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
    run_case_process([executable, home, release, f"http://127.0.0.1:{port}/{name}/transport", expected, dmg.stat().st_size],
                     case, env)
    result = json.loads((home / "result.json").read_text())
    require(result["passed"] and result["architecture"] == arch, name + " harness result failed")
    require(tree(target) == tree(old), name + " unexpectedly changed the installed target")
    if expected == "prepared":
        require(result["reachedHandoff"], "Positive case did not reach handoff boundary")
    else:
        require(result["phase"] == "failed", name + " did not reject the input")
    print("PASS", name, flush=True)
    return result


def installer_cases(output, old, prepared, installer, version, source_version):
    results = []
    for mode in ("success", "rollback"):
        home = output / ("install-" + mode) / "home"
        (home / "Applications").mkdir(parents=True)
        target = home / "Applications" / APP_NAME
        run(["/usr/bin/ditto", old, target])
        session = str(uuid.uuid4()).upper()
        stage = home / "Applications" / (".GPTTouchBarHUD-update-" + session)
        stage.mkdir(mode=0o700)
        run(["/usr/bin/ditto", prepared, stage / "new.app"])
        # Select a verified non-live owner PID without replacing the historical liveness primitive.
        dead_pid = subprocess.Popen(["/usr/bin/true"])
        dead_pid.wait()
        context = {"sessionID": session, "targetPath": str(target), "sourceVersion": source_version,
                   "targetVersion": "v" + version, "ownerPID": dead_pid.pid}
        (stage / "context.json").write_text(json.dumps(context))
        (stage / "progress-helper").write_text("#!/bin/sh\nexit 0\n")
        (stage / "progress-helper").chmod(0o700)
        env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
        run(["/bin/zsh", FIXTURE / "installer-fixture.zsh", installer, stage, home, mode],
            log=stage / "fixture.log", env=env)
        state = json.loads((stage / "install.json").read_text())
        require(state["phase"] == ("succeeded" if mode == "success" else "failed"), mode + " wrong phase")
        require(state["recovery"] == ("backupRetained" if mode == "success" else "restored"), mode + " wrong recovery")
        original = stage / "previous.app" if mode == "success" else target
        new = target if mode == "success" else stage / "failed.app"
        require(tree(original) == tree(old), mode + " changed original app bytes")
        require(tree(new) == tree(prepared), mode + " changed prepared app bytes")
        for app in (original, new):
            run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
        results.append({"mode": mode, "state": state, "oldAndNewTreeHashesMatch": True})
        print("PASS installer", mode, flush=True)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--arch", required=True, choices=("arm64", "x86_64"))
    parser.add_argument("--output", required=True, type=Path, help="New, retained evidence directory")
    args = parser.parse_args()
    require(platform.system() == "Darwin", "Requires native macOS tools")
    require(platform.machine() == args.arch, "Run only on the DMG's native architecture")
    translated = subprocess.run(["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"], capture_output=True, text=True)
    require(translated.stdout.strip() != "1", "Rosetta execution is not a native test")
    dmg = args.dmg.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    manifest, source_root, sources = extract_sources(output)
    version = inspect_dmg(dmg, args.arch, output)
    cleanup_test = cleanup_timeout_self_test(dmg, output)
    require(tuple(map(int, version.split("."))) > tuple(map(int, manifest["sourceVersion"].split("."))),
            "Target must be newer than the historical baseline")
    executable, installer = build_harness(args.arch, output, source_root, sources)
    old = create_old_fixture(output, manifest["sourceVersion"])
    receipt_home = output / "receipt-home"
    receipt_home.mkdir()
    run([executable, "--receipt-boundaries", receipt_home / "Applications", version],
        log=output / "receipt-boundaries.log", env=dict(os.environ, HOME=str(receipt_home), CFFIXED_USER_HOME=str(receipt_home)))
    results = []
    handler = functools.partial(Handler, directory=str(output))
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            port = server.server_address[1]
            positive = download_case("valid", dmg, version, args.arch, "prepared", output, old, executable, port)
            results.append(positive)
            prepared = Path(positive["preparedPayload"])
            staged_installer = Path(positive["channel"]) / "install-update.sh"
            require(staged_installer.read_bytes() == installer.read_bytes(),
                    "Preparation did not copy the exact old Bundle.main installer")
            checksum = download_case("bad-checksum", dmg, version, args.arch, "rejected", output, old, executable, port,
                                     bad_checksum=True)
            require("SHA-256" in checksum["message"], "Checksum negative failed for an unrelated reason")
            results.append(checksum)
            parts = list(map(int, version.split(".")))
            parts[-1] += 1
            wrong_version = ".".join(map(str, parts))
            mismatch = download_case("bad-version", dmg, wrong_version, args.arch, "rejected", output, old, executable, port)
            require("应用标识或版本不匹配" in mismatch["message"], "Version negative failed for an unrelated reason")
            results.append(mismatch)
            image = output / "tampered-image"
            image.mkdir()
            tampered_app = image / APP_NAME
            run(["/usr/bin/ditto", prepared, tampered_app])
            with (tampered_app / "Contents/Resources/AppIcon.icns").open("ab") as stream:
                stream.write(b"LEGACY-SIGNATURE-NEGATIVE-FIXTURE")
            invalid = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", tampered_app],
                          log=output / "tampered-codesign.log", check=False)
            require(invalid.returncode != 0, "Tampered resource unexpectedly retained a valid signature")
            tampered_dmg = output / "tampered.dmg"
            run(["/usr/bin/hdiutil", "create", "-srcfolder", image, "-volname", "Legacy update negative", "-format", "UDZO", tampered_dmg],
                log=output / "tampered-dmg.log")
            signature = download_case("bad-signature", tampered_dmg, version, args.arch, "rejected", output, old, executable, port)
            require(signature["step"] == "validating" and signature["message"] == "更新准备失败，原应用未替换。",
                    "Signature negative failed before historical signed-bundle validation")
            results.append(signature)
        finally:
            server.shutdown()
            worker.join(timeout=5)
    installs = installer_cases(output, old, prepared, staged_installer, version, manifest["sourceVersion"])
    summary = {"passed": True, "architecture": args.arch, "dmg": str(dmg), "dmgSHA256": sha256(dmg),
               "targetVersion": version, "source": manifest, "downloadCases": results, "installerCases": installs,
               "oldBundleInstallerSHA256": sha256(staged_installer), "receiptBoundariesPassed": True,
               "controlledTimeoutCleanup": cleanup_test,
               "boundaries": ["synthetic release metadata; loopback download transport", "inert old target, never launched",
                              "sleep-only progress helper; stop before installer process handoff",
                              "old shell installer from old Bundle.main; launch/receipt/pause primitives simulated",
                              "historical receipt primitives tested directly; full app and real launch confirmation untested"]}
    (output / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    print("PASS legacy update compatibility:", output / "summary.json", flush=True)


if __name__ == "__main__":
    main()
