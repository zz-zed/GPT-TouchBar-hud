#!/usr/bin/env python3
"""Real Process/FD lifecycle checks; all filesystem effects stay in an owned temp tree."""
import os
from pathlib import Path
import signal
import re
import subprocess
import sys
import tempfile
import time


probe = Path(sys.argv[1]).resolve()
fixture = Path(__file__).with_name("InstallationMaintenanceFixture.zsh").resolve()
checks = 0
process_ids = []


def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message)
    checks += 1


def wait_for(predicate, message):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError(message)


def run(*arguments):
    return subprocess.run([str(probe), *map(str, arguments)], stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, timeout=10)


def lock_status(directory):
    result = run("--try", directory)
    check(result.returncode in (0, 3), f"Unexpected lock probe failure: {result.stderr}")
    return result.returncode


def marker(directory, name):
    path = directory / name
    wait_for(path.exists, f"Missing {name} marker in {directory}")
    return path.read_text()


def remember_pid(directory, name):
    pid = int(marker(directory, name))
    process_ids.append(pid)
    return pid


def process_exited(pid):
    state = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "state="],
                           capture_output=True, text=True, timeout=2).stdout.strip()
    return not state or state.startswith("Z")


def start_owner(directory, mode):
    directory.mkdir()
    result = run("--owner", directory, fixture, mode)
    check(result.returncode == 0, f"Owner failed: {result.stderr}")
    # subprocess.run reaped the application-shaped owner before any assertion below.
    marker(directory, "shell-started")
    return remember_pid(directory, "shell-pid")


with tempfile.TemporaryDirectory(prefix="hud-maintenance-lifecycle-") as raw:
    root = Path(raw).resolve()
    try:
        installer_source = fixture.parent.parent.joinpath("Resources/install-update.sh").read_text()
        open_body = re.search(r"hud_install_open\(\)\s*\{([^}]+)\}", installer_source).group(1)
        check("/usr/bin/open" in open_body and "</dev/null" in open_body,
              "Production launch boundary closes the inherited maintenance stdin")
        check(not re.search(r"(?m)^\s*read(?:\s|$)", installer_source),
              "Production installer does not consume the maintenance descriptor as stdin")
        for mode in ("success", "rollback", "orphan-descendant"):
            directory = root / mode
            shell_pid = start_owner(directory, mode)
            check(lock_status(directory) == 3, f"{mode}: shell must retain lock after owner exits")
            (directory / "shell-proceed").touch()
            marker(directory, "descendant-started")
            remember_pid(directory, "descendant-pid")
            check(marker(directory, "descendant-lock-fds") == "0", f"{mode}: only inherited stdin owns the lock")
            check(int(marker(directory, "descendant-stdin-flags")) & 1 == 0,
                  f"{mode}: duplicated stdin must survive synchronous exec")
            check(lock_status(directory) == 3, f"{mode}: synchronous descendant must exclude maintenance")
            if mode == "orphan-descendant":
                os.kill(shell_pid, signal.SIGKILL)
                wait_for(lambda: process_exited(shell_pid), "Killed installer shell did not exit")
                check(lock_status(directory) == 3, "Live orphan descendant must retain the shared lock")
            (directory / "descendant-release").touch()
            marker(directory, "descendant-finished")
            if mode != "orphan-descendant":
                check(marker(directory, "shell-result") == ("4" if mode == "rollback" else "0"),
                      f"{mode}: fixture completed its expected normal/rollback exit")
                check((directory / "GPT HUD.app/marker").read_text() == ("old" if mode == "rollback" else "new"),
                      f"{mode}: actual installer leaves the expected replacement or restored app")
            wait_for(lambda: lock_status(directory) == 0, f"{mode}: lock leaked after the process tree exited")
            check((directory / ".GPTTouchBarHUD-maintenance.lock").exists(), "Release preserves the shared lock inode")

        directory = root / "cloexec"
        directory.mkdir()
        result = run("--cloexec", directory)
        check(result.returncode == 0, f"CLOEXEC owner failed: {result.stderr}")
        check(marker(directory, "plain-lock-fds") == "", "Original CLOEXEC descriptor is absent from an ordinary child exec")
        check(lock_status(directory) == 0, "Original owner exit releases the lock when no stdin handoff occurred")

        for mode in ("launch-inherited", "launch-detached"):
            directory = root / mode
            shell_pid = start_owner(directory, mode)
            marker(directory, "launched-started")
            launched_pid = remember_pid(directory, "launched-pid")
            marker(directory, "shell-result")
            wait_for(lambda: process_exited(shell_pid), "Installer shell did not exit after launching its fixture")
            if mode == "launch-inherited":
                check(marker(directory, "launched-lock-fds") == "0", "Unclosed launch stdin carries the maintenance lock")
                check(lock_status(directory) == 3, "Inherited launch fixture demonstrates a lock held beyond installer exit")
            else:
                check(marker(directory, "launched-lock-fds") == "", "Explicit /dev/null launch stdin prevents lock inheritance")
                wait_for(lambda: lock_status(directory) == 0, "Detached launch must not keep the maintenance lock")
                os.kill(launched_pid, 0)
                check(True, "Detached launched process remains alive while maintenance is available")
            (directory / "launched-release").touch()
            marker(directory, "launched-finished")
            wait_for(lambda: lock_status(directory) == 0, "Launch fixture did not release its inherited descriptor")
    finally:
        for pid in reversed(process_ids):
            try:
                command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="],
                                         capture_output=True, text=True, timeout=2).stdout
                if str(probe) in command or str(fixture) in command:
                    os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

print(f"PASS: {checks} installation maintenance FD lifecycle checks")
