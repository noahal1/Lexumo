import test from 'node:test'
import assert from 'node:assert/strict'

import { api, register, startTestServer } from '../test-utils/server.js'

test('注册 → 登录 → /api/me', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())

  // 注册：邮箱被 trim + 小写，返回 token/email/rev=0
  const reg = await api(srv.base, 'POST', '/api/auth/register', {
    body: { email: '  Alice@Example.COM ', password: 'password123' },
  })
  assert.equal(reg.status, 200)
  assert.equal(reg.body.email, 'alice@example.com')
  assert.equal(reg.body.rev, 0)
  assert.equal(typeof reg.body.token, 'string')
  assert.equal(reg.body.token.length, 64) // 32 字节 hex

  // /api/me
  const me = await api(srv.base, 'GET', '/api/me', { token: reg.body.token })
  assert.equal(me.status, 200)
  assert.deepEqual(me.body, { email: 'alice@example.com', rev: 0 })

  // 登录：拿到新 token，rev 仍是 0
  const login = await api(srv.base, 'POST', '/api/auth/login', {
    body: { email: 'alice@example.com', password: 'password123' },
  })
  assert.equal(login.status, 200)
  assert.equal(login.body.email, 'alice@example.com')
  assert.equal(login.body.rev, 0)
  assert.equal(typeof login.body.token, 'string')
  assert.notEqual(login.body.token, reg.body.token)

  const me2 = await api(srv.base, 'GET', '/api/me', { token: login.body.token })
  assert.equal(me2.status, 200)
  assert.deepEqual(me2.body, { email: 'alice@example.com', rev: 0 })
})

test('重复邮箱注册返回 409 email_taken（大小写/空格归一）', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())

  await register(srv.base, 'dup@example.com', 'password123')
  const second = await api(srv.base, 'POST', '/api/auth/register', {
    body: { email: ' DUP@Example.com ', password: 'password123' },
  })
  assert.equal(second.status, 409)
  assert.deepEqual(second.body, { error: 'email_taken' })
})

test('弱密码 / 非法邮箱返回 400', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())

  const weak = await api(srv.base, 'POST', '/api/auth/register', {
    body: { email: 'weak@example.com', password: '1234567' }, // 7 字符
  })
  assert.equal(weak.status, 400)
  assert.deepEqual(weak.body, { error: 'weak_password' })

  const emptyPassword = await api(srv.base, 'POST', '/api/auth/register', {
    body: { email: 'weak2@example.com', password: '' },
  })
  assert.equal(emptyPassword.status, 400)
  assert.deepEqual(emptyPassword.body, { error: 'weak_password' })

  for (const email of ['not-an-email', 'a@b', 'a@@b.com', '', '  ']) {
    const res = await api(srv.base, 'POST', '/api/auth/register', {
      body: { email, password: 'password123' },
    })
    assert.equal(res.status, 400, `邮箱 ${JSON.stringify(email)} 应被拒绝`)
    assert.deepEqual(res.body, { error: 'invalid_email' })
  }
})

test('错误密码 / 不存在的邮箱都返回 401 bad_credentials', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())

  await register(srv.base, 'bob@example.com', 'password123')

  const wrong = await api(srv.base, 'POST', '/api/auth/login', {
    body: { email: 'bob@example.com', password: 'wrong-password' },
  })
  assert.equal(wrong.status, 401)
  assert.deepEqual(wrong.body, { error: 'bad_credentials' })

  const unknown = await api(srv.base, 'POST', '/api/auth/login', {
    body: { email: 'nobody@example.com', password: 'password123' },
  })
  assert.equal(unknown.status, 401)
  assert.deepEqual(unknown.body, { error: 'bad_credentials' })
})

test('无令牌 / 无效令牌访问受保护端点返回 401 unauthorized', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())

  const noToken = await api(srv.base, 'POST', '/api/sync', { body: { since: 0, changes: {} } })
  assert.equal(noToken.status, 401)
  assert.deepEqual(noToken.body, { error: 'unauthorized' })

  const badToken = await api(srv.base, 'GET', '/api/me', { token: 'deadbeef'.repeat(8) })
  assert.equal(badToken.status, 401)
  assert.deepEqual(badToken.body, { error: 'unauthorized' })

  const badScheme = await api(srv.base, 'GET', '/api/me', { headers: { authorization: 'Basic abc' } })
  assert.equal(badScheme.status, 401)
  assert.deepEqual(badScheme.body, { error: 'unauthorized' })
})

test('logout 作废令牌', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())

  const { token } = await register(srv.base, 'carol@example.com', 'password123')

  const logout = await api(srv.base, 'POST', '/api/auth/logout', { token })
  assert.equal(logout.status, 204)
  assert.equal(logout.body, null) // 204 无 body

  const me = await api(srv.base, 'GET', '/api/me', { token })
  assert.equal(me.status, 401)
  assert.deepEqual(me.body, { error: 'unauthorized' })
})

test('非法 JSON / 非对象 body 返回 400 bad_request', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())

  const bad = await api(srv.base, 'POST', '/api/auth/register', { rawBody: '{"email":' })
  assert.equal(bad.status, 400)
  assert.deepEqual(bad.body, { error: 'bad_request' })

  const arr = await api(srv.base, 'POST', '/api/auth/register', { rawBody: '[]' })
  assert.equal(arr.status, 400)
  assert.deepEqual(arr.body, { error: 'bad_request' })
})

test('未知路由返回 404 not_found（JSON）', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())

  const res = await api(srv.base, 'GET', '/api/nope')
  assert.equal(res.status, 404)
  assert.deepEqual(res.body, { error: 'not_found' })
})
