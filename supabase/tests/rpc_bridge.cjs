#!/usr/bin/env node
// A tiny stand-in for PostgREST, so `differential.cjs` can talk to the SQL
// function over HTTP exactly as the app would.
//
// It speaks the RPC endpoints the differential test needs:
//   POST /rest/v1/rpc/sync     { since, changes }  → the function's return value
//   POST /rest/v1/rpc/whoami   {}                  → { sub: <a fresh user uuid> }
//
// ...and enough of GoTrue for the Dart client to run against it in
// `flutter/test/supabase_e2e_test.dart`:
//   GET  /auth/v1/health
//   POST /auth/v1/signup                            { email, password }
//   POST /auth/v1/token?grant_type=password         { email, password }
//   POST /auth/v1/token?grant_type=refresh_token    { refresh_token }
//   POST /auth/v1/logout
//
// Sessions are in memory and die with the process; that is enough for a test
// that starts the bridge, runs, and stops it. `access-<uuid>` doubles as the
// bearer token the sync call forwards, so `auth.uid()` sees the same user
// through both halves.
//
// Deliberately not part of the product: Supabase provides this layer in
// production (`supabase.rpc('sync', ...)`), and adding a Node Postgres driver
// just to test would be a dependency the test itself could hide behind. Calls
// go through `docker exec psql`, so what runs is the same SQL the migration
// installs.
//
//   node supabase/tests/rpc_bridge.cjs            # listens on 55433
//   CONTAINER=lexumo-pg PORT=55433 node ...
const http = require('node:http');
const { execFileSync } = require('node:child_process');

const CONTAINER = process.env.CONTAINER || 'lexumo-pg';
const PORT = Number(process.env.PORT || 55433);
const DB = process.env.PGDATABASE || 'lexumo';
const DBUSER = process.env.PGUSER || 'postgres';

function psql(sql) {
  const out = execFileSync(
    'docker',
    ['exec', '-i', CONTAINER, 'psql', '-U', DBUSER, '-d', DB, '-v', 'ON_ERROR_STOP=1', '-t', '-A', '-q', '-f', '-'],
    { input: sql, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
  );
  return out.trim();
}

// Quote a JS string for a SQL literal. The values here come from a test
// script, not from users, but building SQL by hand is exactly where a "just
// this once" turns into an injection, so escape properly anyway.
function lit(value) {
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'number') return String(value);
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  return "'" + String(value).replace(/'/g, "''") + "'";
}

function jsonLit(value) {
  return lit(JSON.stringify(value)) + '::jsonb';
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (err) {
        reject(err);
      }
    });
    req.on('error', reject);
  });
}

// The app sends `Authorization: Bearer <supabase access token>`. Real Supabase
// would verify the JWT; here the token *is* the user uuid, and `whoami` hands
// one out. `auth.uid()` reads the `request.jwt.claim.sub` GUC, so each request
// sets it in the same session as the function call.
// access token → user id. `access-<uuid>` comes from sign-in here; a bare
// uuid is what the differential test sends, so both are accepted.
const sessions = new Map();
const passwords = new Map();

function userFromToken(req) {
  const header = req.headers.authorization || '';
  const m = /^Bearer\s+(.+)$/.exec(header);
  if (!m) return null;
  const token = m[1];
  const known = sessions.get(token);
  if (known) return known;
  if (token.startsWith('access-')) return null;
  return token;
}

function emailTaken(email) {
  const out = psql(
    `select count(*) from auth.users where email = ${lit(email)};`,
  );
  return Number(out) > 0;
}

function mintSession(userId, email) {
  const access = 'access-' + userId;
  const refresh = 'refresh-' + userId;
  sessions.set(access, userId);
  return {
    access_token: access,
    token_type: 'bearer',
    expires_in: 3600,
    refresh_token: refresh,
    user: { id: userId, email },
  };
}

function respond(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
  res.end(text);
}

const server = http.createServer(async (req, res) => {
  if (req.method !== 'POST' && !(req.method === 'GET' && req.url === '/auth/v1/health')) {
    return respond(res, 405, { error: 'method_not_allowed' });
  }

  const body = await readBody(req);

  try {
    if (req.url === '/auth/v1/health') {
      return respond(res, 200, { name: 'GoTrue', version: 'test' });
    }

    if (req.url === '/auth/v1/signup' && req.method === 'POST') {
      const email = String(body.email || '');
      const password = String(body.password || '');
      if (!email.includes('@')) {
        return respond(res, 400, {
          code: 400,
          error_code: 'validation_failed',
          msg: 'Unable to validate email address: invalid format',
        });
      }
      if (password.length < 8) {
        return respond(res, 422, { code: 422, error_code: 'weak_password' });
      }
      if (emailTaken(email)) {
        return respond(res, 409, { code: 409, error_code: 'user_already_exists' });
      }
      const id = psql(
        `insert into auth.users (email) values (${lit(email)}) returning id;`,
      );
      passwords.set(email, password);
      return respond(res, 200, mintSession(id, email));
    }

    if (req.url === '/auth/v1/token?grant_type=password') {
      const email = String(body.email || '');
      const id = psql(`select id from auth.users where email = ${lit(email)};`) || '';
      const password = String(body.password || '');
      // Same answer for "no such user" and "wrong password", like GoTrue: a
      // different message for each is an account-enumeration oracle.
      if (!id || passwords.get(email) !== password) {
        return respond(res, 400, {
          code: 400,
          error_code: 'invalid_grant',
          msg: 'Invalid login credentials',
        });
      }
      return respond(res, 200, mintSession(id, email));
    }

    if (req.url === '/auth/v1/token?grant_type=refresh_token') {
      const refresh = String(body.refresh_token || '');
      const userId = refresh.startsWith('refresh-') ? refresh.slice(8) : '';
      if (!userId) {
        return respond(res, 400, { code: 400, error_code: 'invalid_grant' });
      }
      const email = psql(`select email from auth.users where id = ${lit(userId)};`);
      if (!email) {
        return respond(res, 400, { code: 400, error_code: 'invalid_grant' });
      }
      return respond(res, 200, mintSession(userId, email));
    }

    if (req.url === '/auth/v1/logout') {
      const header = req.headers.authorization || '';
      const m = /^Bearer\s+(.+)$/.exec(header);
      if (m) sessions.delete(m[1]);
      return respond(res, 204, {});
    }

    if (req.url === '/rest/v1/rpc/whoami') {
      const id = psql(
        `insert into auth.users (email) values ('bridge-' || gen_random_uuid() || '@test.local') returning id;`,
      );
      return respond(res, 200, { sub: id });
    }

    if (req.url === '/rest/v1/rpc/sync') {
      const uid = userFromToken(req);
      if (!uid) return respond(res, 401, { error: 'unauthorized' });

      const since = body.since === undefined || body.since === null ? 'null' : String(Number(body.since) || 0);
      const sql = [
        `select set_config('request.jwt.claim.sub', ${lit(uid)}, false);`,
        `select public.sync(${since}::bigint, ${jsonLit(body.changes ?? {})})::text;`,
      ].join('\n');

      const raw = psql(sql);
      // The first statement returns the GUC; the payload is the last line.
      const lines = raw.split('\n').filter(Boolean);
      const payload = lines[lines.length - 1];
      return respond(res, 200, JSON.parse(payload));
    }

    return respond(res, 404, { error: 'not_found' });
  } catch (err) {
    // Translate the plpgsql `raise exception 'code'` into PostgREST's shape,
    // which is what the client (`SyncError.fromCode`) reads.
    const text = String(err.message || err);
    const match = /(bad_request|too_many_changes|unauthorized)/.exec(text);
    const code = match ? match[1] : 'server';
    const status = code === 'unauthorized' ? 401 : 400;
    return respond(res, status, { error: code, message: text.split('\n')[0] });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`rpc bridge on http://127.0.0.1:${PORT} → docker exec ${CONTAINER}`);
});
