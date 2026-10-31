import test from 'node:test'
import assert from 'node:assert/strict'

import { api, register, startTestServer } from '../test-utils/server.js'

const T0 = 1_700_000_000_000

function makeWord(id, updatedAt = T0, overrides = {}) {
  return {
    id,
    term: `term-${id}`,
    definition: `def-${id}`,
    definition2: '',
    example: '',
    note: '',
    status: 'new',
    favorite: false,
    listId: 'list-1',
    sourceLang: 'en',
    targetLang: 'zh-CN',
    listenCount: 0,
    srs: null,
    createdAt: updatedAt,
    updatedAt,
    ...overrides,
  }
}

function makeList(id, updatedAt = T0, overrides = {}) {
  return {
    id,
    name: `list-${id}`,
    sourceLang: 'en',
    targetLang: 'zh-CN',
    createdAt: updatedAt,
    updatedAt,
    ...overrides,
  }
}

function makeLog(id, wordId, at = T0, overrides = {}) {
  return { id, wordId, grade: 'good', at, intervalBefore: 1, intervalAfter: 2, ...overrides }
}

function makeSettings(updatedAt = T0, overrides = {}) {
  return {
    theme: 'system',
    uiLang: 'zh-CN',
    dailyGoal: 20,
    ttsRate: 1,
    ttsVoiceURI: '',
    autoPlayAudio: true,
    audioFirst: false,
    newCardsPerDay: 10,
    reviewOrder: 'due',
    updatedAt,
    ...overrides,
  }
}

function sync(base, token, since, changes) {
  return api(base, 'POST', '/api/sync', { token, body: { since, changes } })
}

/** 注册一个账号，再用 login 拿第二个 token 模拟「另一台设备」 */
async function registerWithSecondClient(base, email = 'sync@example.com') {
  const first = await register(base, email, 'password123')
  const login = await api(base, 'POST', '/api/auth/login', {
    body: { email, password: 'password123' },
  })
  assert.equal(login.status, 200)
  return { client1: first.token, client2: login.body.token }
}

test('推送 2 个词条 + 1 条日志：响应含这些记录且 rev 递增', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())
  const { token } = await register(srv.base)

  const res = await sync(srv.base, token, 0, {
    lists: [],
    words: [makeWord('w1'), makeWord('w2')],
    logs: [makeLog('l1', 'w1')],
    settings: null,
  })

  assert.equal(res.status, 200)
  assert.equal(res.body.rev, 3) // 2 词条 + 1 日志
  assert.equal(typeof res.body.serverTime, 'number')
  assert.deepEqual(
    res.body.changes.words.map((w) => w.id).sort(),
    ['w1', 'w2'],
  )
  assert.deepEqual(
    res.body.changes.words.map((w) => w._rev).sort((a, b) => a - b),
    [1, 2],
  )
  assert.equal(res.body.changes.logs.length, 1)
  assert.equal(res.body.changes.logs[0].id, 'l1')
  assert.equal(res.body.changes.logs[0].grade, 'good')
  assert.equal(res.body.changes.logs[0]._rev, 3)
  assert.equal(res.body.changes.lists.length, 0)
  assert.equal(res.body.changes.settings, null)

  // /api/me 的 rev 跟着更新
  const me = await api(srv.base, 'GET', '/api/me', { token })
  assert.equal(me.body.rev, 3)
})

test('增量拉取：since=上次 rev 只返回新增记录', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())
  const { token } = await register(srv.base)

  const first = await sync(srv.base, token, 0, {
    words: [makeWord('w1'), makeWord('w2')],
    logs: [makeLog('l1', 'w1')],
  })
  assert.equal(first.body.rev, 3)

  // 没有任何变更：返回空，rev 不变
  const empty = await sync(srv.base, token, 3, {})
  assert.equal(empty.body.rev, 3)
  assert.deepEqual(empty.body.changes.words, [])
  assert.deepEqual(empty.body.changes.logs, [])
  assert.deepEqual(empty.body.changes.lists, [])
  assert.equal(empty.body.changes.settings, null)

  // 再来一条：只返回新增的那条
  const third = await sync(srv.base, token, 3, { words: [makeWord('w3', T0 + 1000)] })
  assert.equal(third.body.rev, 4)
  assert.deepEqual(
    third.body.changes.words.map((w) => w.id),
    ['w3'],
  )
  assert.equal(third.body.changes.words[0]._rev, 4)
  assert.equal(third.body.changes.logs.length, 0)

  // since=0 全量
  const full = await sync(srv.base, token, 0, {})
  assert.deepEqual(
    full.body.changes.words.map((w) => w.id).sort(),
    ['w1', 'w2', 'w3'],
  )
  assert.equal(full.body.changes.logs.length, 1)
})

test('LWW：同 id 较旧 updatedAt 被丢弃，较新/相等被接受', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())
  const { token } = await register(srv.base)

  const v1 = await sync(srv.base, token, 0, {
    words: [makeWord('w1', T0 + 1000, { term: 'v1' })],
  })
  assert.equal(v1.body.rev, 1)

  // 更旧：丢弃，rev 不变，返回的仍是已存的 v1
  const stale = await sync(srv.base, token, 0, {
    words: [makeWord('w1', T0 + 500, { term: 'stale' })],
  })
  assert.equal(stale.body.rev, 1)
  assert.equal(stale.body.changes.words.length, 1)
  assert.equal(stale.body.changes.words[0].term, 'v1')
  assert.equal(stale.body.changes.words[0].updatedAt, T0 + 1000)
  assert.equal(stale.body.changes.words[0]._rev, 1)

  // 更新：接受
  const v2 = await sync(srv.base, token, 1, {
    words: [makeWord('w1', T0 + 2000, { term: 'v2' })],
  })
  assert.equal(v2.body.rev, 2)
  assert.equal(v2.body.changes.words.length, 1)
  assert.equal(v2.body.changes.words[0].term, 'v2')
  assert.equal(v2.body.changes.words[0]._rev, 2)

  // 相等 updatedAt：契约用 >=，接受
  const equal = await sync(srv.base, token, 2, {
    words: [makeWord('w1', T0 + 2000, { term: 'v2-equal' })],
  })
  assert.equal(equal.body.rev, 3)
  assert.equal(equal.body.changes.words[0].term, 'v2-equal')
  assert.equal(equal.body.changes.words[0]._rev, 3)
})

test('lists 同样按 LWW 同步', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())
  const { token } = await register(srv.base)

  const a = await sync(srv.base, token, 0, { lists: [makeList('l1', T0 + 100)] })
  assert.equal(a.body.rev, 1)
  assert.equal(a.body.changes.lists[0].name, 'list-l1')

  const stale = await sync(srv.base, token, 1, {
    lists: [makeList('l1', T0, { name: 'stale-name' })],
  })
  assert.equal(stale.body.rev, 1)
  assert.equal(stale.body.changes.lists.length, 0)

  const fresh = await sync(srv.base, token, 1, {
    lists: [makeList('l1', T0 + 200, { name: 'fresh-name' })],
  })
  assert.equal(fresh.body.rev, 2)
  assert.equal(fresh.body.changes.lists[0].name, 'fresh-name')
})

test('日志幂等：同 id 重复推送只存一条', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())
  const { token } = await register(srv.base)

  const first = await sync(srv.base, token, 0, { logs: [makeLog('l1', 'w1')] })
  assert.equal(first.body.rev, 1)

  const dup = await sync(srv.base, token, 1, { logs: [makeLog('l1', 'w1', T0 + 10)] })
  assert.equal(dup.body.rev, 1)
  assert.deepEqual(dup.body.changes.logs, [])

  const full = await sync(srv.base, token, 0, {})
  assert.equal(full.body.changes.logs.length, 1)
})

test('日志墓碑：删除后另一客户端全量拉取不再有存活日志', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())
  const { client1, client2 } = await registerWithSecondClient(srv.base)

  const pushed = await sync(srv.base, client1, 0, { logs: [makeLog('l1', 'w1')] })
  assert.equal(pushed.body.rev, 1)

  // 客户端 1 撤销评分：推送日志墓碑
  const deleted = await sync(srv.base, client1, 1, {
    logs: [{ id: 'l1', at: T0 + 500, deleted: true }],
  })
  assert.equal(deleted.body.rev, 2)
  assert.equal(deleted.body.changes.logs.length, 1)
  assert.equal(deleted.body.changes.logs[0].id, 'l1')
  assert.equal(deleted.body.changes.logs[0].deleted, true)

  // 客户端 2 从 since=0 全量拉取：不应再有存活日志；
  // 墓碑本身要返回，否则已经同步过该日志的客户端无法得知删除
  const pull = await sync(srv.base, client2, 0, {})
  const live = pull.body.changes.logs.filter((l) => l.deleted !== true)
  assert.equal(live.length, 0, '删除后不应再返回存活日志')
  const tomb = pull.body.changes.logs.find((l) => l.id === 'l1')
  assert.ok(tomb, '应返回日志墓碑用于传播删除')
  assert.equal(tomb.deleted, true)
  assert.equal(tomb._rev, 2)

  // 墓碑幂等：再推一次 rev 不涨
  const again = await sync(srv.base, client1, 2, {
    logs: [{ id: 'l1', at: T0 + 600, deleted: true }],
  })
  assert.equal(again.body.rev, 2)

  // 删除不存在的日志：忽略
  const ghost = await sync(srv.base, client1, 2, {
    logs: [{ id: 'never-existed', at: T0, deleted: true }],
  })
  assert.equal(ghost.body.rev, 2)
})

test('词条墓碑：推送 {id, deleted:true} 后另一客户端全量拉取能拿到墓碑', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())
  const { client1, client2 } = await registerWithSecondClient(srv.base)

  await sync(srv.base, client1, 0, { words: [makeWord('w1', T0)] })

  const del = await sync(srv.base, client1, 1, {
    words: [{ id: 'w1', deleted: true, updatedAt: T0 + 1000 }],
  })
  assert.equal(del.body.rev, 2)

  const pull = await sync(srv.base, client2, 0, {})
  const rec = pull.body.changes.words.find((w) => w.id === 'w1')
  assert.ok(rec, '应拿到墓碑')
  assert.equal(rec.deleted, true)
  assert.equal(rec.updatedAt, T0 + 1000)
  assert.equal(rec._rev, 2)

  // 旧墓碑被 LWW 丢弃
  const stale = await sync(srv.base, client1, 2, {
    words: [{ id: 'w1', deleted: true, updatedAt: T0 + 500 }],
  })
  assert.equal(stale.body.rev, 2)

  // 更新的正常记录可以让词条复活
  const revived = await sync(srv.base, client1, 2, {
    words: [makeWord('w1', T0 + 2000, { term: 'revived' })],
  })
  assert.equal(revived.body.rev, 3)
  assert.equal(revived.body.changes.words[0].term, 'revived')
  assert.equal(revived.body.changes.words[0].deleted, undefined)
})

test('settings 按 LWW 同步，未变时返回 null', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())
  const { token } = await register(srv.base)

  const a = await sync(srv.base, token, 0, { settings: makeSettings(T0) })
  assert.equal(a.body.rev, 1)
  assert.equal(a.body.changes.settings.updatedAt, T0)
  assert.equal(a.body.changes.settings._rev, 1)

  // 更旧：丢弃，且 since 之后无变化 → null
  const older = await sync(srv.base, token, 1, {
    settings: makeSettings(T0 - 100, { theme: 'dark' }),
  })
  assert.equal(older.body.rev, 1)
  assert.equal(older.body.changes.settings, null)

  // 更新：接受
  const newer = await sync(srv.base, token, 1, {
    settings: makeSettings(T0 + 100, { theme: 'dark' }),
  })
  assert.equal(newer.body.rev, 2)
  assert.equal(newer.body.changes.settings.theme, 'dark')
  assert.equal(newer.body.changes.settings._rev, 2)

  // since=2 时 settings 未变
  const unchanged = await sync(srv.base, token, 2, {})
  assert.equal(unchanged.body.changes.settings, null)
})

test('changes 超过 5000 条返回 400 too_many_changes 且整体不写入', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())
  const { token } = await register(srv.base)

  const words = Array.from({ length: 5001 }, (_, i) => makeWord(`w${i}`))
  const res = await sync(srv.base, token, 0, { words })
  assert.equal(res.status, 400)
  assert.deepEqual(res.body, { error: 'too_many_changes' })

  // 一条都没写进去
  const full = await sync(srv.base, token, 0, {})
  assert.equal(full.body.rev, 0)
  assert.equal(full.body.changes.words.length, 0)
})

test('畸形 changes 返回 400 bad_request', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())
  const { token } = await register(srv.base)

  const notArray = await sync(srv.base, token, 0, { words: 'nope' })
  assert.equal(notArray.status, 400)
  assert.deepEqual(notArray.body, { error: 'bad_request' })

  const missingId = await sync(srv.base, token, 0, { words: [{ term: 'no-id', updatedAt: T0 }] })
  assert.equal(missingId.status, 400)
  assert.deepEqual(missingId.body, { error: 'bad_request' })

  const missingUpdatedAt = await sync(srv.base, token, 0, { words: [{ id: 'w1' }] })
  assert.equal(missingUpdatedAt.status, 400)
  assert.deepEqual(missingUpdatedAt.body, { error: 'bad_request' })
})

test('用户数据隔离：另一个账号看不到别人的记录', async (t) => {
  const srv = await startTestServer()
  t.after(() => srv.close())

  const alice = await register(srv.base, 'alice@example.com', 'password123')
  const bob = await register(srv.base, 'bob@example.com', 'password123')

  await sync(srv.base, alice.token, 0, {
    words: [makeWord('alice-word', T0)],
    logs: [makeLog('alice-log', 'alice-word')],
  })

  const bobPull = await sync(srv.base, bob.token, 0, {})
  assert.equal(bobPull.body.rev, 0)
  assert.equal(bobPull.body.changes.words.length, 0)
  assert.equal(bobPull.body.changes.logs.length, 0)
})

test('重启后数据与令牌仍在（JSON 持久化）', async (t) => {
  const srv1 = await startTestServer()
  const { token } = await register(srv1.base, 'persist@example.com', 'password123')
  await sync(srv1.base, token, 0, {
    words: [makeWord('w1', T0)],
    logs: [makeLog('l1', 'w1')],
    settings: makeSettings(T0),
  })
  await srv1.stop() // 只停服务，保留数据目录

  // 用同一 dataDir 起一个新实例，模拟服务重启
  const srv2 = await startTestServer({ dataDir: srv1.dataDir })
  t.after(() => srv2.close())

  // 旧令牌仍有效
  const me = await api(srv2.base, 'GET', '/api/me', { token })
  assert.equal(me.status, 200)
  assert.equal(me.body.rev, 3) // 1 词条 + 1 日志 + settings

  // 记录、settings 都能读回
  const pull = await sync(srv2.base, token, 0, {})
  assert.equal(pull.body.rev, 3)
  assert.equal(pull.body.changes.words.length, 1)
  assert.equal(pull.body.changes.words[0].id, 'w1')
  assert.equal(pull.body.changes.logs.length, 1)
  assert.equal(pull.body.changes.settings.updatedAt, T0)

  // 重启后继续写：rev 从 3 递增
  const next = await sync(srv2.base, token, 3, { words: [makeWord('w2', T0 + 1)] })
  assert.equal(next.body.rev, 4)
})
