// Startup-only recovery of cached turns. No history-wide polling or activity TTL.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execute = promisify(execFile);
export const RECOVERY_BYTES = 256 * 1024;
const validID = value => typeof value === 'string' && /^[a-zA-Z0-9_.:-]{1,160}$/.test(value);

export function terminalEvidence(buffer, turnIDs, skipped = false) {
  const lines = buffer.toString('utf8').split('\n');
  if (skipped) lines.shift(); // The first record may begin before the bounded tail.
  lines.pop(); // Never accept a partially written last record.
  const result = new Map();
  for (const line of lines) {
    let root; try { root = JSON.parse(line); } catch { continue; }
    const p = root?.payload;
    if (root?.type !== 'event_msg' || !turnIDs.has(p?.turn_id)) continue;
    if (p.type === 'task_started') result.delete(p.turn_id);
    if (p.type === 'task_complete' || p.type === 'turn_aborted') {
      result.set(p.turn_id, p.type === 'task_complete' ? 'completed' : 'interrupted');
    }
  }
  return result;
}

// Resolve archived sessions too, but only via a path from the read-only DB.
export function readEvidence(home, rolloutPath, turnIDs) {
  const root = fs.realpathSync(home);
  const resolved = fs.realpathSync(rolloutPath);
  if (!['sessions', 'archived_sessions'].some(dir => resolved.startsWith(path.join(root, dir) + path.sep)) ||
      !resolved.endsWith('.jsonl')) return new Map();
  const fd = fs.openSync(resolved, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) return new Map();
    const offset = Math.max(0, stat.size - RECOVERY_BYTES);
    const buffer = Buffer.alloc(Math.min(RECOVERY_BYTES, stat.size));
    const count = fs.readSync(fd, buffer, 0, buffer.length, offset);
    return terminalEvidence(buffer.subarray(0, count), turnIDs, offset > 0);
  } finally { fs.closeSync(fd); }
}

export async function recoverCachedTurns(state, options = {}) {
  const home = options.home ?? process.env.CODEX_HOME ?? path.join(os.homedir(), '.codex');
  const pending = [...state.records.values()].filter(record => ['unknown', 'stopObserved'].includes(record.phase));
  const report = { attempted: pending.length, resolved: 0, unresolved: pending.length, filesRead: 0, errors: 0 };
  if (!pending.length) return report;
  const sessions = [...new Set(pending.map(record => record.session).filter(validID))];
  const sql = `SELECT id, rollout_path FROM threads WHERE id IN (${sessions.map(id => `'${id}'`).join(',')}) LIMIT 32;`;
  let rows;
  try {
    // IDs use a restricted allowlist; no shell, writes, content output or full DB scan.
    const { stdout } = await execute('/usr/bin/sqlite3', ['-readonly', '-json', path.join(home, 'state_5.sqlite'), sql], {
      timeout: 1000, maxBuffer: 512 * 1024,
    });
    rows = stdout.trim() ? JSON.parse(stdout) : [];
    if (!Array.isArray(rows)) throw new Error('Invalid lookup result');
  } catch { report.errors += 1; return report; }
  // At most 32 bounded tails / 8 MiB per startup. Unchecked entries remain unresolved.
  for (const row of rows.slice(0, 32)) {
    const records = pending.filter(record => record.session === row.id);
    if (!records.length || typeof row.rollout_path !== 'string') continue;
    try {
      const evidence = readEvidence(home, row.rollout_path, new Set(records.map(record => record.turn)));
      report.filesRead += 1;
      for (const record of records) {
        const phase = evidence.get(record.turn);
        if (phase && state.resolveTerminal(record.session, record.turn, phase)) report.resolved += 1;
      }
    } catch { report.errors += 1; }
  }
  report.unresolved -= report.resolved;
  return report;
}
