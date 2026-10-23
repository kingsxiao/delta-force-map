/* ============================================================
   api.mjs — 账号 HTTP 接口（契约 shared/API.md §6）
   ------------------------------------------------------------
   由 server.mjs 挂载：pathname 以 /api/ 开头时交给本模块，返回
   true 表示已应答。设计口径：
     · 请求体 JSON、上限 128KB；鉴权响应一律 Cache-Control: no-store
     · 错误统一 {error: 中文说明, code: MACHINE_CODE}
     · 限速：注册 10 次/小时、登录 20 次/小时、账号数据 30 次/分钟（按 IP，
       反代取 X-Forwarded-For 从右数第 N 跳——$proxy_add_x_forwarded_for
       追加模式下末段才是反代眼见的真实对端，首段客户端可自带伪造；单层
       反代 N=1，多级反代须 --trust-proxy=N 显式指明跳数）
     · CORS 与 /events 同 posture：ACAO * + OPTIONS 预检（token 而非
       cookie，无凭证面）
   ============================================================ */
import { createRateLimiter, openAuthStore, AuthError } from './store.mjs'

/** 请求体读取上限（账号数据文档本身 64KB，留 JSON 包装余量） */
const BODY_MAX = 128 * 1024

/**
 * 客户端 IP（限速键）。默认只认 socket 直连地址——直连形态下 XFF 是
 * 客户端可伪造头，采信它 = 换头绕过限速；nginx 反代形态由部署方显式
 * 开 --trust-proxy（server.mjs），此时取 X-Forwarded-For **从右数第
 * trustProxy 跳**——nginx `proxy_set_header X-Forwarded-For
 * $proxy_add_x_forwarded_for` 是追加模式，末段（第 1 跳）是本机反代眼见
 * 的对端地址（可信），首段则可能是客户端自带的任意值。多级反代
 * （CDN→nginx→node 等）须 --trust-proxy=N 指明跳数：仍取末段的话末段
 * 恒为上级代理内网 IP，全站用户聚合到同一限速键互相挤掉配额。
 * @param {boolean|number} trustProxy true = 单层反代（1 跳）；正整数 N = 从右数第 N 跳
 */
function clientIp(req, trustProxy) {
  if (trustProxy) {
    const hops = trustProxy === true ? 1 : Math.max(1, Number(trustProxy) || 1)
    const xff = req.headers['x-forwarded-for']
    if (typeof xff === 'string' && xff.trim()) {
      const parts = xff.split(',').map((s) => s.trim()).filter(Boolean)
      // 声明跳数多于 XFF 实际段数 = 链路与配置不符，不知哪段可信，
      // 保守退回 socket 直连地址（宁可全员一桶，不给伪造段留绕过面）
      if (parts.length >= hops) return parts[parts.length - hops]
    }
  }
  return req.socket?.remoteAddress || 'unknown'
}

function readBody(req, res) {
  return new Promise((resolve, reject) => {
    /** @type {Array<Buffer|string>} */
    const chunks = []
    let size = 0
    let oversized = false
    req.on('data', (c) => {
      if (oversized) return // 已拒收：不再缓冲（防超大体继续吃内存）
      const buf = Buffer.isBuffer(c) ? c : Buffer.from(c)
      size += buf.length
      if (size > BODY_MAX) {
        oversized = true
        // 先回写 413 再掐连接：先 req.destroy() 会 RST 早于响应到达，客户端
        // 只见 ECONNRESET，契约承诺的 413 JSON 实际不可达。改为 Connection:
        // close 回写，等响应刷完（finish）再 destroy——响应可送达，也不留
        // 慢速上传长期占连接
        sendJson(res, 413, { error: '请求体过大', code: 'BODY_TOO_LARGE' }, { Connection: 'close' })
        const err = new AuthError('BODY_TOO_LARGE', '请求体过大', 413)
        err.responded = true // 告知 handle：响应已发，catch 里别再写一次
        if (typeof res.on === 'function') res.on('finish', () => req.destroy())
        reject(err)
        return
      }
      chunks.push(buf)
    })
    req.on('end', () => {
      if (oversized) return
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
  // 账号数据读写（GET/PUT /api/account/data）：独立宽松限速——PUT 每次都触发
  // 整文档 normalize+原子写盘，无限速时持有合法 token 者可无限放大磁盘 I/O
  const dataLimiter = createRateLimiter(30, 60_000)

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
        const body = await readBody(req, res)
        const out = await store.register(body)
        sendJson(res, 201, out)
        return true
      }
      if (pathname === '/api/auth/login' && req.method === 'POST') {
        if (!loginLimiter.take(clientIp(req, trustProxy))) {
          throw new AuthError('RATE_LIMITED', '尝试太频繁，请一小时后再试', 429)
        }
        const body = await readBody(req, res)
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
        if (!dataLimiter.take(clientIp(req, trustProxy))) {
          throw new AuthError('RATE_LIMITED', '请求太频繁，请稍后再试', 429)
        }
        const user = await requireUser(req)
        sendJson(res, 200, await store.getData(user.uid))
        return true
      }
      if (pathname === '/api/account/data' && req.method === 'PUT') {
        if (!dataLimiter.take(clientIp(req, trustProxy))) {
          throw new AuthError('RATE_LIMITED', '保存太频繁，请稍后再试', 429)
        }
        const user = await requireUser(req)
        const body = await readBody(req, res)
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
        if (!e.responded) sendJson(res, e.status, { error: e.message, code: e.code })
        return true
      }
      // 未知异常按 500 兜底，不外泄堆栈
      sendJson(res, 500, { error: '服务器内部错误', code: 'INTERNAL' })
      return true
    }
  }

  return { handle, store }
}
