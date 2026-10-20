#!/usr/bin/env python3
"""Compile locally; execute real launchd/LaunchServices checks only on disposable CI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shlex
import shutil
import subprocess
import time
import uuid

REPO = Path(__file__).resolve().parents[1]
PREFIX = "local.gpthud.migration-integration."
LSREGISTER = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")


def require(value, message):
    if not value:
        raise RuntimeError(message)


def command(arguments, *, env=None, check=True):
    result = subprocess.run(list(map(str, arguments)), cwd=REPO, env=env,
                            capture_output=True, text=True, timeout=90)
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {arguments}\n{result.stdout}\n{result.stderr}")
    return result


def wait_for(predicate, description, timeout=18):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise RuntimeError("Timed out: " + description)


def rendered_launcher(source, config, host_name):
    replacements = {
        'APP_NAME="GPTTouchBarHUD"': f'APP_NAME="{config["executableName"]}"',
        'LEGACY_APP_NAME="TouchBarCodexToken"': f'LEGACY_APP_NAME="LL{config["nonce"][:10]}"',
        '$HOME/Library/Application Support/GPT TouchBar HUD': '$HOME/Library/Application Support/' + config["supportDirectoryName"],
        '$HOME/Library/Application Support/TouchBarCodexToken': '$HOME/Library/Application Support/' + config["supportDirectoryName"] + '-legacy',
        '/usr/bin/defaults read io.github.zz-zed.GPTTouchBarHUD ': '/usr/bin/defaults read ' + config["bundleID"] + ' ',
        '/usr/bin/pgrep -x "Codex"': '/usr/bin/pgrep -x "' + host_name + '"',
        '/usr/bin/pgrep -x "ChatGPT"': '/usr/bin/pgrep -x "LAX' + config["nonce"][:8] + '"',
        '/usr/bin/pgrep -x "GPT"': '/usr/bin/pgrep -x "LBX' + config["nonce"][:8] + '"',
    }
    result = source
    for original, replacement in replacements.items():
        require(source.count(original) == 1, "Launcher source changed; review exact replacement: " + original)
        result = result.replace(original, replacement, 1)
    restored = result
    for original, replacement in reversed(list(replacements.items())):
        require(restored.count(replacement) == 1, "Ambiguous launcher identity rendering")
        restored = restored.replace(replacement, original, 1)
    require(restored == source, "Launcher logic changed beyond explicit identity/path constants")
    prefix = ('export HOME=' + shlex.quote(str(Path(config["root"]) / "home")) + '\n'
              'export CFFIXED_USER_HOME="$HOME"\n')
    # Keep the shebang first and all production logic after this test-only HOME prefix.
    first, rest = result.split('\n', 1)
    return first + '\n' + prefix + rest, {"sha256": hashlib.sha256(source.encode()).hexdigest(),
        "exactIdentityReplacements": replacements, "restoredProductionSourceMatches": True,
        "testPrefix": prefix, "stubbedCommands": []}


def build(root, config, arch):
    binary = root / "LaunchEntryIntegration"
    obj = root / "process-path.o"
    command(["xcrun", "clang", "-mmacosx-version-min=11.0", "-c", "Tests/LaunchEntryIntegrationProcess.c", "-o", obj])
    cache = command(["bash", "-c", 'source scripts/swift-module-cache.sh; swift_module_cache_path "' + arch + '-apple-macosx11.0"']).stdout.strip()
    sources = ["Sources/DiagnosticEvent.swift", "Sources/DiagnosticTaskTrace.swift", "Sources/DiagnosticProcessStore.swift",
               "Sources/DiagnosticStore.swift", "Sources/DiagnosticRecorder.swift", "Sources/HostAutoLaunchPreferences.swift",
               "Sources/HostAutoLauncher.swift", "Tests/MigrationProcessIntegrationIdentity.swift", "Tests/LaunchEntryIntegration.swift"]
    result = command(["xcrun", "swiftc", "-swift-version", "5", "-target", arch + "-apple-macosx11.0",
                      "-module-cache-path", cache, "-D", "MIGRATION_PROCESS_INTEGRATION", "-D", "LAUNCH_ENTRY_INTEGRATION",
                      *sources, obj, "-o", binary], check=False)
    (root / "build.log").write_text(result.stdout + result.stderr)
    require(result.returncode == 0, "Launch-entry integration harness build failed; see " + str(root / "build.log"))
    host_name = "LH" + config["nonce"][:10]
    source = (REPO / "Resources/gpt-touchbar-hud-launcher.sh").read_text()
    launcher, render_record = rendered_launcher(source, config, host_name)
    (root / "launcher-rendering.json").write_text(json.dumps(render_record, indent=2) + "\n")
    applications = []
    for name, identity in [("Migration Integration Old.app", config["bundleID"]),
                           ("Migration Integration New.app", config["bundleID"]),
                           ("Launch Entry Controller.app", config["bundleID"] + ".controller")]:
        app = root / "home/Applications" / name
        macos = app / "Contents/MacOS"
        resources = app / "Contents/Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        shutil.copy2(binary, macos / config["executableName"])
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identity,
            "CFBundleName": name[:-4], "CFBundleExecutable": config["executableName"], "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0", "LSUIElement": True,
            "LSMinimumSystemVersion": "11.0"}))
        (resources / "MigrationProcessIntegration.plist").write_bytes(plistlib.dumps(config))
        script = resources / "gpt-touchbar-hud-launcher.sh"
        script.write_text(launcher)
        script.chmod(0o700)
        command(["/bin/zsh", "-n", script])
        command(["/usr/bin/codesign", "--force", "--sign", "-", app])
        command(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
        applications.append(app)
    host = root / host_name
    # Preserve executable bytes, not system-only filesystem flags from the sealed volume.
    shutil.copyfile("/bin/sleep", host)
    host.chmod(0o700)
    return applications, host


def execute(root, config, applications, host):
    require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and os.environ.get("RUNNER_OS") == "macOS", "Real OS registration is allowed only on a disposable GitHub-hosted macOS runner")
    old, new, controller = applications
    tool = controller / "Contents/MacOS" / config["executableName"]
    env = dict(os.environ, HOME=str(root / "home"), CFFIXED_USER_HOME=str(root / "home"))
    target = f'gui/{os.getuid()}/{config["launchAgentLabel"]}'
    plist_path = root / "home/Library/LaunchAgents" / (config["launchAgentLabel"] + ".plist")
    logs = []
    hosts = []
    checks = []

    def control(action, app=None):
        args = [tool, "--control", action] + ([app] if app else [])
        result = command(args, env=env)
        record = json.loads(result.stdout.strip().splitlines()[-1])
        logs.append({"control": action, "target": str(app) if app else None, "result": record})
        return record

    def running():
        return control("list")["applications"]

    def events():
        return [value for path in (root / "events").glob("*.json")
                if (value := json.loads(path.read_text())).get("event") == "launchEntryReady"]

    def assert_no_launch(description, duration=6):
        before = len(events())
        time.sleep(duration)
        require(not running() and len(events()) == before, description)
        checks.append(description)

    def host_start():
        value = subprocess.Popen([str(host), "600"], cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        hosts.append(value)
        wait_for(lambda: command(["/usr/bin/pgrep", "-x", host.name], check=False).returncode == 0,
                 "unique real host sentinel visible to pgrep")
        return value

    def launch_at(app):
        wait_for(lambda: any(value["bundle"] == str(app) and value["nonce"] == config["nonce"]
                             and value["executable"] == str(app / "Contents/MacOS" / config["executableName"])
                             for value in events()), "real launcher opened " + app.name)
        require(any(value["bundle"] == str(app) for value in running()), "Ready fixture process not found at expected URL")

    cleanup = {"errors": []}
    try:
        environment = control("environment")
        (root / "gui-environment.json").write_text(json.dumps(environment, indent=2) + "\n")
        require(environment["guiDomainAvailable"], "Disposable runner has no usable GUI launchd domain")
        control("clear-preferences", old)
        control("enable", old)
        wait_for(lambda: re.search(r'\bruns\s*=\s*[1-9]', command(["/bin/launchctl", "print", target]).stdout),
                 "real bootstrap RunAtLoad execution")
        require(plistlib.loads(plist_path.read_bytes())["RunAtLoad"] is True, "RunAtLoad missing")
        assert_no_launch("RunAtLoad without a host does not open the app")
        first_host = host_start()
        launch_at(old)
        checks.append("real host detection and periodic launcher open the old exact bundle")
        # Suppress an interval race while the real manager changes the registration.
        locks = [root / "home/Library/Application Support" / (config["supportDirectoryName"] + suffix) / "manual-quit.lock"
                 for suffix in ("", "-legacy")]
        for lock in locks:
            lock.parent.mkdir(parents=True, exist_ok=True)
            lock.write_text("isolated manual quit fixture\n")
        control("stop")
        control("install", new)
        plist = plistlib.loads(plist_path.read_bytes())
        require(plist["ProgramArguments"] == ["/bin/zsh", str(new / "Contents/Resources/gpt-touchbar-hud-launcher.sh"), str(new)],
                "Real registration did not refresh to the new bundle path")
        checks.append("real HostAutoLaunchManager refreshes ProgramArguments to the new bundle")
        assert_no_launch("manual quit suppresses a real loaded launcher while host remains")
        first_host.terminate(); first_host.wait(timeout=5)
        wait_for(lambda: all(not lock.exists() for lock in locks), "host exit clears manual quit markers")
        assert_no_launch("host exit never opens an app while clearing manual quit markers", duration=1)
        host_start()
        launch_at(new)
        checks.append("host restart opens the new registered exact bundle")
        control("disable", new)
        control("stop")
        require(not plist_path.exists(), "Disable retained managed plist")
        missing = command(["/bin/launchctl", "print", target], check=False)
        require(missing.returncode == 113 and "Could not find service" in missing.stderr + missing.stdout,
                "Disable did not verify missing test service")
        control("install", new)
        require(not plist_path.exists(), "Manual installOrUpdate re-enabled a saved opt-out")
        # Exercise the actual stale-launcher preference guard, with real pgrep/open.
        command(["/bin/zsh", new / "Contents/Resources/gpt-touchbar-hud-launcher.sh", new], env=env)
        assert_no_launch("disabled preference blocks stale launcher and installOrUpdate", duration=1)
        opened = control("register-open", new)
        require(opened["bundle"] == str(new) and opened["executable"] == str(new / "Contents/MacOS" / config["executableName"]),
                "Explicit URL returned a different executable")
        checks.append("real LSRegisterURL plus explicit NSWorkspace URL returns the new running executable")
    finally:
        for process in hosts:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
        for action, app in [("disable", new), ("stop", None), ("clear-preferences", new)]:
            try: control(action, app)
            except Exception as error: cleanup["errors"].append(str(error))
        try:
            registered_paths = {str(Path(path)) for path in control("registered-paths")["paths"]}
        except Exception as error:
            cleanup["errors"].append(str(error))
            registered_paths = {str(app) for app in applications}
        for app in applications:
            if str(app) not in registered_paths:
                logs.append({"unregisterExactPath": str(app), "skipped": "not registered in LaunchServices"})
                continue
            result = command([LSREGISTER, "-u", app], check=False)
            logs.append({"unregisterExactPath": str(app), "status": result.returncode, "output": result.stdout + result.stderr})
            if result.returncode: cleanup["errors"].append("Cannot unregister exact fixture path: " + str(app))
        missing = command(["/bin/launchctl", "print", target], check=False)
        cleanup["testLabelMissing"] = missing.returncode == 113 and "Could not find service" in missing.stderr + missing.stdout
        try: cleanup["remainingFixtureApplications"] = running()
        except Exception as error: cleanup["errors"].append(str(error))
        try:
            wait_for(lambda: not control("registered-paths")["paths"], "exact fixture paths removed from LaunchServices", timeout=10)
            cleanup["registeredPathsRemoved"] = True
        except Exception as error:
            cleanup["registeredPathsRemoved"] = False
            cleanup["errors"].append(str(error))
        cleanup["ownedHostChildrenReaped"] = all(process.poll() is not None for process in hosts)
        cleanup["passed"] = not cleanup["errors"] and cleanup["registeredPathsRemoved"] and cleanup["testLabelMissing"] and not cleanup.get("remainingFixtureApplications") and cleanup["ownedHostChildrenReaped"]
        (root / "cleanup.json").write_text(json.dumps(cleanup, indent=2) + "\n")
        (root / "control-evidence.json").write_text(json.dumps(logs, indent=2) + "\n")
        (root / "checks.json").write_text(json.dumps(checks, indent=2) + "\n")
    require(cleanup["passed"], "Isolated launch-entry cleanup failed; see cleanup.json")
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=REPO / "build/launch-entry-integration" / platform.machine())
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--run", action="store_true", help="Register unique fixtures only on disposable CI")
    mode.add_argument("--compile-only", action="store_true", help="Build/verify without OS registration (default)")
    args = parser.parse_args()
    require(platform.system() == "Darwin", "Native macOS required")
    if args.run:
        require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
                and os.environ.get("RUNNER_OS") == "macOS", "--run requires disposable GitHub-hosted macOS")
    nonce = uuid.uuid4().hex
    output = args.output.resolve()
    root = output / ("fixture-" + nonce)
    root.mkdir(parents=True, mode=0o700)
    require(root.resolve() == root, "Integration root must be direct")
    config = {"root": str(root), "bundleID": PREFIX + nonce, "launchAgentLabel": PREFIX + nonce + ".launcher",
              "supportDirectoryName": "LaunchEntry-" + nonce, "bootFile": str(root / "boot.txt"),
              "executableName": "LE" + nonce[:10], "nonce": nonce}
    (root / "boot.txt").write_text(str(uuid.uuid4()) + "\n")
    (root / "configuration.json").write_text(json.dumps(config, indent=2) + "\n")
    applications, host = build(root, config, platform.machine())
    checks = execute(root, config, applications, host) if args.run else []
    summary = {"compiled": True, "realOSExecution": args.run, "root": str(root), "checks": checks,
               "boundaries": ["compile-only performs no launchd/LaunchServices registration or app launch",
                              "execution uses a disposable GUI session and unique test identities",
                              "launcher identity/path constants and HOME alone are rendered; OS commands stay real",
                              "manual quit marker is a fixture; full product menu/lifecycle is not run",
                              "registration and explicit URL behavior do not prove Dock/alias following or a real reboot"]}
    (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    output.mkdir(parents=True, exist_ok=True)
    (output / "latest.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("PASS launch-entry integration " + ("execution" if args.run else "compile-only") + ": " + str(root / "summary.json"))


if __name__ == "__main__":
    main()
