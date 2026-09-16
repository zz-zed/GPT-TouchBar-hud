// Isolated feasibility probe. Not imported by, or installed into, the HUD.
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { recoverCachedTurns } from './recovery.mjs';

const events = new Set(['UserPromptSubmit', 'Stop', 'Interrupt', 'SessionEnd']);
const idOK = value => typeof value === 'string' && /^[a-zA-Z0-9_.:-]{1,160}$/.test(value);
const phases = new Set(['submitted', 'stopObserved', 'interrupted', 'unknown', 'completed']);
const MAX_RECORDS = 512;
const MAX_INPUT = 1024 * 1024;

// Explicit allowlist: never forward prompt, output, cwd, transcript, or tool input.
export function sanitize(input) {
  if (!input || !events.has(input.hook_event_name) || !idOK(input.session_id)) return null;
  if (input.hook_event_name !== 'SessionEnd' && !idOK(input.turn_id)) return null;
  return {
    version: 1, event: input.hook_event_name, session: input.session_id,
    turn: input.hook_event_name === 'SessionEnd' ? null : input.turn_id,
  };
}

export class State {
  constructor(snapshot) {
    this.records = new Map();
    this.coverage = 'partial'; // Hooks cannot enumerate already-running tasks.
    this.health = 'awaitingEvents';
    this.revision = 0;
    this.eventHistory = [];
    this.recovery = null;
    if (snapshot?.version !== 1 || !Array.isArray(snapshot.records)) return;
    for (const item of (Array.isArray(snapshot.eventHistory) ? snapshot.eventHistory : []).slice(-128)) {
      const clean = sanitize({ hook_event_name: item?.event, session_id: item?.session, turn_id: item?.turn });
      if (clean && Number.isSafeInteger(item.receivedAt) && item.receivedAt >= 0) {
        this.eventHistory.push({ ...clean, receivedAt: item.receivedAt });
      }
    }
    for (const record of snapshot.records.slice(-MAX_RECORDS)) {
      if (!idOK(record?.session) || !idOK(record?.turn) || !phases.has(record?.phase)) continue;
      // Preserve terminal facts for this exact turn. Unfinished work needs fresh evidence.
      this.records.set(JSON.stringify([record.session, record.turn]), {
        session: record.session, turn: record.turn,
        phase: record.phase === 'submitted' ? 'unknown' : record.phase,
        observedAt: Number.isSafeInteger(record.observedAt) ? record.observedAt : null,
      });
    }
    if (this.records.size) this.health = 'restartGap';
  }

  apply(wire, now = Date.now()) {
    const event = sanitize({ hook_event_name: wire?.event, session_id: wire?.session, turn_id: wire?.turn });
    if (wire?.version !== 1 || !event) return false;
    if (event.event === 'SessionEnd') {
      for (const record of this.records.values()) {
        if (record.session === event.session && ['submitted', 'unknown'].includes(record.phase)) {
          record.phase = 'unknown'; record.observedAt = now;
        }
      }
      // Ending a session is not proof all its execution has stopped.
      this.health = 'sessionEnded';
    } else {
      const key = JSON.stringify([event.session, event.turn]);
      const previous = this.records.get(key);
      if (previous?.phase === 'completed') return false;
      // Late/duplicate submission must not resurrect a terminal observation.
      if (event.event === 'UserPromptSubmit' && previous && previous.phase !== 'unknown') return false;
      if (event.event === 'UserPromptSubmit') {
        for (const record of this.records.values()) {
          if (record.session === event.session && record.turn !== event.turn && record.phase === 'submitted') {
            // Missing end event: do not leave the previous turn "running" forever.
            record.phase = 'unknown';
          }
        }
      }
      let phase = { UserPromptSubmit: 'submitted', Stop: 'stopObserved', Interrupt: 'interrupted' }[event.event];
      if (previous?.phase === 'interrupted' && event.event === 'Stop') return false;
      this.records.set(key, { session: event.session, turn: event.turn, phase, observedAt: now });
      this.health = 'receiving';
    }
    if (this.records.size > MAX_RECORDS) {
      this.records.delete(this.records.keys().next().value);
      this.health = 'capacityGap';
    }
    this.revision += 1;
    this.eventHistory.push({ ...event, receivedAt: now });
    if (this.eventHistory.length > 128) this.eventHistory.shift();
    return true;
  }

  summary() {
    // One user-visible session counts once, even if multiple turns were observed.
    const sessions = new Map();
    const rank = { completed: -1, interrupted: 0, stopObserved: 1, unknown: 2, submitted: 3 };
    for (const record of this.records.values()) {
      if (!sessions.has(record.session) || rank[record.phase] > rank[sessions.get(record.session)]) {
        sessions.set(record.session, record.phase);
      }
    }
    const count = phase => [...sessions.values()].filter(value => value === phase).length;
    return {
      coverage: this.coverage, health: this.health,
      submittedCandidates: count('submitted'), stopObserved: count('stopObserved'),
      interrupted: count('interrupted'), unknown: count('unknown'),
      confirmedCompleted: count('completed'),
      // A prompt can be blocked by another hook. Stop can trigger continuation.
      authoritativeRunningCount: null, authoritativeIdle: false,
    };
  }

  snapshot() {
    return { version: 1, revision: this.revision, summary: this.summary(), records: [...this.records.values()], eventHistory: this.eventHistory, recovery: this.recovery };
  }

  resolveTerminal(session, turn, phase) {
    if (!['completed', 'interrupted'].includes(phase)) return false;
    const record = this.records.get(JSON.stringify([session, turn]));
    if (!record || !['unknown', 'stopObserved'].includes(record.phase)) return false;
    record.phase = phase;
    this.revision += 1;
    // Recovered evidence is not a newly received Hook. Do not invent eventHistory.
    return true;
  }
}

function privateDirectory(socketPath) {
  if (!path.isAbsolute(socketPath) || Buffer.byteLength(socketPath) > 100) throw new Error('Use a short absolute socket path');
  const stat = fs.lstatSync(path.dirname(socketPath));
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid() || (stat.mode & 0o077)) {
    throw new Error('Socket directory must be owned by this user, with mode 0700');
  }
}

export async function receive(socketPath, options = {}) {
  privateDirectory(socketPath);
  // Never unlink an existing socket: it may belong to another active receiver.
  if (fs.existsSync(socketPath)) throw new Error('Socket already exists; use a new private directory');
  const snapshotPath = path.join(path.dirname(socketPath), 'snapshot.json');
  let previous;
  try {
    const stat = fs.lstatSync(snapshotPath);
    if (stat.isFile() && !stat.isSymbolicLink() && stat.size <= MAX_INPUT) previous = JSON.parse(fs.readFileSync(snapshotPath, 'utf8'));
  } catch { /* Missing/corrupt cache does not prove idle. */ }
  const state = new State(previous);
  // Run before accepting Hook traffic so recovery cannot overwrite newer live events.
  state.recovery = await recoverCachedTurns(state, options);
  if (state.records.size) {
    state.health = state.recovery.unresolved ? 'recoveryIncomplete' : 'cacheRecovered';
  }
  function persist() {
    const temporary = `${snapshotPath}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(state.snapshot()), { mode: 0o600, flag: 'wx' });
    fs.renameSync(temporary, snapshotPath);
  }
  persist();
  const server = net.createServer(socket => {
    socket.setTimeout(200, () => socket.destroy());
    socket.on('error', () => {});
    let buffer = '';
    socket.on('data', chunk => {
      buffer += chunk.toString('utf8');
      if (Buffer.byteLength(buffer) > 2048) { socket.destroy(); return; }
      const end = buffer.indexOf('\n');
      if (end < 0) return;
      try {
        const event = JSON.parse(buffer.slice(0, end));
        if (state.apply(event)) persist();
        socket.end('ok\n');
      } catch { socket.destroy(); }
      socket.removeAllListeners('data');
    });
  });
  server.maxConnections = 16;
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(socketPath, () => { fs.chmodSync(socketPath, 0o600); resolve(); });
  });
  return { server, state, snapshotPath };
}

export function send(socketPath, event) {
  return new Promise(resolve => {
    let socket;
    const finish = value => { clearTimeout(deadline); socket?.destroy(); resolve(value); };
    const deadline = setTimeout(() => finish(false), 200);
    try {
      privateDirectory(socketPath);
      const stat = fs.lstatSync(socketPath);
      if (!stat.isSocket() || stat.uid !== process.getuid()) { finish(false); return; }
      socket = net.createConnection(socketPath);
      socket.on('connect', () => socket.write(JSON.stringify(event) + '\n'));
      socket.on('data', data => finish(data.toString().startsWith('ok')));
      socket.on('error', () => finish(false));
      socket.on('close', () => finish(false));
    } catch { finish(false); }
  });
}

const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
export function hookConfig(socketPath) {
  const command = [process.execPath, fileURLToPath(import.meta.url), 'emit', socketPath].map(quote).join(' ');
  // Synchronous, bounded delivery avoids avoidable reordering from async hooks.
  return { hooks: Object.fromEntries([...events].map(event => [event, [{ hooks: [{ type: 'command', command, timeout: 1 }] }]])) };
}

async function emit(socketPath) {
  // Neutral output for every hook, including Stop; no prompt injection or veto.
  const deadline = setTimeout(() => { process.stdout.write('{}\n'); process.exit(0); }, 500);
  try {
    let size = 0;
    const chunks = [];
    for await (const chunk of process.stdin) {
      size += chunk.length;
      if (size > MAX_INPUT) break;
      chunks.push(chunk);
    }
    if (size <= MAX_INPUT) {
      const event = sanitize(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      if (event) await send(socketPath, event);
    }
  } catch { /* Fail open: observer errors must not affect the task. */ }
  clearTimeout(deadline);
  process.stdout.write('{}\n');
  process.exit(0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [mode, socketPath] = process.argv.slice(2);
  if (mode === 'emit') await emit(socketPath);
  else if (mode === 'config') console.log(JSON.stringify(hookConfig(socketPath), null, 2));
  else if (mode === 'receive') {
    const { server, snapshotPath } = await receive(socketPath);
    console.log(JSON.stringify({ receiverPID: process.pid, socketPath, snapshotPath }));
    const close = () => server.close(() => process.exit(0));
    process.once('SIGTERM', close); process.once('SIGINT', close);
  } else throw new Error('Usage: node bridge.mjs receive|emit|config /private/directory/events.sock');
}
