"""Exercise actual process contention without launching the HUD or touching user state."""
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile

probe = str(Path(sys.argv[1]).resolve())
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


def launch(path):
    return subprocess.Popen([probe, str(path)], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def send(process, message):
    process.stdin.write(message + "\n")
    process.stdin.flush()


def response(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        assert selector.select(timeout=10), "Timed out waiting for lock probe"
    return process.stdout.readline().strip()


with tempfile.TemporaryDirectory(prefix="hud-single-instance-") as directory:
    lock_path = Path(directory) / "support" / "application-instance.lock"
    processes = []
    try:
        for iteration in range(5):
            contenders = [launch(lock_path) for _ in range(12)]
            processes.extend(contenders)
            for process in contenders:
                send(process, "start")
            results = [response(process) for process in contenders]
            check(results.count("owner") == 1, "Exactly one concurrent launch owns the lock")
            check(results.count("duplicate") == 11, "Every duplicate exits before starting UI")
            owner = contenders[results.index("owner")]
            for process, result in zip(contenders, results):
                if result == "duplicate":
                    check(process.wait(timeout=10) == 0, "Duplicate is a normal exit")
            inode = lock_path.stat().st_ino
            if iteration % 2:
                owner.kill()
                owner.wait(timeout=10)
            else:
                send(owner, "quit")
                check(owner.wait(timeout=10) == 0, "Owner exits normally")
            check(lock_path.stat().st_ino == inode, "Persistent lock file retains its inode")
            reopened = launch(lock_path)
            processes.append(reopened)
            send(reopened, "start")
            check(response(reopened) == "owner", "Normal exit and SIGKILL both permit restart")
            send(reopened, "quit")
            check(reopened.wait(timeout=10) == 0, "Restarted owner exits normally")

        # A surviving app-server / installer child must not prevent the next launch.
        parent = launch(lock_path)
        processes.append(parent)
        send(parent, "start")
        check(response(parent) == "owner", "Parent acquires before starting child")
        send(parent, "spawn-child")
        child_pid = int(response(parent).removeprefix("child "))
        try:
            send(parent, "quit")
            check(parent.wait(timeout=10) == 0, "Parent exits while child remains")
            os.kill(child_pid, 0)
            replacement = launch(lock_path)
            processes.append(replacement)
            send(replacement, "start")
            check(response(replacement) == "owner", "Surviving child does not retain the lock")
            send(replacement, "quit")
            check(replacement.wait(timeout=10) == 0, "Replacement exits normally")
        finally:
            os.kill(child_pid, signal.SIGTERM)

        # Failure to open must not be confused with owning the lock.
        invalid_path = Path(directory) / "not-a-directory"
        invalid_path.write_text("fixture")
        failed = launch(invalid_path / "application-instance.lock")
        processes.append(failed)
        send(failed, "start")
        out, _ = failed.communicate(timeout=10)
        check(failed.returncode != 0 and "owner" not in out, "Storage error fails closed")

        symlink_path = Path(directory) / "linked.lock"
        symlink_path.symlink_to(lock_path)
        failed = launch(symlink_path)
        processes.append(failed)
        send(failed, "start")
        out, _ = failed.communicate(timeout=10)
        check(failed.returncode != 0 and "owner" not in out, "Lock does not follow a symlink")

        # Keep this gate before both preference migration and AppDelegate creation.
        source = Path("Sources/main.swift").read_text()
        gate = source.index("try SingleInstanceLock(")
        check(gate < source.index("LegacyAppMigration.migratePreferences()"), "Gate precedes side effects")
        check(gate < source.index("AppDelegate()"), "Gate precedes status item creation")
        check("withExtendedLifetime(instanceLock)" in source, "Lock lives through app.run")
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
            for stream in [process.stdin, process.stdout, process.stderr]:
                stream.close()

print(f"PASS: {checks} single-instance checks ({probe})")
