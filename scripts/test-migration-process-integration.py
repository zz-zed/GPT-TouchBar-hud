#!/usr/bin/env python3
"""Real migration processes/LaunchServices on disposable CI; local use compiles only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import signal
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
OLD_NAME = "Migration Integration Old.app"
NEW_NAME = "Migration Integration New.app"
EXECUTABLE = "MigrationProcessIntegrationApp"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SOURCES = [
    "Sources/AppInstallationMigration.swift", "Sources/AppInstallationMaintenance.swift",
    "Sources/AppMigrationMacOSDriver.swift", "Sources/AppMigrationRuntime.swift",
    "Sources/SingleInstanceLock.swift", "Sources/AppUpdateModels.swift", "Sources/AppUpdateProgressChannel.swift",
    "Sources/HostAutoLauncher.swift", "Sources/HostAutoLaunchPreferences.swift",
    "Sources/DiagnosticEvent.swift", "Sources/DiagnosticTaskTrace.swift", "Sources/DiagnosticProcessStore.swift",
    "Sources/DiagnosticStore.swift", "Sources/DiagnosticRecorder.swift",
    "Tests/MigrationProcessIntegrationIdentity.swift", "Tests/MigrationProcessIntegrationApp.swift",
]


def require(value, message):
    if not value:
        raise RuntimeError(message)


def run(argv, *, log=None, timeout=90, check=True):
    result = subprocess.run(list(map(str, argv)), cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if log:
        Path(log).write_text(json.dumps({"argv": list(map(str, argv)), "code": result.returncode,
                                        "stdout": result.stdout, "stderr": result.stderr}, indent=2) + "\n")
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {argv}; {result.stderr[-3000:]}")
    return result


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def wait_for(check, description, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.1)
    raise RuntimeError("Timed out: " + description)


def command(pid):
    result = run(["/bin/ps", "-p", str(pid), "-o", "command="], check=False)
    return result.stdout.strip() if result.returncode == 0 else ""


def running(pid):
    result = run(["/bin/ps", "-p", str(pid), "-o", "stat="], check=False)
    return result.returncode == 0 and not result.stdout.strip().startswith("Z")


def events(root):
    return sorted((value for path in (root / "events").glob("*.json")
                   if (value := read_json(path))), key=lambda value: value["time"])


def event(root, name, *, after=0, phase=None, bundle=None):
    return next((value for value in reversed(events(root)) if value["event"] == name and value["time"] >= after
                 and (phase is None or value.get("phase") == phase)
                 and (bundle is None or value.get("bundle") == str(bundle))), None)


def kill_owned(root, pid):
    name = command(pid)
    if not name:
        return
    require(name.startswith(str(root) + "/") and "/Contents/MacOS/" + EXECUTABLE in name,
            "Refusing to signal a PID outside this exact integration root: " + name)
    os.kill(pid, signal.SIGKILL)
    wait_for(lambda: not running(pid), "process exit " + str(pid), timeout=10)


def owned_processes(root):
    matches = []
    for line in run(["/bin/ps", "-axo", "pid=,command="]).stdout.splitlines():
        match = re.match(r"\s*(\d+)\s+(.*)", line)
        if match and match[2].startswith(str(root) + "/") and "/Contents/MacOS/" + EXECUTABLE in match[2]:
            matches.append({"pid": int(match[1]), "command": match[2]})
    return matches


def cleanup(root, identity):
    # LaunchServices launches are not put in our process group. Never kill a
    # GUI process group; match only this unique root's executable paths.
    evidence = {"errors": [], "signaled": [], "unregister": [], "identity": identity}
    for process in owned_processes(root):
        try:
            kill_owned(root, process["pid"])
            evidence["signaled"].append(process)
        except ProcessLookupError:
            pass
        except Exception as error:
            evidence["errors"].append(str(error))
    apps = list(root.rglob("*.app"))
    for app in apps:
        result = run([LSREGISTER, "-u", app], check=False)
        evidence["unregister"].append({"path": str(app), "exit": result.returncode,
                                       "stdout": result.stdout, "stderr": result.stderr})
        if result.returncode:
            evidence["errors"].append("Cannot unregister exact fixture path: " + str(app))
    try:
        probe = next(app / "Contents/MacOS" / EXECUTABLE for app in apps
                     if (app / "Contents/MacOS" / EXECUTABLE).is_file())
        def registered_paths():
            return json.loads(run([probe, "--probe-registrations"]).stdout)
        wait_for(lambda: not registered_paths(), "exact fixture LaunchServices registrations removed", timeout=10)
        evidence["remainingRegisteredPaths"] = registered_paths()
    except Exception as error:
        evidence["errors"].append(str(error))
    deleted = run(["/usr/bin/defaults", "delete", identity], check=False)
    missing = run(["/usr/bin/defaults", "read", identity], check=False)
    evidence["defaults"] = {"deleteExit": deleted.returncode, "deleteOutput": deleted.stdout + deleted.stderr,
                             "readExit": missing.returncode, "readOutput": missing.stdout + missing.stderr}
    evidence["preferenceDomainMissing"] = missing.returncode != 0 and "does not exist" in (missing.stdout + missing.stderr).lower()
    label = identity + ".launcher"
    target = "gui/" + str(os.getuid()) + "/" + label
    removed = run(["/bin/launchctl", "bootout", target], check=False)
    absent = run(["/bin/launchctl", "print", target], check=False)
    evidence["launchd"] = {"exactLabel": label, "bootoutExit": removed.returncode,
                            "bootoutOutput": removed.stdout + removed.stderr, "printExit": absent.returncode,
                            "printOutput": absent.stdout + absent.stderr}
    evidence["testLabelMissing"] = absent.returncode == 113 and "could not find service" in (absent.stdout + absent.stderr).lower()
    evidence["remainingOwnedProcesses"] = owned_processes(root)
    evidence["passed"] = not evidence["errors"] and not evidence["remainingOwnedProcesses"] and not evidence.get("remainingRegisteredPaths", ["unknown"]) and evidence["preferenceDomainMissing"] and evidence["testLabelMissing"]
    (root / "cleanup.json").write_text(json.dumps(evidence, indent=2) + "\n")
    require(evidence["passed"], "Isolated process integration cleanup failed; see " + str(root / "cleanup.json"))


def build(output):
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).stdout.strip()
    binary = output / EXECUTABLE
    argv = ["xcrun", "swiftc", "-parse-as-library", "-D", "MIGRATION_PROCESS_INTEGRATION", "-sdk", sdk,
            "-target", platform.machine() + "-apple-macosx11.0", "-module-cache-path", output / "module-cache",
            *SOURCES, "-o", binary]
    run(argv, log=output / "compile.json", timeout=240)
    return binary


def make_case(output, name, binary):
    root = output / name
    for path in [root / "Applications", root / "home/Applications", root / "events"]:
        path.mkdir(parents=True)
    identity = "local.gpthud.migration-integration." + str(uuid.uuid4()).lower()
    boot = str(uuid.uuid4())
    (root / "boot.txt").write_text(boot + "\n")
    app = root / "Applications" / OLD_NAME
    macos = app / "Contents/MacOS"
    resources = app / "Contents/Resources"
    macos.mkdir(parents=True); resources.mkdir()
    run(["/usr/bin/ditto", binary, macos / EXECUTABLE])
    info = {"CFBundleIdentifier": identity, "CFBundleExecutable": EXECUTABLE, "CFBundlePackageType": "APPL",
            "CFBundleName": "Isolated migration process integration", "CFBundleShortVersionString": "0.1.46",
            "CFBundleVersion": "integration", "LSUIElement": True, "LSMinimumSystemVersion": "11.0"}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    config = {"root": str(root), "bundleID": identity, "launchAgentLabel": identity + ".launcher",
              "supportDirectoryName": identity, "bootFile": str(root / "boot.txt"), "autoLaunchEnabled": "false"}
    (resources / "MigrationProcessIntegration.plist").write_bytes(plistlib.dumps(config))
    run(["/usr/bin/codesign", "--force", "--sign", "-", app], log=root / "codesign.json")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    return root, app, identity, boot


def launch(app, log):
    run(["/usr/bin/open", "-n", app], log=log)


def pending(root, app):
    start = time.time()
    launch(app, root / "initial-open.json")
    journal = root / "home/journal/state.json"
    transaction = wait_for(lambda: (value if (value := read_json(journal)) and value["phase"] == "pending" else None),
                           "real source minimal core/pending")
    core = wait_for(lambda: event(root, "minimal-core-ready", after=start, bundle=app), "source minimal core")
    require(transaction["observedBoot"] == (root / "boot.txt").read_text().strip(), "Pending boot differs")
    # A real competing process must fail the real SingleInstanceLock.
    duplicate = time.time()
    launch(app, root / "duplicate-open.json")
    wait_for(lambda: event(root, "duplicate-application-rejected", after=duplicate, bundle=app), "real duplicate lock rejection")
    kill_owned(root, core["pid"])
    (root / "boot.txt").write_text(str(uuid.uuid4()) + "\n")  # Explicitly simulated natural reboot.
    return journal, transaction


def verify_commit(root, journal, initial, *, after):
    transaction = wait_for(lambda: (value if (value := read_json(journal)) and value["phase"] == "committed" else None),
                           "committed real runtime transaction", timeout=55)
    target = Path(transaction["target"])
    archive = Path(transaction["stage"]) / "previous.app"
    ready = read_json(Path(transaction["stage"]) / "ready.json")
    require(ready and ready["boot"] == (root / "boot.txt").read_text().strip(), "No current-boot actual ready")
    require(ready["target"] == str(target) and ready["identity"] == transaction["identity"], "Wrong ready target or identity")
    require(command(ready["pid"]).startswith(str(target) + "/"), "Ready process is not the live target")
    require(not Path(transaction["source"]).exists() and archive.is_dir(), "Source was not archived")
    stat = archive.stat()
    require(f"{stat.st_dev}:{stat.st_ino}" == initial["sourceFileID"], "Archive lost original inode")
    require(event(root, "minimal-core-ready", after=after, bundle=target), "Target minimal core did not run")
    for app in [target, archive]:
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    probe = run([target / "Contents/MacOS" / EXECUTABLE, "--probe-readiness"])
    require(probe.stdout.strip() == "CURRENT", "Driver did not confirm real current ready process")
    return transaction, ready


def run_case(output, name, binary):
    root, app, identity, original_boot = make_case(output, name, binary)
    result = {"name": name, "identity": identity, "root": str(root), "bootTransitionIsSimulated": True}
    recovery = None
    try:
        journal, initial = pending(root, app)
        started = time.time()
        if name.startswith("helper-killed-"):
            phase = name.removeprefix("helper-killed-")
            (root / "pause-phase").write_text(phase + "\n")
            launch(app, root / "migration-open.json")
            checkpoint = wait_for(lambda: event(root, "checkpoint", after=started, phase=phase), "real helper checkpoint " + phase)
            interrupted = read_json(journal)
            require(interrupted["phase"] == ("pending" if phase == "helper-lock-acquired" else phase), "Checkpoint journal phase differs")
            if phase in ("candidateReady", "referencesReady", "archived", "committed"):
                # The real candidate starts a competing recovery helper. Wait
                # until that process has observed the held kernel lock before
                # killing its owner, so this case controls the later restart.
                wait_for(lambda: event(root, "helper-maintenance-busy", after=started), "candidate recovery helper rejected by held maintenance lock")
            kill_owned(root, checkpoint["pid"])
            result["killedHelperPID"] = checkpoint["pid"]
            (root / "pause-phase").unlink()
            if phase == "candidateReady":
                target = Path(interrupted["target"])
                receipt = Path(interrupted["stage"]) / "ready.json"
                genuine_ready = read_json(receipt)
                probe = target / "Contents/MacOS" / EXECUTABLE
                require(run([probe, "--probe-readiness"]).stdout.strip() == "CURRENT", "Live actual readiness rejected")
                genuine_boot = genuine_ready["boot"]
                def rejected_mutation(label, **changes):
                    message = dict(genuine_ready); message.update(changes)
                    receipt.write_text(json.dumps(message)); receipt.chmod(0o600)
                    result = run([probe, "--probe-readiness"], check=False)
                    require(result.returncode != 0 or result.stdout.strip() == "NOT_CURRENT", label + " accepted")
                rejected_mutation("Wrong launchDate with original live PID", launchedAt=genuine_ready["launchedAt"] + 1)
                rejected_mutation("Other live process PID", pid=os.getpid())
                rejected_mutation("Wrong exact target path", target=str(root / "wrong.app"))
                rejected_mutation("Wrong transaction nonce", id=str(uuid.uuid4()))
                # Restore the genuine message to isolate the following boot checks.
                receipt.write_text(json.dumps(genuine_ready)); receipt.chmod(0o600)
                (root / "boot.txt").write_text(str(uuid.uuid4()) + "\n")
                require(run([probe, "--probe-readiness"]).stdout.strip() == "NOT_CURRENT", "Old boot accepted with live PID/date")
                # Invalidate the genuine receipt's boot key; never synthesize an ACK.
                without_boot = dict(genuine_ready); without_boot.pop("boot")
                receipt.write_text(json.dumps(without_boot)); receipt.chmod(0o600)
                require(run([probe, "--probe-readiness"]).stdout.strip() == "NOT_CURRENT", "Pre-boot-schema ready accepted")
                # Restore the genuine bytes and simulated boot to isolate the
                # dead-process predicate; no new successful receipt is authored.
                receipt.write_text(json.dumps(genuine_ready)); receipt.chmod(0o600)
                (root / "boot.txt").write_text(genuine_boot + "\n")
                kill_owned(root, genuine_ready["pid"])
                require(run([probe, "--probe-readiness"]).stdout.strip() == "NOT_CURRENT", "Dead process ready accepted")
                (root / "boot.txt").write_text(str(uuid.uuid4()) + "\n")
                result["readinessRejections"] = ["mutated launchDate with original live PID", "mutated other live PID",
                                                 "mutated target", "mutated nonce", "previous boot with live PID/date",
                                                 "missing boot field", "dead candidate"]
                launch(target, root / "recover-target-open.json")
            else:
                # Relaunch the actual signed private helper using its validated
                # original handoff. This also works after source archival.
                helper = Path(interrupted["stage"]) / "migration-helper.app/Contents/MacOS" / EXECUTABLE
                recovery = subprocess.Popen([str(helper), "--hud-private-migration-helper", interrupted["id"]],
                                            cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                result["recoveryHelperPID"] = recovery.pid
        elif name == "maintenance-contention":
            executable = app / "Contents/MacOS" / EXECUTABLE
            holder = subprocess.Popen([str(executable), "--hold-maintenance"], cwd=ROOT,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            wait_for(lambda: event(root, "maintenance-holder-ready", after=started), "real maintenance holder")
            launch(app, root / "contended-open.json")
            wait_for(lambda: event(root, "startup-handed-off", after=started, bundle=app), "source handoff under contention")
            time.sleep(1)
            require(read_json(journal)["phase"] == "pending" and app.exists(), "Busy maintenance changed installation")
            kill_owned(root, holder.pid); holder.wait(timeout=10)
            launch(app, root / "post-contention-open.json")
            result["maintenanceContentionPreservedSource"] = True
        else:
            launch(app, root / "migration-open.json")
        transaction, ready = verify_commit(root, journal, initial, after=started)
        if recovery is not None:
            result["recoveryHelperExit"] = recovery.wait(timeout=35)
        result["committed"] = True
        result["actualReady"] = ready
        # A copied private helper is real signed code, not an arbitrary script.
        helper = Path(transaction["stage"]) / "migration-helper.app"
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", helper])
        result["privateHelperSigned"] = True
        if name == "normal":
            # One real archived-entry forwarding check is sufficient; the
            # checkpoint matrix independently proves every durable crash phase.
            kill_owned(root, ready["pid"])
            archive = Path(transaction["stage"]) / "previous.app"
            before = time.time()
            launch(archive, root / "archive-open.json")
            fresh = wait_for(lambda: event(root, "minimal-core-ready", after=before, bundle=Path(transaction["target"])),
                             "archived entry forwards to canonical target")
            require(not event(root, "minimal-core-ready", after=before, bundle=archive), "Archived core initialized")
            require(command(fresh["pid"]).startswith(transaction["target"] + "/"), "Forwarded target is not live")
            result["archiveForwardedWithoutArchivedCore"] = True
        result["passed"] = True
    finally:
        try:
            cleanup(root, identity)
            if recovery is not None:
                result["recoveryHelperReaped"] = recovery.wait(timeout=10) is not None
            result["cleanupPassed"] = True
        except Exception:
            result["passed"] = False
            result["cleanupPassed"] = False
            raise
        finally:
            (root / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--execute-disposable-ci", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    require(platform.system() == "Darwin" and platform.machine() in ("arm64", "x86_64"), "Native macOS required")
    require(not (args.compile_only and args.execute_disposable_ci), "Choose compile-only or CI execution")
    execute = args.execute_disposable_ci
    if execute:
        require(os.environ.get("GITHUB_ACTIONS") == "true" and bool(os.environ.get("RUNNER_TEMP"))
                and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted" and os.environ.get("RUNNER_OS") == "macOS",
                "Real launch/registration is restricted to an explicit disposable GitHub Actions runner")
        run(["/bin/launchctl", "print", "gui/" + str(os.getuid())], timeout=10)
        require(run(["/usr/sbin/sysctl", "-n", "sysctl.proc_translated"], check=False).stdout.strip() != "1", "No Rosetta")
    base = args.output or ROOT / "build/migration-integration" / platform.machine()
    base.mkdir(parents=True, exist_ok=True)
    output = (base / str(uuid.uuid4())).resolve()
    output.mkdir()
    summary = {"passed": False, "mode": "real-process-disposable-ci" if execute else "compile-only",
               "architecture": platform.machine(), "output": str(output),
               "productionAutomaticMigrationEnabled": False,
               "limits": ["Boot changes are simulated UUIDs; no real reboot", "Minimal signed test core, not full product AppDelegate",
                          "Unique test identity and roots; product identity is not compiled", "No fake launch or ready ACK"]}
    summary["sourceSHA256"] = {source: hashlib.sha256((ROOT / source).read_bytes()).hexdigest() for source in SOURCES}
    try:
        binary = build(output)
        summary["testBinarySHA256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        if execute:
            summary["cases"] = [run_case(output, name, binary) for name in
                                ("normal", "helper-killed-helper-lock-acquired", "helper-killed-prepared",
                                 "helper-killed-candidatePublished", "helper-killed-candidateReady",
                                 "helper-killed-referencesReady", "helper-killed-archived", "helper-killed-committed",
                                 "maintenance-contention")]
        summary["passed"] = True
    except Exception as error:
        summary["error"] = str(error)
        raise
    finally:
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print("Migration process integration evidence:", output / "summary.json", flush=True)


if __name__ == "__main__":
    main()
