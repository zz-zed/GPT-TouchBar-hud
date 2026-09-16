// Reads hook discovery from a separate instance of the installed runtime.
// No threads, model calls, trust writes, global config writes, or trust bypass.
import { spawn } from 'node:child_process';
import { hookConfig } from './bridge.mjs';

const project = process.argv.includes('--project');
const executable = process.argv.slice(2).find(arg => arg !== '--project') || '/Applications/ChatGPT.app/Contents/Resources/codex';
const config = hookConfig('/tmp/gpt-hud-probe-not-installed/events.sock');
const args = project ? [] : Object.entries(config.hooks).flatMap(([name, value]) => [
  '-c', `hooks.${name}=[{hooks=[{type="command",command=${JSON.stringify(value[0].hooks[0].command)},timeout=1}]}]`,
]);
const child = spawn(executable, [...args, 'app-server', '--listen', 'stdio://'], { stdio: ['pipe', 'pipe', 'ignore'] });
const deadline = setTimeout(() => finish(1, { error: 'hooks/list timed out' }), 10000);
let buffer = '', finished = false;
function finish(code, result) {
  if (finished) return;
  finished = true;
  clearTimeout(deadline);
  if (result) console.log(JSON.stringify(result, null, 2));
  child.stdin.destroy(); child.kill(); process.exitCode = code;
}
function send(value) { child.stdin.write(JSON.stringify(value) + '\n'); }
child.on('error', () => finish(1, { error: 'Cannot start runtime' }));
child.on('exit', () => { if (!finished) finish(1, { error: 'Runtime exited before discovery' }); });
child.stdin.on('error', () => finish(1, { error: 'Runtime input closed' }));
child.stdout.on('data', chunk => {
  buffer += chunk;
  if (buffer.length > 2 * 1024 * 1024) { finish(1, { error: 'Response exceeded probe bound' }); return; }
  let end;
  while ((end = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
    let message; try { message = JSON.parse(line); } catch { continue; }
    if (message.id === 1) {
      if (message.error) { finish(1, { error: 'initialize failed' }); return; }
      send({ method: 'initialized' });
      send({ id: 2, method: 'hooks/list', params: { cwds: [process.cwd()] } });
    }
    if (message.id === 2) {
      if (message.error) { finish(1, { error: 'hooks/list failed' }); return; }
      const entries = message.result?.data || [];
      const discovered = entries.flatMap(entry => entry.hooks || []).filter(hook => hook.source === (project ? 'project' : 'sessionFlags'));
      finish(discovered.length === 4 ? 0 : 1, {
        scope: project ? 'project-config-discovery-only' : 'isolated-runtime-discovery-only', hooksExecuted: false, configWrittenByProbe: false,
        discovered: discovered.map(hook => ({ event: hook.eventName, enabled: hook.enabled,
          trust: hook.trustStatus, timeoutSeconds: hook.timeoutSec, async: hook.async })),
        errors: entries.reduce((count, entry) => count + entry.errors.length, 0),
      });
    }
  }
});
send({ id: 1, method: 'initialize', params: {
  clientInfo: { name: 'gpt_hud_hook_probe', version: '0.1' }, capabilities: { experimentalApi: true },
} });
