import test from 'node:test'
import assert from 'node:assert/strict'

import { startTestServer } from '../test-utils/server.js'

test('CORS 预检（OPTIONS）返回 204 且带 Access-Control-Allow-*', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())

  const res = await fetch(`${srv.base}/api/sync`, {
    method: 'OPTIONS',
    headers: {
      origin: 'http://localhost:1420',
      'access-control-request-method': 'POST',
      'access-control-request-headers': 'content-type, authorization',
    },
  })

  assert.equal(res.status, 204)
  assert.equal(res.headers.get('access-control-allow-origin'), '*')
  assert.equal(res.headers.get('access-control-allow-methods'), 'GET, POST, OPTIONS')
  assert.equal(res.headers.get('access-control-allow-headers'), 'content-type, authorization')
  assert.equal(await res.text(), '')
})

test('普通响应带 CORS 头且不设置 Cookie', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())

  const res = await fetch(`${srv.base}/api/health`, {
    headers: { origin: 'http://localhost:1420' },
  })

  assert.equal(res.status, 200)
  assert.deepEqual(await res.json(), { ok: true, version: 1 })
  assert.equal(res.headers.get('access-control-allow-origin'), '*')
  assert.equal(res.headers.get('set-cookie'), null)
  assert.equal(res.headers.get('content-type'), 'application/json; charset=utf-8')
})

test('错误响应同样是 JSON 且带 CORS 头', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())

  const res = await fetch(`${srv.base}/api/does-not-exist`)
  assert.equal(res.status, 404)
  assert.equal(res.headers.get('access-control-allow-origin'), '*')
  assert.deepEqual(await res.json(), { error: 'not_found' })
})
