import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { State, sanitize, receive, send, hookConfig } from './bridge.mjs';
import { terminalEvidence, readEvidence, recoverCachedTurns, RECOVERY_BYTES } from './recovery.mjs';

const bridge = fileURLToPath(new URL('./bridge.mjs', import.meta.url));
const event = (kind, session = 'a', turn = '1') => sanitize({ hook_event_name: kind, session_id: session, turn_id: turn });
function fixture(t) {
  // Short private path also stays below macOS sockaddr_un's path limit.
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'hud-hook-'));
  fs.chmodSync(directory, 0o700);
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return path.join(directory, 'e.sock');
}
function runEmitter(socketPath, payload) {
  return new Promise((resolve, reject) => {
    const started = performance.now();
    const child = spawn(process.execPath, [bridge, 'emit', socketPath]);
    let stdout = '', stderr = '';
    child.stdout.on('data', data => { stdout += data; });
    child.stderr.on('data', data => { stderr += data; });
    child.stdin.on('error', () => {});
    child.on('error', reject);
    child.on('exit', code => resolve({ code, stdout, stderr, milliseconds: performance.now() - started }));
    child.stdin.end(payload);
  });
}
const neutral = result => {
  assert.equal(result.code, 0); assert.equal(result.stdout, '{}\n'); assert.equal(result.stderr, '');
};

test('allowlist drops all conversation and path fields', () => {
  const value = sanitize({ hook_event_name: 'UserPromptSubmit', session_id: 'a', turn_id: '1',
    prompt: 'PRIVATE', last_assistant_message: 'PRIVATE', transcript_path: '/PRIVATE', cwd: '/PRIVATE' });
  assert.deepEqual(value, { version: 1, event: 'UserPromptSubmit', session: 'a', turn: '1' });
});
test('malformed IDs, missing turn and unrelated/subagent hooks are rejected', () => {
  for (const input of [null, {}, { hook_event_name: 'Stop', session_id: 'a' },
    { hook_event_name: 'Stop', session_id: '../x', turn_id: '1' },
    { hook_event_name: 'SubagentStop', session_id: 'a', turn_id: '1' },
    { hook_event_name: 'PostToolUse', session_id: 'a', turn_id: '1' }]) assert.equal(sanitize(input), null);
});
test('cold start explicitly has incomplete coverage, not authoritative idle', () => {
  assert.equal(new State().summary().authoritativeIdle, false);
  assert.equal(new State().summary().coverage, 'partial');
});
test('two sessions are two candidates; duplicate submission does not inflate count', () => {
  const s = new State();
  s.apply(event('UserPromptSubmit')); s.apply(event('UserPromptSubmit', 'b'));
  s.apply(event('UserPromptSubmit'));
  assert.equal(s.summary().submittedCandidates, 2);
  assert.equal(s.summary().authoritativeRunningCount, null);
});
test('multiple turns in one session count once', () => {
  const s = new State();
  s.apply(event('UserPromptSubmit')); s.apply(event('UserPromptSubmit', 'a', '2'));
  assert.equal(s.summary().submittedCandidates, 1);
  s.apply(event('Stop', 'a', '2'));
  assert.equal(s.summary().submittedCandidates, 0);
  assert.equal(s.summary().unknown, 1); // Old turn never received an end.
});
test('long silence alone does not invent a completion', () => {
  const s = new State(); s.apply(event('UserPromptSubmit'), 0);
  assert.equal(s.summary().submittedCandidates, 1);
  assert.equal(s.snapshot().records[0].observedAt, 0);
});
test('Stop is provisional, not a successful task completion', () => {
  const s = new State(); s.apply(event('UserPromptSubmit')); s.apply(event('Stop'));
  assert.equal(s.summary().submittedCandidates, 0);
  assert.equal(s.summary().stopObserved, 1);
  assert.equal(s.summary().authoritativeIdle, false);
});
test('late submission cannot resurrect stopped turn; new turn can continue', () => {
  const s = new State(); s.apply(event('Stop')); s.apply(event('UserPromptSubmit'));
  assert.equal(s.summary().submittedCandidates, 0);
  s.apply(event('UserPromptSubmit', 'a', '2'));
  assert.equal(s.summary().submittedCandidates, 1);
});
test('old turn Stop does not cancel a newer turn', () => {
  const s = new State(); s.apply(event('UserPromptSubmit', 'a', '2')); s.apply(event('Stop'));
  assert.equal(s.summary().submittedCandidates, 1);
});
test('interrupt applies to its turn and dominates late Stop', () => {
  const s = new State(); s.apply(event('UserPromptSubmit')); s.apply(event('UserPromptSubmit', 'b'));
  s.apply(event('Interrupt')); s.apply(event('Stop'));
  assert.equal(s.summary().submittedCandidates, 1);
  assert.equal(s.summary().interrupted, 1);
});
test('session end is unknown, not proof of task completion', () => {
  const s = new State(); s.apply(event('UserPromptSubmit')); s.apply(event('SessionEnd'));
  assert.equal(s.summary().submittedCandidates, 0); assert.equal(s.summary().unknown, 1);
});
test('restored unfinished turns become unknown; observed terminal facts survive', () => {
  const s = new State(); s.apply(event('UserPromptSubmit')); s.apply(event('Stop', 'b'));
  const restored = new State(s.snapshot());
  assert.equal(restored.summary().submittedCandidates, 0);
  assert.equal(restored.summary().unknown, 1); assert.equal(restored.summary().stopObserved, 1);
  assert.equal(restored.summary().health, 'restartGap');
});
test('corrupt cache does not turn into idle', () => {
  for (const value of [null, {}, { version: 1, records: [null, { session: '../x', turn: '1', phase: 'submitted' }] }]) {
    assert.equal(new State(value).summary().authoritativeIdle, false);
  }
});
test('bounded cache signals capacity loss', () => {
  const s = new State();
  for (let i = 0; i < 600; i++) s.apply(event('UserPromptSubmit', `session-${i}`));
  assert.equal(s.records.size, 512); assert.equal(s.summary().health, 'capacityGap');
});
test('generated config is short-timeout, non-async and never overrides trust', () => {
  const config = hookConfig('/tmp/test/e.sock');
  assert.equal(Object.keys(config.hooks).length, 4);
  for (const entries of Object.values(config.hooks)) {
    assert.equal(entries[0].hooks[0].timeout, 1);
    assert.equal(entries[0].hooks[0].async, undefined);
  }
  assert.equal(JSON.stringify(config).includes('bypass'), false);
});
test('bounded event evidence retains submit/stop order without conversation content', () => {
  const s = new State(); s.apply(event('UserPromptSubmit'), 100); s.apply(event('Stop'), 200);
  assert.deepEqual(s.snapshot().eventHistory.map(item => [item.event, item.receivedAt]),
    [['UserPromptSubmit', 100], ['Stop', 200]]);
  const snapshot = s.snapshot(); snapshot.eventHistory[0].prompt = 'PRIVATE';
  const restored = new State(snapshot);
  assert.equal(restored.eventHistory.length, 2);
  assert.equal(JSON.stringify(restored.snapshot()).includes('PRIVATE'), false);
  assert.equal(restored.summary().unknown, 0);
  assert.equal(restored.summary().stopObserved, 1); // Stop observation is not success.
  assert.equal(restored.summary().authoritativeIdle, false);
  for (let i = 0; i < 200; i++) s.apply(event('Stop', `history-${i}`));
  assert.equal(s.eventHistory.length, 128);
});
test('real socket: concurrent deliveries persist only metadata and recover conservatively', async t => {
  const socketPath = fixture(t);
  const receiver = await receive(socketPath);
  try {
    assert.deepEqual(await Promise.all([send(socketPath, event('UserPromptSubmit')), send(socketPath, event('UserPromptSubmit', 'b'))]), [true, true]);
    assert.equal(receiver.state.summary().submittedCandidates, 2);
    const output = await runEmitter(socketPath, JSON.stringify({ hook_event_name: 'Stop', session_id: 'a', turn_id: '1', last_assistant_message: 'PRIVATE' }));
    neutral(output);
    const cache = fs.readFileSync(receiver.snapshotPath, 'utf8');
    assert.equal(cache.includes('PRIVATE'), false);
    assert.equal(fs.statSync(receiver.snapshotPath).mode & 0o777, 0o600);
    assert.equal(receiver.state.summary().submittedCandidates, 1);
  } finally { await new Promise(resolve => receiver.server.close(resolve)); }
  const restarted = await receive(socketPath);
  try {
    assert.equal(restarted.state.summary().unknown, 1);
    assert.equal(restarted.state.summary().stopObserved, 1);
    assert.equal(restarted.state.summary().submittedCandidates, 0);
  } finally { await new Promise(resolve => restarted.server.close(resolve)); }
});
test('missing receiver, malformed or oversized input are neutral and bounded', async t => {
  const socketPath = fixture(t);
  const timings = [];
  for (const payload of ['invalid json', 'x'.repeat(1024 * 1024 + 1),
    JSON.stringify({ hook_event_name: 'UserPromptSubmit', session_id: 'a', turn_id: '1', prompt: 'PRIVATE' })]) {
    const result = await runEmitter(socketPath, payload); neutral(result); timings.push(result.milliseconds);
    assert.ok(result.milliseconds < 2000, 'generous CI bound; not a production latency target');
  }
  t.diagnostic(`emitter subprocess elapsed ms: ${timings.map(v => v.toFixed(1)).join(', ')}`);
});
test('hung receiver cannot hang hook indefinitely', async t => {
  const socketPath = fixture(t);
  const connections = new Set();
  const server = net.createServer(socket => { connections.add(socket); socket.on('close', () => connections.delete(socket)); });
  await new Promise(resolve => server.listen(socketPath, resolve));
  try {
    const result = await runEmitter(socketPath, JSON.stringify({ hook_event_name: 'Stop', session_id: 'a', turn_id: '1' }));
    neutral(result); assert.ok(result.milliseconds < 2000);
    t.diagnostic(`hung receiver fail-open elapsed ms: ${result.milliseconds.toFixed(1)}`);
  } finally {
    for (const socket of connections) socket.destroy();
    await new Promise(resolve => server.close(resolve));
  }
});
test('receiver refuses public directory and existing socket without deleting it', async t => {
  const socketPath = fixture(t);
  fs.chmodSync(path.dirname(socketPath), 0o755);
  await assert.rejects(receive(socketPath), /0700/);
  fs.chmodSync(path.dirname(socketPath), 0o700);
  const receiver = await receive(socketPath);
  try { await assert.rejects(receive(socketPath), /already exists/); }
  finally { await new Promise(resolve => receiver.server.close(resolve)); }
});

const logLine = (type, turn = '1') => JSON.stringify({ type: 'event_msg', timestamp: '2026-09-16T12:00:00Z',
  payload: { type, turn_id: turn, last_agent_message: 'PRIVATE' } }) + '\n';
function recoveryFixture(t) {
  const socketPath = fixture(t);
  const home = path.dirname(socketPath);
  const sessions = path.join(home, 'sessions');
  fs.mkdirSync(sessions);
  const rollout = path.join(sessions, 'test.jsonl');
  const db = path.join(home, 'state_5.sqlite');
  execFileSync('/usr/bin/sqlite3', [db, 'CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT);']);
  const addRow = (id, file) => execFileSync('/usr/bin/sqlite3', [db,
    `INSERT INTO threads VALUES('${id.replaceAll("'", "''")}','${file.replaceAll("'", "''")}');`]);
  addRow('a', rollout);
  return { home, rollout, socketPath, addRow };
}
const unknownState = () => {
  const s = new State(); s.apply(event('UserPromptSubmit')); return new State(s.snapshot());
};
test('terminal recovery matches exact turn and rejects unrelated/partial lines', () => {
  assert.equal(terminalEvidence(Buffer.from(logLine('task_complete', 'other')), new Set(['1'])).size, 0);
  assert.equal(terminalEvidence(Buffer.from(logLine('task_complete').trimEnd()), new Set(['1'])).size, 0);
  assert.equal(terminalEvidence(Buffer.from(logLine('task_complete')), new Set(['1']), true).size, 0);
  assert.equal(terminalEvidence(Buffer.from(logLine('task_complete') + logLine('task_started')), new Set(['1'])).size, 0);
  assert.equal(terminalEvidence(Buffer.from(logLine('turn_aborted')), new Set(['1'])).get('1'), 'interrupted');
});
test('completed cache stays completed through repeated restarts and session end', () => {
  let s = unknownState(); assert.equal(s.resolveTerminal('a', '1', 'completed'), true);
  for (let i = 0; i < 3; i++) s = new State(s.snapshot());
  s.apply(event('SessionEnd')); s.apply(event('Stop')); s.apply(event('UserPromptSubmit'));
  assert.equal(s.summary().confirmedCompleted, 1); assert.equal(s.summary().unknown, 0);
  assert.equal(s.summary().submittedCandidates, 0); assert.equal(s.summary().authoritativeIdle, false);
});
test('interrupt survives restart/session end; a different new turn still runs', () => {
  let s = new State(); s.apply(event('Interrupt')); s = new State(s.snapshot());
  s.apply(event('SessionEnd'));
  assert.equal(s.summary().interrupted, 1); assert.equal(s.summary().unknown, 0);
  s.apply(event('UserPromptSubmit', 'a', '2'));
  assert.equal(s.summary().submittedCandidates, 1);
  assert.equal(s.resolveTerminal('a', '2', 'completed'), false); // Do not clobber live work.
});
test('read-only recovery repairs exact cached turn without synthetic Hook events', async t => {
  const { home, rollout } = recoveryFixture(t);
  fs.writeFileSync(rollout, logLine('task_started') + logLine('task_complete'));
  const s = unknownState(); const history = JSON.stringify(s.eventHistory);
  const result = await recoverCachedTurns(s, { home });
  assert.equal(result.resolved, 1); assert.equal(result.unresolved, 0);
  assert.equal(s.summary().unknown, 0); assert.equal(s.summary().confirmedCompleted, 1);
  assert.equal(JSON.stringify(s.eventHistory), history);
  assert.equal(JSON.stringify(s.snapshot()).includes('PRIVATE'), false);
});
test('missing DB, missing rollout or unmatched turn preserve unknown', async t => {
  const { home, rollout } = recoveryFixture(t);
  for (const mode of ['missingFile', 'otherTurn', 'runningOnly', 'missingDB']) {
    if (mode === 'otherTurn') fs.writeFileSync(rollout, logLine('task_complete', 'other'));
    if (mode === 'runningOnly') fs.writeFileSync(rollout, logLine('task_started'));
    const s = unknownState();
    const r = await recoverCachedTurns(s, { home: mode === 'missingDB' ? path.join(home, 'absent') : home });
    assert.equal(r.resolved, 0); assert.equal(s.summary().unknown, 1);
  }
});
test('bounded tail can repair a large rollout without reading conversation history', t => {
  const { home, rollout } = recoveryFixture(t);
  fs.writeFileSync(rollout, 'x'.repeat(RECOVERY_BYTES * 2) + '\n' + logLine('task_complete'));
  assert.equal(readEvidence(home, rollout, new Set(['1'])).get('1'), 'completed');
});
test('recovery refuses outside roots and symlink escape', t => {
  const { home, rollout } = recoveryFixture(t);
  const outside = path.join(home, 'outside.jsonl');
  fs.writeFileSync(outside, logLine('task_complete'));
  assert.equal(readEvidence(home, outside, new Set(['1'])).size, 0);
  fs.symlinkSync(outside, rollout);
  assert.equal(readEvidence(home, rollout, new Set(['1'])).size, 0);
});
test('startup recovery repairs cache; subsequent restart needs no log lookup for completed turns', async t => {
  const { home, rollout, socketPath } = recoveryFixture(t);
  fs.writeFileSync(rollout, logLine('task_complete'));
  fs.writeFileSync(path.join(home, 'snapshot.json'), JSON.stringify(unknownState().snapshot()));
  let receiver = await receive(socketPath, { home });
  try {
    assert.equal(receiver.state.summary().unknown, 0);
    assert.equal(receiver.state.recovery.resolved, 1);
    assert.equal(receiver.state.summary().health, 'cacheRecovered');
  } finally { await new Promise(resolve => receiver.server.close(resolve)); }
  receiver = await receive(socketPath, { home: path.join(home, 'missing') });
  try {
    assert.equal(receiver.state.summary().unknown, 0);
    assert.equal(receiver.state.recovery.attempted, 0);
    assert.equal(receiver.state.summary().confirmedCompleted, 1);
  } finally { await new Promise(resolve => receiver.server.close(resolve)); }
});
test('startup I/O cap leaves excess cached tasks unresolved rather than guessing', async t => {
  const { home, rollout, addRow } = recoveryFixture(t);
  fs.writeFileSync(rollout, logLine('task_complete'));
  const s = new State();
  for (let i = 0; i < 35; i++) {
    addRow(`task-${i}`, rollout); s.apply(event('UserPromptSubmit', `task-${i}`));
  }
  const restored = new State(s.snapshot());
  const result = await recoverCachedTurns(restored, { home });
  assert.equal(result.filesRead, 32); assert.equal(result.resolved, 32);
  assert.equal(result.unresolved, 3); assert.equal(restored.summary().unknown, 3);
});
