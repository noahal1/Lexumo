/**
 * Lexumo 同步服务存储层（零第三方依赖，Node 24 内置模块）。
 *
 * 存储布局（DATA_DIR 下）：
 *   users.json            邮箱 → 用户（scrypt 的 salt / hash，绝不存明文密码）
 *   tokens.json           token → { userId, expiresAt }
 *   records/<userId>.json 该用户的 rev、lists/words/logs 记录与 settings
 *
 * 写入策略：内存缓存 + 「写临时文件 → rename」的原子替换。
 * 单进程、单线程、同步执行，因此一次 /api/sync 的「读-改-写」不会被其它请求交错，
 * 天然满足「先应用后返回」的原子性。
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'

import { TOKEN_TTL_MS, createTokenValue } from './auth.js'

/** 契约：changes 单次最多 5000 条记录 */
export const MAX_CHANGES_PER_SYNC = 5000

const KINDS = ['lists', 'words', 'logs']

/** 存储层业务错误，code 直接作为 HTTP 响应里的 error 字符串 */
export class SyncError extends Error {
  constructor(code) {
    super(code)
    this.name = 'SyncError'
    this.code = code
  }
}

export class Store {
  constructor({ dataDir }) {
    this.dataDir = dataDir
    this.recordsDir = join(dataDir, 'records')
    mkdirSync(this.recordsDir, { recursive: true })

    this.usersFile = join(dataDir, 'users.json')
    this.tokensFile = join(dataDir, 'tokens.json')

    this.usersByEmail = new Map(Object.entries(readJson(this.usersFile, {})))
    this.usersById = new Map()
    for (const user of this.usersByEmail.values()) this.usersById.set(user.id, user)

    this.tokens = new Map(Object.entries(readJson(this.tokensFile, {})))
    this.userDataCache = new Map()

    this.#pruneExpiredTokens()
  }

  // ---------------------------------------------------------------- 用户

  /** 创建用户；邮箱已存在返回 null（由调用方转成 409 email_taken） */
  createUser(email, salt, passwordHash) {
    if (this.usersByEmail.has(email)) return null
    const user = { id: randomUUID(), email, salt, passwordHash, createdAt: Date.now() }
    this.usersByEmail.set(email, user)
    this.usersById.set(user.id, user)
    this.#persistUsers()
    return user
  }

  findUserByEmail(email) {
    return this.usersByEmail.get(email) ?? null
  }

  getUserById(id) {
    return this.usersById.get(id) ?? null
  }

  // ---------------------------------------------------------------- 令牌

  createToken(userId) {
    const token = createTokenValue()
    this.tokens.set(token, { userId, expiresAt: Date.now() + TOKEN_TTL_MS })
    this.#persistTokens()
    return token
  }

  /** 返回 token 对应的 userId；不存在或已过期返回 null */
  getTokenUserId(token) {
    const entry = this.tokens.get(token)
    if (!entry) return null
    if (!(entry.expiresAt > Date.now())) {
      this.tokens.delete(token)
      this.#persistTokens()
      return null
    }
    return entry.userId
  }

  /** 作废令牌（logout） */
  deleteToken(token) {
    if (this.tokens.delete(token)) this.#persistTokens()
  }

  // ---------------------------------------------------------------- 同步

  /** 该用户当前的全局 rev */
  getRev(userId) {
    return this.#userData(userId).rev
  }

  /**
   * 应用一次同步请求，返回契约规定的响应体。
   * 顺序：先校验 → 逐条应用（分配递增 rev）→ 返回 since 之后的所有记录（含本次写入）。
   */
  applySync(userId, since, changes) {
    const data = this.#userData(userId)
    const sinceRev = normalizeSince(since)
    const patch = normalizeChanges(changes) // 非法结构在这里抛 SyncError(bad_request)

    let dirty = false

    // words / lists：LWW，incoming.updatedAt >= stored.updatedAt 才覆盖；墓碑一视同仁
    const applyLww = (kind, record) => {
      const bucket = data.records[kind]
      const stored = bucket.get(record.id)
      if (stored && !(record.updatedAt >= stored.payload.updatedAt)) return false
      bucket.set(record.id, { rev: ++data.rev, payload: record })
      return true
    }

    for (const record of patch.lists) if (applyLww('lists', record)) dirty = true
    for (const record of patch.words) if (applyLww('words', record)) dirty = true

    // logs：只追加、按 id 去重；另支持日志墓碑（撤销评分）用于传播删除
    for (const record of patch.logs) {
      const bucket = data.records.logs
      const stored = bucket.get(record.id)
      if (record.deleted === true) {
        // 删除存活日志并保留墓碑，让删除能通过增量同步传播；不存在或已是墓碑则忽略
        if (!stored || stored.payload.deleted === true) continue
        bucket.set(record.id, { rev: ++data.rev, payload: { ...record, deleted: true } })
        dirty = true
      } else {
        // 正常日志：已存在（且不是墓碑）则忽略；若此前是墓碑，则视为新记录重新插入
        if (stored && stored.payload.deleted !== true) continue
        bucket.set(record.id, { rev: ++data.rev, payload: record })
        dirty = true
      }
    }

    // settings：LWW
    if (patch.settings) {
      const stored = data.settings
      if (!stored || patch.settings.updatedAt >= stored.payload.updatedAt) {
        data.settings = { rev: ++data.rev, payload: patch.settings }
        dirty = true
      }
    }

    if (dirty) this.#persistUserData(userId, data)

    // 返回 rev > since 的所有记录；settings 为 null 表示该区间内未变
    return {
      rev: data.rev,
      serverTime: Date.now(),
      changes: {
        lists: collectSince(data.records.lists, sinceRev),
        words: collectSince(data.records.words, sinceRev),
        logs: collectSince(data.records.logs, sinceRev),
        settings:
          data.settings && data.settings.rev > sinceRev
            ? { ...data.settings.payload, _rev: data.settings.rev }
            : null,
      },
    }
  }

  // ---------------------------------------------------------------- 内部

  #dataFile(userId) {
    return join(this.recordsDir, `${userId}.json`)
  }

  #userData(userId) {
    const cached = this.userDataCache.get(userId)
    if (cached) return cached

    const raw = readJson(this.#dataFile(userId), null)
    const data = {
      rev: Number.isInteger(raw?.rev) && raw.rev >= 0 ? raw.rev : 0,
      records: { lists: new Map(), words: new Map(), logs: new Map() },
      settings:
        isPlainObject(raw?.settings) && isPlainObject(raw.settings.payload)
          ? { rev: Number(raw.settings.rev) || 0, payload: raw.settings.payload }
          : null,
    }

    for (const kind of KINDS) {
      const bucket = raw?.records?.[kind]
      if (!isPlainObject(bucket)) continue
      for (const [id, entry] of Object.entries(bucket)) {
        if (!isPlainObject(entry) || !isPlainObject(entry.payload)) continue
        data.records[kind].set(id, { rev: Number(entry.rev) || 0, payload: entry.payload })
      }
    }

    this.userDataCache.set(userId, data)
    return data
  }

  #persistUserData(userId, data) {
    const records = {}
    for (const kind of KINDS) records[kind] = Object.fromEntries(data.records[kind])
    writeJsonAtomic(this.#dataFile(userId), {
      rev: data.rev,
      records,
      settings: data.settings
        ? { rev: data.settings.rev, payload: data.settings.payload }
        : null,
    })
  }

  #persistUsers() {
    writeJsonAtomic(this.usersFile, Object.fromEntries(this.usersByEmail))
  }

  #persistTokens() {
    writeJsonAtomic(this.tokensFile, Object.fromEntries(this.tokens))
  }

  #pruneExpiredTokens() {
    const now = Date.now()
    let changed = false
    for (const [token, entry] of this.tokens) {
      if (!(entry.expiresAt > now)) {
        this.tokens.delete(token)
        changed = true
      }
    }
    if (changed) this.#persistTokens()
  }
}

// ------------------------------------------------------------------ 工具函数

function isPlainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function readJson(file, fallback) {
  if (!existsSync(file)) return fallback
  try {
    return JSON.parse(readFileSync(file, 'utf8'))
  } catch (err) {
    throw new Error(`数据文件损坏，无法解析 ${file}: ${err.message}`)
  }
}

/** 原子写：先写临时文件再 rename，避免进程中断留下半个 JSON */
function writeJsonAtomic(file, value) {
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`
  writeFileSync(tmp, JSON.stringify(value), 'utf8')
  renameSync(tmp, file)
}

/** since 规范化：非数字 / 负数都按 0 处理（0 = 全量拉取） */
function normalizeSince(value) {
  const n = Number(value)
  if (!Number.isFinite(n) || n <= 0) return 0
  return Math.floor(n)
}

/**
 * 校验并规范化 changes。
 * 契约外的畸形输入统一 400 bad_request；条目数超过 5000 为 too_many_changes。
 * 全部校验在应用之前完成，保证请求要么整体生效要么整体不生效。
 */
function normalizeChanges(changes) {
  if (changes === undefined || changes === null) {
    return { lists: [], words: [], logs: [], settings: null }
  }
  if (!isPlainObject(changes)) throw new SyncError('bad_request')

  const lists = validateRecordArray(changes.lists, 'lists')
  const words = validateRecordArray(changes.words, 'words')
  const logs = validateRecordArray(changes.logs, 'logs')
  const settings = validateSettings(changes.settings)

  if (lists.length + words.length + logs.length > MAX_CHANGES_PER_SYNC) {
    throw new SyncError('too_many_changes')
  }
  return { lists, words, logs, settings }
}

function validateRecordArray(value, kind) {
  if (value === undefined || value === null) return []
  if (!Array.isArray(value)) throw new SyncError('bad_request')

  for (const item of value) {
    if (!isPlainObject(item)) throw new SyncError('bad_request')
    if (typeof item.id !== 'string' || item.id.length === 0 || item.id.length > 200) {
      throw new SyncError('bad_request')
    }
    // words / lists 依赖 updatedAt 做 LWW；logs 只按 id 去重（墓碑带 at）
    if (kind !== 'logs' && (typeof item.updatedAt !== 'number' || !Number.isFinite(item.updatedAt))) {
      throw new SyncError('bad_request')
    }
  }
  return value
}

function validateSettings(value) {
  if (value === undefined || value === null) return null
  if (!isPlainObject(value)) throw new SyncError('bad_request')
  if (typeof value.updatedAt !== 'number' || !Number.isFinite(value.updatedAt)) {
    throw new SyncError('bad_request')
  }
  return value
}

/** 收集 rev > sinceRev 的记录，按 rev 升序返回，并附上调试用 _rev */
function collectSince(bucket, sinceRev) {
  const out = []
  for (const entry of bucket.values()) {
    if (entry.rev > sinceRev) out.push({ ...entry.payload, _rev: entry.rev })
  }
  out.sort((a, b) => a._rev - b._rev)
  return out
}
