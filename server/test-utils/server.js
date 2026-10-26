/**
 * 测试辅助：每个测试启动一个独立的服务实例（独立 DATA_DIR 临时目录 + 随机端口），
 * 跑完关闭服务并清理临时目录，保证测试之间互不影响、可并发。
 */
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { createApp } from '../src/index.js'

export async function startTestServer({ dataDir: existingDir } = {}) {
  const dataDir = existingDir ?? (await mkdtemp(join(tmpdir(), 'lexumo-sync-test-')))
  const { server, store } = createApp({ dataDir })

  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', resolve)
  })

  const { port } = server.address()
  const base = `http://127.0.0.1:${port}`

  const stop = () =>
    new Promise((resolve) => {
      server.close(resolve)
      server.closeAllConnections?.()
    })

  return {
    base,
    dataDir,
    store,
    /** 只关服务，保留数据目录（用于模拟重启） */
    stop,
    /** 关服务并清理数据目录 */
    async close() {
      await stop()
      await rm(dataDir, { recursive: true, force: true })
    },
  }
}

/**
 * 发一个 HTTP 请求并解析 JSON 响应。
 * body 为对象时自动 JSON 序列化；rawBody 用于发送非法 JSON 等原始内容。
 */
export async function api(base, method, path, { token, body, rawBody, headers } = {}) {
  const finalHeaders = { ...headers }
  let payload
  if (rawBody !== undefined) {
    payload = rawBody
    finalHeaders['content-type'] ??= 'application/json'
  } else if (body !== undefined) {
    payload = JSON.stringify(body)
    finalHeaders['content-type'] ??= 'application/json'
  }
  if (token) finalHeaders.authorization = `Bearer ${token}`

  const res = await fetch(base + path, { method, headers: finalHeaders, body: payload })
  const text = await res.text()
  let parsed = null
  if (text) {
    try {
      parsed = JSON.parse(text)
    } catch {
      parsed = text
    }
  }
  return { status: res.status, headers: res.headers, body: parsed }
}

/** 注册并返回 { token, email, rev } */
export async function register(base, email = 'user@example.com', password = 'password123') {
  const res = await api(base, 'POST', '/api/auth/register', { body: { email, password } })
  assert.equal(res.status, 200, `注册应成功，实际 ${res.status}: ${JSON.stringify(res.body)}`)
  return res.body
}
