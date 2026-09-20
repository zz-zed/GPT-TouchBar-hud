#!/usr/bin/env python3
"""Discovery-only probe in a temporary CODEX_HOME; no trust, task, model or global config writes."""
import json, os, pathlib, select, subprocess, sys, tempfile, time
runtime = sys.argv[1] if len(sys.argv) > 1 else '/Applications/ChatGPT.app/Contents/Resources/codex'
with tempfile.TemporaryDirectory(prefix='hud-discovery-', dir='/private/tmp') as temporary:
    base = pathlib.Path(temporary); os.chmod(base, 0o700)
    config = {'hooks': {event: [{'hooks': [{'type': 'command', 'command': "'/nonexistent/HookEmitter' 'emit' '--owner=gpt-touchbar-hud-v1' '--socket' '/nonexistent/events.sock'", 'timeout': 1}]}]
                        for event in ['UserPromptSubmit', 'Stop', 'Interrupt', 'SessionEnd']}}
    hooks = base / 'hooks.json'; hooks.write_text(json.dumps(config)); hooks.chmod(0o600)
    env = dict(os.environ); env['CODEX_HOME'] = str(base)
    process = subprocess.Popen([runtime, 'app-server', '--listen', 'stdio://'], cwd=base, env=env,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    def send(value):
        process.stdin.write((json.dumps(value)+'\n').encode()); process.stdin.flush()
    send({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name':'hud_hook_discovery','version':'1'}, 'capabilities':{'experimentalApi':True}}})
    buffer = b''; deadline = time.monotonic() + 8; report = None
    try:
        while time.monotonic() < deadline and report is None:
            if not select.select([process.stdout], [], [], .2)[0]: continue
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk: break
            buffer += chunk; assert len(buffer) < 2*1024*1024
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                response = json.loads(line)
                if response.get('id') == 1:
                    assert not response.get('error'), response.get('error')
                    send({'method':'initialized'})
                    send({'id':2,'method':'hooks/list','params':{'cwds':[str(base)]}})
                if response.get('id') == 2:
                    assert not response.get('error'), response.get('error')
                    entries = response['result']['data']
                    found = [hook for entry in entries for hook in entry['hooks']]
                    report = {'runtime': subprocess.check_output([runtime,'--version'], text=True).strip(),
                              'scope':'isolated discovery only', 'hooks_executed':False, 'trust_written':False,
                              'discovered':[{key:hook.get(key) for key in ['eventName','enabled','trustStatus','timeoutSec','async']} for hook in found],
                              'errors':sum(len(entry['errors']) for entry in entries)}
                    assert len(found)==4 and report['errors']==0
        assert report is not None, 'Discovery timed out'
        print(json.dumps(report, indent=2))
    finally:
        process.stdin.close(); process.terminate()
        try: process.wait(timeout=2)
        except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=2)
