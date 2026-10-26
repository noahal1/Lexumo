/**
 * 密码与令牌工具。
 *
 * - 密码：scrypt + 每个用户随机 16 字节 salt，只存 salt 与派生哈希，绝不存明文。
 * - 令牌：32 字节随机数的 hex（64 字符），opaque token，有效期 30 天。
 */
import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto'

export const TOKEN_TTL_MS = 30 * 24 * 60 * 60 * 1000 // 30 天
export const PASSWORD_MIN_LENGTH = 8
export const PASSWORD_MAX_LENGTH = 1024 // 防御性上限，避免超长密码拖慢 scrypt

const HASH_BYTES = 64
const SALT_BYTES = 16
// 用户不存在时用它跑一次 scrypt，使登录失败耗时接近，避免枚举邮箱
const DUMMY_SALT = 'lexumo-sync-dummy-salt-0000000000'

// 邮箱：单个 @，本地部分与域名都非空，域名带点且顶级域至少 2 字符
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/

/** 统一规范化邮箱：trim + 小写（契约要求比较前统一处理） */
export function normalizeEmail(value) {
  return typeof value === 'string' ? value.trim().toLowerCase() : ''
}

export function isValidEmail(email) {
  return typeof email === 'string' && email.length > 0 && email.length <= 254 && EMAIL_RE.test(email)
}

export function isValidPassword(password) {
  return (
    typeof password === 'string' &&
    password.length >= PASSWORD_MIN_LENGTH &&
    password.length <= PASSWORD_MAX_LENGTH
  )
}

/** 生成 { salt, hash }，均为 hex 字符串 */
export function hashPassword(password) {
  const salt = randomBytes(SALT_BYTES).toString('hex')
  const hash = scryptSync(password, salt, HASH_BYTES).toString('hex')
  return { salt, hash }
}

/** 校验密码；user 为 null 时也执行一次 scrypt 以对齐耗时 */
export function verifyPassword(password, user) {
  const candidate = typeof password === 'string' ? password : ''
  if (!user) {
    scryptSync(candidate, DUMMY_SALT, HASH_BYTES)
    return false
  }
  const actual = scryptSync(candidate, user.salt, HASH_BYTES)
  const expected = Buffer.from(user.passwordHash, 'hex')
  if (expected.length !== actual.length) return false
  return timingSafeEqual(actual, expected)
}

/** 生成 opaque token：32 字节随机数 → 64 字符 hex */
export function createTokenValue() {
  return randomBytes(32).toString('hex')
}
