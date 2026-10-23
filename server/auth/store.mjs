/* ============================================================
   store.mjs — 账号存储与令牌（server/auth 的域逻辑，零 npm 依赖）
   ------------------------------------------------------------
   职责：注册 / 登录 / 登出（tokenVersion 全设备失效）/ 令牌校验 /
   账号云数据（每用户一个不透明 K/V 文档）。
   安全口径（契约 shared/API.md §6）：
     · 密码 scrypt（N=16384,r=8,p=1）+ 16B 随机盐，timingSafeEqual 比对
     · 令牌无状态：v1.<uid>.<tokenVersion>.<expMs>.<hmac>，HMAC-SHA256
       密钥 = data/auth/secret.key（首启生成 0o600，gitignore）
     · 用户名全表唯一（大小写不敏感）
   落盘：data/auth/accounts.json + data/auth/account-data/<uid>.json，
   一律 tmp+rename 原子写（同 fetch-once 的 writeJsonAtomic 口径）。
   并发：单进程内注册 / 登录串行化（promise 链），避免读改写竞争。
   ============================================================ */
import { randomBytes, scrypt as _scrypt, createHmac, timingSafeEqual } from 'node:crypto'
import { mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { normalizeAccountDoc } from '../../shared/js/accountData.js'

const SCRYPT = { N: 16384, r: 8, p: 1, keylen: 32 }
/** 令牌有效期 30 天（登出主动失效不受影响） */
export const TOKEN_TTL_MS = 30 * 24 * 3600 * 1000
/** 用户名：2–16 字符，字母/数字/下划线/任意文字（含中文） */
const USERNAME_RE = /^[\p{L}\p{N}_]{2,16}$/u
const PASSWORD_MIN = 8
const PASSWORD_MAX = 64

/** 语义化错误：code 供客户端分支，status 供 HTTP 层 */
export class AuthError extends Error {
  constructor(code, message, status = 400) {
    super(message)
    this.code = code
    this.status = status
  }
}

const scrypt = (password, salt) =>
  new Promise((resolve, reject) =>
    _scrypt(password, salt, SCRYPT.keylen, SCRYPT, (e, key) => (e ? reject(e) : resolve(key)))
  )

async function writeAtomic(filePath, text) {
  await mkdir(path.dirname(filePath), { recursive: true })
  const tmp = `${filePath}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`
  // 账号数据（密钥 / 哈希 / 云文档）一律 0600：多用户主机上其他本地账户不可读
  await writeFile(tmp, text, { mode: 0o600 })
  try {
    await rename(tmp, filePath)
  } catch (e) {
    await unlink(tmp).catch(() => {})
    throw e
  }
}

/**
 * 固定窗口限速器（按 IP；服务单进程，内存态即持久口径）。
 * @param {number} max 窗口内允许次数
 * @param {number} windowMs 窗口长度
 */
export function createRateLimiter(max, windowMs) {
  let windowStart = Date.now()
  const counts = new Map()
  // 键数上限：直连形态下攻击者可伪造无限个 IP 键，超限即整窗重置（宁重置不限内存）
  const MAX_KEYS = 4096
  return {
    take(key) {
      const now = Date.now()
      if (now - windowStart >= windowMs || counts.size > MAX_KEYS) {
        windowStart = now
        counts.clear()
      }
      const n = (counts.get(key) ?? 0) + 1
      counts.set(key, n)
      return n <= max
    },
  }
}

/**
 * 打开账号存储（懒加载首访读盘，写穿）。
 * @param {{rootDir?:string}} opts rootDir 仓库根（auth 数据挂 data/auth/）
 */
export function openAuthStore({ rootDir = process.cwd() } = {}) {
  const dir = path.join(rootDir, 'data', 'auth')
  const dataDir = path.join(dir, 'account-data')
  const accountsFile = path.join(dir, 'accounts.json')

  /** @type {{users: Record<string, any>}|null} 懒加载账号表 */
  let accounts = null
  /** @type {string|null} HMAC 密钥（hex） */
  let secret = null
  /** 注册/登录串行链（读改写竞争安全网） */
  let queue = Promise.resolve()

  async function loadAccounts() {
    if (accounts) return accounts
    try {
      const raw = JSON.parse(await readFile(accountsFile, 'utf8'))
      accounts = raw && typeof raw === 'object' && raw.users ? raw : { users: {} }
    } catch {
      accounts = { users: {} }
    }
    return accounts
  }

  async function loadSecret() {
    if (secret) return secret
    const file = path.join(dir, 'secret.key')
    try {
      secret = (await readFile(file, 'utf8')).trim()
      if (/^[0-9a-f]{64}$/.test(secret)) return secret
    } catch {
      /* 首启生成 */
    }
    secret = randomBytes(32).toString('hex')
    await writeAtomic(file, secret + '\n')
    return secret
  }

  function userPrivate(u) {
    return { uid: u.uid, username: u.username, createdAt: u.createdAt }
  }

  /* ---------- 令牌 ---------- */

  function hmac(payload) {
    return createHmac('sha256', Buffer.from(secret, 'hex')).update(payload).digest('hex')
  }

  /**
   * 签发令牌（ttlMs 供自测注入过期）。
   * @param {{uid:string, tokenVersion:number}} u
   */
  function signToken(u, ttlMs = TOKEN_TTL_MS) {
    const exp = Date.now() + ttlMs
    const payload = `v1.${u.uid}.${u.tokenVersion}.${exp}`
    return `${payload}.${hmac(payload)}`
  }

  /**
   * 校验令牌 → 用户记录；非法 / 过期 / 版本落后一律抛 AuthError。
   * @returns {{uid:string, username:string, createdAt:string}}
   */
  async function verifyToken(token) {
    if (typeof token !== 'string') throw new AuthError('BAD_TOKEN', '令牌无效', 401)
    const parts = token.split('.')
    if (parts.length !== 5 || parts[0] !== 'v1') throw new AuthError('BAD_TOKEN', '令牌无效', 401)
    const [, uid, tvRaw, expRaw, sig] = parts
    if (!/^[0-9a-f]{16}$/.test(uid) || !/^\d+$/.test(tvRaw) || !/^\d+$/.test(expRaw) || !/^[0-9a-f]{64}$/.test(sig)) {
      throw new AuthError('BAD_TOKEN', '令牌无效', 401)
    }
    await loadSecret()
    const expect = hmac(`v1.${uid}.${tvRaw}.${expRaw}`)
    const a = Buffer.from(sig)
    const b = Buffer.from(expect)
    if (a.length !== b.length || !timingSafeEqual(a, b)) throw new AuthError('BAD_TOKEN', '令牌无效', 401)
    if (Date.now() >= Number(expRaw)) throw new AuthError('TOKEN_EXPIRED', '登录已过期，请重新登录', 401)
    const table = await loadAccounts()
    const u = table.users[uid]
    if (!u || u.tokenVersion !== Number(tvRaw)) throw new AuthError('BAD_TOKEN', '登录已失效，请重新登录', 401)
    return userPrivate(u)
  }

  /* ---------- 注册 / 登录 / 登出 ---------- */

  function validateCredentials(username, password) {
    if (typeof username !== 'string' || !USERNAME_RE.test(username.trim()) || username.trim() !== username) {
      throw new AuthError('INVALID_USERNAME', '用户名需 2–16 个字符（字母/数字/下划线/中文，无首尾空格）')
    }
    if (typeof password !== 'string' || password.length < PASSWORD_MIN || password.length > PASSWORD_MAX) {
      throw new AuthError('INVALID_PASSWORD', `密码需 ${PASSWORD_MIN}–${PASSWORD_MAX} 个字符`)
    }
  }

  async function register({ username, password }) {
    validateCredentials(username, password)
    const run = async () => {
      const table = await loadAccounts()
      await loadSecret()
      const lower = username.toLowerCase()
      for (const u of Object.values(table.users)) {
        if (u.usernameLower === lower) throw new AuthError('USERNAME_TAKEN', '用户名已被注册', 409)
      }
      const user = {
        uid: randomBytes(8).toString('hex'),
        username,
        usernameLower: lower,
        salt: randomBytes(16).toString('hex'),
        hash: '',
        tokenVersion: 1,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      }
      user.hash = (await scrypt(password, user.salt)).toString('hex')
      table.users[user.uid] = user
      await writeAtomic(accountsFile, JSON.stringify(table, null, 2))
      return { user: userPrivate(user), token: signToken(user) }
    }
    const out = { result: null }
    queue = queue.then(run).then((r) => (out.result = r), (e) => (out.error = e))
    await queue
    if (out.error) throw out.error
    return out.result
  }

  async function login({ username, password }) {
    const run = async () => {
      const table = await loadAccounts()
      await loadSecret()
      const lower = typeof username === 'string' ? username.toLowerCase() : ''
      let user = null
      for (const u of Object.values(table.users)) {
        if (u.usernameLower === lower) { user = u; break }
      }
      // 恒定路径：用户不存在也跑一次同代价 scrypt（假盐 = 用户名小写），登录失败不泄露用户名是否存在
      const salt = user ? user.salt : lower
      const got = await scrypt(typeof password === 'string' ? password : '', salt)
      if (!user) throw new AuthError('AUTH_FAILED', '用户名或密码错误', 401)
      const a = Buffer.from(got)
      const b = Buffer.from(user.hash, 'hex')
      if (a.length !== b.length || !timingSafeEqual(a, b)) {
        throw new AuthError('AUTH_FAILED', '用户名或密码错误', 401)
      }
      return { user: userPrivate(user), token: signToken(user) }
    }
    const out = {}
    queue = queue.then(run).then((r) => (out.result = r), (e) => (out.error = e))
    await queue
    if (out.error) throw out.error
    return out.result
  }

  /** 登出：tokenVersion +1，该用户全部已发令牌失效（「退出所有设备」语义） */
  async function logout(uid) {
    const run = async () => {
      const table = await loadAccounts()
      const u = table.users[uid]
      if (!u) throw new AuthError('BAD_TOKEN', '令牌无效', 401)
      u.tokenVersion += 1
      u.updatedAt = new Date().toISOString()
      await writeAtomic(accountsFile, JSON.stringify(table, null, 2))
    }
    queue = queue.then(run, () => {})
    await queue
  }

  /* ---------- 账号云数据 ---------- */

  const dataFile = (uid) => path.join(dataDir, `${uid}.json`)

  /** 读取云数据文档；无则空文档（savedAt = null） */
  async function getData(uid) {
    try {
      const raw = JSON.parse(await readFile(dataFile(uid), 'utf8'))
      return { data: normalizeAccountDoc(raw.data) ?? {}, savedAt: raw.savedAt ?? null }
    } catch {
      return { data: {}, savedAt: null }
    }
  }

  /** 整文档覆盖写入（口径：normalizeAccountDoc 过滤） */
  async function putData(uid, doc) {
    const normalized = normalizeAccountDoc(doc)
    if (!normalized) throw new AuthError('BAD_DOC', '账号数据不合规（键名或 64KB 上限）', 413)
    const savedAt = new Date().toISOString()
    await writeAtomic(dataFile(uid), JSON.stringify({ savedAt, data: normalized }, null, 2))
    return { savedAt }
  }

  return { register, login, logout, verifyToken, signToken, getData, putData }
}
