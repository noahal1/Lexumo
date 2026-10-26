/**
 * Lexumo 同步服务 HTTP 入口（零第三方依赖，node:http 手写路由）。
 *
 * 端点（详见 docs/sync-protocol.md）：
 *   GET  /api/health
 *   POST /api/auth/register
 *   POST /api/auth/login
 *   POST /api/auth/logout
 *   GET  /api/me
 *   POST /api/sync
 *
 * 启动：node src/index.js（或 cd server && npm start）
 * 环境变量：PORT（默认 8787）、HOST（默认 127.0.0.1）、DATA_DIR（默认 <server>/data）
 */
import { createServer } from 'node:http'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

import {
  hashPassword,
  isValidEmail,
  isValidPassword,
  normalizeEmail,
  verifyPassword,
} from './auth.js'
import { Store, SyncError } from './store.js'

const HERE = dirname(fileURLToPath(import.meta.url))
const MAX_BODY_BYTES = 8 * 1024 * 1024 // 契约：请求体上限 8 MB

/** 带 HTTP 状态码的业务错误，code 即响应里的 error 字符串 */
class HttpError extends Error {
  constructor(status, code) {
    super(code)
    this.name = 'HttpError'
    this.status = status
    this.code = code
  }
}

/**
 * 创建 HTTP 服务（不自动 listen，方便测试用随机端口）。
 * @param {{ dataDir?: string, store?: Store }} [options]
 */
export function createApp({ dataDir, store } = {}) {
  const resolvedDataDir = dataDir ? resolve(dataDir) : defaultDataDir()
  const storeInstance = store ?? new Store({ dataDir: resolvedDataDir })

  const server = createServer((req, res) => {
    // 所有响应（含错误、预检）都带 CORS 头；不使用 Cookie
    setCorsHeaders(res)

    // 预检直接 204，无需鉴权
    if (req.method === 'OPTIONS') {
      res.writeHead(204)
      res.end()
      return
    }

    route(req, res, storeInstance).catch((err) => {
      if (err instanceof HttpError) {
        sendJson(res, err.status, { error: err.code })
        return
      }
      if (err instanceof SyncError) {
        sendJson(res, 400, { error: err.code })
        return
      }
      console.error('[lexumo-sync] 未处理的错误:', err)
      if (!res.headersSent) sendJson(res, 500, { error: 'internal_error' })
      else res.end()
    })
  })

  return { server, store: storeInstance, dataDir: resolvedDataDir }
}

/** 启动服务（读取环境变量） */
export function startServer() {
  const port = Number(process.env.PORT || 8787)
  const host = process.env.HOST || '127.0.0.1'
  const dataDir = process.env.DATA_DIR ? resolve(process.env.DATA_DIR) : defaultDataDir()

  const { server } = createApp({ dataDir })

  server.listen(port, host, () => {
    console.log(`[lexumo-sync] listening on http://${host}:${port}`)
    console.log(`[lexumo-sync] data dir: ${dataDir}`)
  })

  // 收到终止信号时优雅关闭
  const shutdown = () => {
    console.log('[lexumo-sync] shutting down…')
    server.close(() => process.exit(0))
    server.closeAllConnections?.()
  }
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)

  return server
}

// ------------------------------------------------------------------ 路由

async function route(req, res, store) {
  const url = new URL(req.url || '/', 'http://localhost')
  const pathname = normalizePath(url.pathname)
  const method = req.method || 'GET'

  if (pathname === '/api/health') {
    if (method !== 'GET') throw new HttpError(405, 'method_not_allowed')
    return sendJson(res, 200, { ok: true, version: 1 })
  }

  if (pathname === '/api/auth/register') {
    if (method !== 'POST') throw new HttpError(405, 'method_not_allowed')
    return handleRegister(req, res, store)
  }

  if (pathname === '/api/auth/login') {
    if (method !== 'POST') throw new HttpError(405, 'method_not_allowed')
    return handleLogin(req, res, store)
  }

  if (pathname === '/api/auth/logout') {
    if (method !== 'POST') throw new HttpError(405, 'method_not_allowed')
    return handleLogout(req, res, store)
  }

  if (pathname === '/api/me') {
    if (method !== 'GET') throw new HttpError(405, 'method_not_allowed')
    return handleMe(req, res, store)
  }

  if (pathname === '/api/sync') {
    if (method !== 'POST') throw new HttpError(405, 'method_not_allowed')
    return handleSync(req, res, store)
  }

  throw new HttpError(404, 'not_found')
}

async function handleRegister(req, res, store) {
  const body = await readJsonObject(req)
  const email = normalizeEmail(body.email)
  if (!isValidEmail(email)) throw new HttpError(400, 'invalid_email')
  if (!isValidPassword(body.password)) throw new HttpError(400, 'weak_password')

  const { salt, hash } = hashPassword(body.password)
  const user = store.createUser(email, salt, hash)
  if (!user) throw new HttpError(409, 'email_taken')

  const token = store.createToken(user.id)
  sendJson(res, 200, { token, email: user.email, rev: 0 })
}

async function handleLogin(req, res, store) {
  const body = await readJsonObject(req)
  const email = normalizeEmail(body.email)
  const user = store.findUserByEmail(email)
  if (!verifyPassword(body.password, user)) throw new HttpError(401, 'bad_credentials')

  const token = store.createToken(user.id)
  sendJson(res, 200, { token, email: user.email, rev: store.getRev(user.id) })
}

async function handleLogout(req, res, store) {
  const { token } = requireAuth(req, store)
  store.deleteToken(token)
  res.writeHead(204)
  res.end()
}

async function handleMe(req, res, store) {
  const { user } = requireAuth(req, store)
  sendJson(res, 200, { email: user.email, rev: store.getRev(user.id) })
}

async function handleSync(req, res, store) {
  const { user } = requireAuth(req, store)
  const body = await readJsonObject(req)
  // 先应用后返回；store 内部已按 since 过滤并附带 _rev
  const result = store.applySync(user.id, body.since, body.changes)
  sendJson(res, 200, result)
}

// ------------------------------------------------------------------ 鉴权

/** 解析 Authorization: Bearer <token> 并校验令牌，失败抛 401 unauthorized */
function requireAuth(req, store) {
  const header = req.headers.authorization
  const match = typeof header === 'string' ? /^Bearer\s+(\S+)$/i.exec(header.trim()) : null
  const token = match ? match[1] : null
  const userId = token ? store.getTokenUserId(token) : null
  const user = userId ? store.getUserById(userId) : null
  if (!token || !user) throw new HttpError(401, 'unauthorized')
  return { user, token }
}

// ------------------------------------------------------------------ HTTP 工具

function setCorsHeaders(res) {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
  res.setHeader('Access-Control-Allow-Headers', 'content-type, authorization')
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
  })
  res.end(payload)
}

/** 读取请求体（上限 8 MB），超过则 413 payload_too_large */
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    let tooLarge = false

    req.on('data', (chunk) => {
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        tooLarge = true
        chunks.length = 0
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      if (tooLarge) reject(new HttpError(413, 'payload_too_large'))
      else resolve(Buffer.concat(chunks))
    })
    req.on('error', () => reject(new HttpError(400, 'bad_request')))
  })
}

/** 读取并解析 JSON 对象；空体视为 {}，非法 JSON 或非对象 → 400 bad_request */
async function readJsonObject(req) {
  const raw = await readBody(req)
  if (raw.length === 0) return {}
  let parsed
  try {
    parsed = JSON.parse(raw.toString('utf8'))
  } catch {
    throw new HttpError(400, 'bad_request')
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new HttpError(400, 'bad_request')
  }
  return parsed
}

function normalizePath(pathname) {
  if (pathname.length > 1 && pathname.endsWith('/')) return pathname.replace(/\/+$/, '') || '/'
  return pathname
}

function defaultDataDir() {
  // 默认 <server>/data，与启动时的 cwd 无关
  return join(HERE, '..', 'data')
}

// 仅当直接运行 `node src/index.js` 时启动，被 import 时只导出工厂函数
const entryHref = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : null
if (entryHref === import.meta.url) startServer()
