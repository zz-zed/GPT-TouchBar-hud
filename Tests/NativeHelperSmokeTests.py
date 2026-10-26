#!/usr/bin/env python3
"""Exercise the packaged native Helper; isolated Unix IPC, no host/user config."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

helper = Path(sys.argv[1]).resolve(strict=True)
if not helper.is_file() or not os.access(helper, os.X_OK):
    raise SystemExit("Build the native App/Helper before --smoke")


def invoke(arguments, payload):
    result = subprocess.run([str(helper), *arguments], input=payload,
                            capture_output=True, timeout=3)
    assert (result.returncode, result.stdout, result.stderr) == (0, b"{}\n", b""), result


with tempfile.TemporaryDirectory(prefix="hud-core-helper-", dir="/private/tmp") as temporary:
    directory = Path(temporary)
    directory.chmod(0o700)
    endpoint = directory / "events.sock"
    arguments = ["emit", "--owner=gpt-touchbar-hud-v1", "--socket", str(endpoint)]
    event = json.dumps({"hook_event_name": "Stop", "session_id": "core-smoke", "turn_id": "one",
                        "prompt": "PRIVATE_PROMPT", "last_assistant_message": "PRIVATE_REPLY"}).encode()
    invoke([], b"")
    invoke(arguments, event)  # No listener must be a harmless no-op.
    invoke(arguments, b"{bad")
    invoke(arguments, b"x" * (1024 * 1024 + 1))
    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(endpoint))
        endpoint.chmod(0o600)
        server.listen(1)
        server.settimeout(3)
        # Intentionally no acknowledgment: the Helper must finish on its own.
        invoke(arguments, event)
        connection, _ = server.accept()
        with connection:
            connection.settimeout(3)
            chunks = []
            while sum(map(len, chunks)) <= 4096:
                chunk = connection.recv(4097)
                if not chunk:
                    break
                chunks.append(chunk)
            wire = b"".join(chunks)
        assert len(wire) <= 4096 and json.loads(wire)["kind"] == "Stop"
        assert b"PRIVATE" not in wire and b"prompt" not in wire and b"last_assistant" not in wire
    process = subprocess.Popen([str(helper), *arguments], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        process.stdin.write(b"{")
        process.stdin.flush()
        process.wait(timeout=3)  # Incomplete stdin must not hang a host Hook.
        process.stdin.close()
        process.stdin = None
        output, error = process.communicate(timeout=1)
        assert (process.returncode, output, error) == (0, b"{}\n", b"")
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        if process.stdin is not None:
            process.stdin.close()
        process.stdout.close()
        process.stderr.close()

print("PASS: packaged Helper executes natively, bounds input/waits, emits private-safe IPC and exits neutrally")
