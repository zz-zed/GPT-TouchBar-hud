#!/usr/bin/env python3
"""Isolated process-level budget/privacy checks. No host or global configuration is used."""
import json, os, pathlib, select, socket, statistics, subprocess, tempfile, time

root = pathlib.Path(__file__).resolve().parents[1]
helper = root / 'build/GPT TouchBar HUD.app/Contents/Helpers/HookEmitter'
assert helper.is_file(), 'Build the signed app first'

def run(sock, payload, *, slow=False):
    start = time.monotonic()
    process = subprocess.Popen([str(helper), 'emit', '--owner=gpt-touchbar-hud-v1', '--socket', str(sock)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if slow:
        process.stdin.write(b'{'); process.stdin.flush()
        assert select.select([process.stdout], [], [], 1.5)[0], 'Watchdog did not return'
        output = os.read(process.stdout.fileno(), 16)
        process.wait(timeout=.2)
        process.stdin.close(); process.stdin = None
        remaining, error = process.communicate(timeout=1)
        output += remaining
    else:
        output, error = process.communicate(payload, timeout=1.5)
    elapsed = time.monotonic() - start
    assert process.returncode == 0 and output == b'{}\n' and not error, (process.returncode, output, error)
    # Includes OS process launch: allow 150 ms scheduling overhead over the 500 ms in-process budget.
    assert elapsed < .65, elapsed
    return elapsed

with tempfile.TemporaryDirectory(prefix='hud-helper-', dir='/private/tmp') as temporary:
    directory = pathlib.Path(temporary); os.chmod(directory, 0o700)
    sock = directory / 'events.sock'
    event = json.dumps(dict(hook_event_name='Stop', session_id='s', turn_id='t',
                           prompt='PRIVATE_PROMPT', last_assistant_message='PRIVATE_REPLY')).encode()
    timings = [run(sock, event) for _ in range(20)]
    malformed = run(sock, b'{bad')
    oversized = run(sock, b'x' * (1024 * 1024 + 1))
    slow = run(sock, b'', slow=True)
    oversized_file = directory / 'oversized-input'
    oversized_file.write_bytes(b'x' * (1024 * 1024 + 8192))
    with oversized_file.open('rb', buffering=0) as stream:
        checked = subprocess.run([str(helper), 'emit', '--owner=gpt-touchbar-hud-v1', '--socket', str(sock)], stdin=stream, capture_output=True, timeout=1)
        assert stream.tell() <= 1024 * 1024, 'Helper read beyond the stdin budget'
        assert checked.returncode == 0 and checked.stdout == b'{}\n' and not checked.stderr
    server = socket.socket(socket.AF_UNIX); server.bind(str(sock)); os.chmod(sock, 0o600); server.listen(4)
    unresponsive = run(sock, event)
    connection, _ = server.accept()
    wire = connection.recv(8192)
    assert len(wire) <= 4096 and b'PRIVATE' not in wire and b'prompt' not in wire and b'last_assistant' not in wire
    assert json.loads(wire)['kind'] == 'Stop'
    connection.close(); server.close()
    result = dict(samples=len(timings), absent_ms_median=round(statistics.median(timings)*1000, 2),
                  absent_ms_p95=round(sorted(timings)[18]*1000, 2), malformed_ms=round(malformed*1000,2),
                  oversized_ms=round(oversized*1000,2), slow_stdin_ms=round(slow*1000,2),
                  no_ack_ms=round(unresponsive*1000,2), wire_bytes=len(wire), neutral_exit_checks=25)
    print(json.dumps(result, indent=2))
