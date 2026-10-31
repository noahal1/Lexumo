#!/usr/bin/env node
// Differential test: drive the same script of sync rounds against the Node
// reference server (`server/`) and the Postgres function
// (`supabase/migrations/0001_sync.sql`), then compare the response bodies.
//
// Both implementations are supposed to be the same protocol. The 12 tests in
// `server/test/sync.test.js` and the 13 in `supabase/tests/sync.sql` each
// assert against their own implementation's behaviour, so they can both be
// green while the two disagree. This script is what catches that: it is the
// only check that compares them to each other.
//
//   node supabase/tests/differential.cjs
//
// Needs: the Node server reachable, and a Postgres with the migration applied.
// `supabase/tests/differential.sh` sets both up and calls this.

const http = require('node:http');

const NODE_BASE = process.env.LEXUMO_NODE_SERVER || 'http://127.0.0.1:8787';
const PG_URL = process.env.LEXUMO_PG_URL || 'http://127.0.0.1:55433';

function post(base, path, body, token) {
  return new Promise((resolve, reject) => {
    const url = new URL(base + path);
    const data = JSON.stringify(body ?? {});
    const req = http.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname,
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'content-length': Buffer.byteLength(data),
          ...(token ? { authorization: `Bearer ${token}` } : {}),
        },
      },
      (res) => {
        let text = '';
        res.on('data', (c) => (text += c));
        res.on('end', () => {
          let json = null;
          try {
            json = JSON.parse(text);
          } catch {}
          resolve({ status: res.statusCode, body: json, text });
        });
      },
    );
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

// A deliberate script: it walks every branch of the merge rules in an order
// that makes each one observable. Timestamps are constants, not `Date.now()`,
// so both sides see identical inputs.
const T = 1700000000000;
const word = (id, updatedAt, extra = {}) => ({
  id,
  updatedAt,
  term: id,
  definition: 'd',
  deleted: false,
  ...extra,
});
const logRec = (id, at, extra = {}) => ({ id, at, wordId: 'w1', grade: 'good', ...extra });
const settings = (updatedAt, extra = {}) => ({ updatedAt, theme: 'light', ...extra });

const ROUNDS = [
  // 1. First push: two words, one list, one log, settings.
  {
    since: 0,
    changes: {
      lists: [{ id: 'list1', updatedAt: T, name: 'main' }],
      words: [word('w1', T), word('w2', T + 1)],
      logs: [logRec('l1', T + 2)],
      settings: settings(T),
    },
  },
  // 2. No changes: everything up to date.
  { since: null, changes: {} },
  // 3. Stale word: rejected.
  { since: 5, changes: { words: [word('w1', T - 100, { term: 'stale' })] } },
  // 4. Equal timestamp: accepted (the `>=` rule).
  { since: 5, changes: { words: [word('w1', T, { term: 'equal' })] } },
  // 5. Newer word: accepted.
  { since: 5, changes: { words: [word('w1', T + 50, { term: 'newer' })] } },
  // 6. Duplicate log: idempotent, no rev consumed.
  { since: 5, changes: { logs: [logRec('l1', T + 2)] } },
  // 7. Log tombstone: delete propagates.
  { since: 5, changes: { logs: [{ id: 'l1', at: T + 2, deleted: true }] } },
  // 8. Delete the same log again: no-op.
  { since: 5, changes: { logs: [{ id: 'l1', at: T + 2, deleted: true }] } },
  // 9. Word tombstone.
  { since: 5, changes: { words: [{ id: 'w2', updatedAt: T + 200, deleted: true }] } },
  // 10. Stale settings: rejected.
  { since: 5, changes: { settings: settings(T - 10, { theme: 'stale' }) } },
  // 11. Newer settings: accepted.
  { since: 5, changes: { settings: settings(T + 300, { theme: 'dark' }) } },
  // 12. Re-insert a log over its own tombstone (undo then re-grade).
  { since: 5, changes: { logs: [logRec('l1', T + 400)] } },
  // 13. Full pull from zero.
  { since: 0, changes: {} },
];

// Keys whose values legitimately differ between the two servers and must be
// excluded from the comparison.
//   serverTime — wall clock, of course.
//   _rev       — per-user sequence; identical only if both applied the same
//                number of writes in the same order, which is what we are
//                testing, so it stays IN the comparison.
function normalise(body) {
  if (!body || typeof body !== 'object') return body;
  const out = { ...body };
  delete out.serverTime;
  return out;
}

function diff(a, b, path = '') {
  const out = [];
  if (a === b) return out;
  const ta = a === null ? 'null' : Array.isArray(a) ? 'array' : typeof a;
  const tb = b === null ? 'null' : Array.isArray(b) ? 'array' : typeof b;
  if (ta !== tb) {
    out.push(`${path || '<root>'}: ${ta} vs ${tb}`);
    return out;
  }
  if (ta === 'array') {
    if (a.length !== b.length) out.push(`${path}: ${a.length} vs ${b.length} items`);
    const n = Math.min(a.length, b.length);
    for (let i = 0; i < n; i++) out.push(...diff(a[i], b[i], `${path}[${i}]`));
    return out;
  }
  if (ta === 'object') {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    for (const k of keys) {
      if (!(k in a)) out.push(`${path}.${k}: missing on node`);
      else if (!(k in b)) out.push(`${path}.${k}: missing on pg`);
      else out.push(...diff(a[k], b[k], `${path}.${k}`));
    }
    return out;
  }
  out.push(`${path}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
  return out;
}

async function main() {
  // Register a user on the Node server.
  const email = `diff-${Date.now()}-${Math.floor(Math.random() * 1e6)}@test.local`;
  const reg = await post(NODE_BASE, '/api/auth/register', { email, password: 'password123' });
  if (reg.status !== 200 && reg.status !== 201) {
    throw new Error(`register failed: ${reg.status} ${reg.text}`);
  }
  const nodeToken = reg.body.token;

  // Register a separate Postgres tenant and use its id as the JWT `sub`.
  const pgUser = await post(PG_URL, '/rest/v1/rpc/whoami', {});
  if (pgUser.status !== 200) throw new Error(`pg tenant setup failed: ${pgUser.status} ${pgUser.text}`);
  const pgToken = pgUser.body.sub;

  let sinceNode = 0;
  let sincePg = 0;
  let failures = 0;

  for (let i = 0; i < ROUNDS.length; i++) {
    const round = ROUNDS[i];
    // `since: null` means "carry forward whatever this side's last rev was",
    // so the two sides stay in the same position even after a rejected write.
    const nodeSince = round.since === null ? sinceNode : round.since;
    const pgSince = round.since === null ? sincePg : round.since;

    const a = await post(NODE_BASE, '/api/sync', { since: nodeSince, changes: round.changes }, nodeToken);
    const b = await post(PG_URL, '/rest/v1/rpc/sync', { since: pgSince, changes: round.changes }, pgToken);

    const na = normalise(a.body);
    const nb = normalise(b.body);

    if (a.status !== 200 || b.status !== 200) {
      // Both must fail the same way, with the same error code.
      const ea = a.body && a.body.error;
      const eb = b.body && (b.body.error || b.body.message);
      if (a.status !== b.status || ea !== eb) {
        failures++;
        console.log(`ROUND ${i + 1}: status differs — node ${a.status} (${ea}) vs pg ${b.status} (${eb})`);
      }
      continue;
    }

    if (na.rev !== undefined) sinceNode = na.rev;
    if (nb.rev !== undefined) sincePg = nb.rev;

    const problems = diff(na, nb);
    if (problems.length > 0) {
      failures++;
      console.log(`ROUND ${i + 1}: ${problems.length} difference(s)`);
      for (const p of problems.slice(0, 12)) console.log('  ' + p);
      if (problems.length > 12) console.log(`  ... and ${problems.length - 12} more`);
    } else {
      console.log(`ROUND ${i + 1}: identical (rev ${na.rev})`);
    }
  }

  if (failures > 0) {
    console.log(`\n${failures} of ${ROUNDS.length} rounds differ`);
    process.exit(1);
  }
  console.log(`\nall ${ROUNDS.length} rounds identical`);
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
