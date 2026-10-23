/* ============================================================
   api.mjs — 账号 HTTP 接口（契约 shared/API.md §6）
   ------------------------------------------------------------
   由 server.mjs 挂载：pathname 以 /api/ 开头时交给本模块，返回
   true 表示已应答。设计口径：
     · 请求体 JSON、上限 128KB；鉴权响应一律 Cache-Control: no-store
     · 错误统一 {error: 中文说明, code: MACHINE_CODE}
     · 限速：注册 10 次/小时、登录 20 次/小时（按 IP，反代取
       X-Forwarded-For 首段——自托管 nginx 形态下由反代保证该头可信）
     · CORS 与 /events 同 posture：ACAO * + OPTIONS 预检（token 而非
       cookie，无凭证面）
   ============================================================ */
import { createRateLimiter, openAuthStore, AuthError } from './store.mjs'

/** 请求体读取上限（账号数据文档本身 64KB，留 JSON 包装余量） */
const BODY_MAX = 128 * 1024

/**
 * 客户端 IP（限速键）。默认只认 socket 直连地址——直连形态下 XFF 是
 * 客户端可伪造头，采信它 = 换头绕过限速；nginx 反代形态由部署方显式
 * 开 --trust-proxy（server.mjs），此时才取 XFF 首段（反代保证该头可信）。
 */
function clientIp(req, trustProxy) {
  if (trustProxy) {
    const xff = req.headers['x-forwarded-for']
    if (typeof xff === 'string' && xff.trim()) return xff.split(',')[0].trim()
  }
  return req.socket?.remoteAddress || 'unknown'
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    /** @type {Array<Buffer|string>} */
    const chunks = []
    let size = 0
    req.on('data', (c) => {
      const buf = Buffer.isBuffer(c) ? c : Buffer.from(c)
      size += buf.length
      if (size > BODY_MAX) {
        reject(new AuthError('BODY_TOO_LARGE', '请求体过大', 413))
        req.destroy()
        return
      }
      chunks.push(buf)
    })
    req.on('end', () => {
      if (!chunks.length) return resolve({})
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')))
      } catch {
        reject(new AuthError('BAD_JSON', '请求体不是合法 JSON', 400))
      }
    })
    req.on('error', reject)
  })
}

function sendJson(res, status, obj, extraHeaders = {}) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
    ...extraHeaders,
  })
  res.end(JSON.stringify(obj))
}

function bearer(req) {
  const h = req.headers.authorization
  if (typeof h !== 'string' || !h.startsWith('Bearer ')) return null
  const t = h.slice(7).trim()
  return t || null
}

/**
 * 创建账号 API。
 * @param {{rootDir?:string}} opts 同 openAuthStore
 * @returns {{handle:(req:import('node:http').IncomingMessage,
 *            res:import('node:http').ServerResponse, url:URL)=>Promise<boolean>}}
 */
export function createAuthApi({ rootDir = process.cwd(), trustProxy = false } = {}) {
  const store = openAuthStore({ rootDir })
  const registerLimiter = createRateLimiter(10, 3600_000)
  const loginLimiter = createRateLimiter(20, 3600_000)

  async function requireUser(req) {
    const token = bearer(req)
    if (!token) throw new AuthError('NO_TOKEN', '未登录', 401)
    return store.verifyToken(token)
  }

  /** @returns {Promise<boolean>} 已处理 true（含预检与未知 /api 路径的 404） */
  async function handle(req, res, url) {
    const { pathname } = url
    if (!pathname.startsWith('/api/')) return false

    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        'Access-Control-Max-Age': '86400',
      })
      res.end()
      return true
    }

    try {
      if (pathname === '/api/auth/register' && req.method === 'POST') {
        if (!registerLimiter.take(clientIp(req, trustProxy))) {
          throw new AuthError('RATE_LIMITED', '注册太频繁，请一小时后再试', 429)
        }
        const body = await readBody(req)
        const out = await store.register(body)
        sendJson(res, 201, out)
        return true
      }
      if (pathname === '/api/auth/login' && req.method === 'POST') {
        if (!loginLimiter.take(clientIp(req, trustProxy))) {
          throw new AuthError('RATE_LIMITED', '尝试太频繁，请一小时后再试', 429)
        }
        const body = await readBody(req)
        const out = await store.login(body)
        sendJson(res, 200, out)
        return true
      }
      if (pathname === '/api/auth/logout' && req.method === 'POST') {
        const user = await requireUser(req)
        await store.logout(user.uid)
        res.writeHead(204, {
          'Cache-Control': 'no-store',
          'Access-Control-Allow-Origin': '*',
        })
        res.end()
        return true
      }
      if (pathname === '/api/auth/me' && req.method === 'GET') {
        const user = await requireUser(req)
        sendJson(res, 200, user)
        return true
      }
      if (pathname === '/api/account/data' && req.method === 'GET') {
        const user = await requireUser(req)
        sendJson(res, 200, await store.getData(user.uid))
        return true
      }
      if (pathname === '/api/account/data' && req.method === 'PUT') {
        const user = await requireUser(req)
        const body = await readBody(req)
        if (body === null || typeof body !== 'object' || Array.isArray(body)) {
          throw new AuthError('BAD_DOC', '账号数据应为对象', 400)
        }
        sendJson(res, 200, await store.putData(user.uid, body))
        return true
      }
      sendJson(res, 404, { error: '接口不存在', code: 'NOT_FOUND' })
      return true
    } catch (e) {
      if (e instanceof AuthError) {
        sendJson(res, e.status, { error: e.message, code: e.code })
        return true
      }
      // 未知异常按 500 兜底，不外泄堆栈
      sendJson(res, 500, { error: '服务器内部错误', code: 'INTERNAL' })
      return true
    }
  }

  return { handle, store }
}
