/* ============================================================
   selftest.mjs — 账号体系离线自测（node 直接运行，零 npm 依赖）
   ------------------------------------------------------------
   全程不打外网：域逻辑直接调用；HTTP 层用 mock req/res；站点集成
   走 createSiteServer（不 start，不触发抓取）+ 127.0.0.1 临时端口。
   覆盖：
     ① accountData 纯函数：文档校验（键名 / 64KB / 形状）+ 星标并集
     ② store：注册 / 重名 / 凭证校验 / 登录对错 / 恒定路径不泄露存在性
     ③ 令牌：签发校验往返 / 过期 / 篡改 / 登出后全设备失效（tokenVersion）
     ④ 云数据：put/get 往返 / 不合规文档拒绝 / 各用户隔离
     ⑤ api HTTP 层（mock req/res）：状态码与错误 code、鉴权头、
        OPTIONS 预检、未知路径 404、限速 429
     ⑥ 站点集成：createSiteServer 挂载后 register/login/me/logout 走
        真实 HTTP 往返；GET 静态行为不受影响
   全部通过 exit 0；任何失败把原因写 stderr 后 exit 1。
   用法：node server/auth/selftest.mjs
   ============================================================ */
import { mkdtemp, rm, readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { Readable } from 'node:stream'

import { normalizeAccountDoc, mergeStars, mergePositions, mergeLocalWins, ACCOUNT_DOC_MAX_BYTES } from '../../shared/js/accountData.js'
import { openAuthStore, createRateLimiter, AuthError } from './store.mjs'
import { createAuthApi } from './api.mjs'
import { createSiteServer } from '../server.mjs'

function assert(cond, msg) {
  if (!cond) throw new Error(msg)
}
const checks = []
const check = (name, fn) => checks.push([name, fn])

/* ---------- mock req / res（HTTP 层单测用，不监听端口） ---------- */
function mockReq(method, pathname, { body, token } = {}) {
  const req = Readable.from(body === undefined ? [] : [JSON.stringify(body)])
  req.method = method
  req.url = pathname
  req.headers = {}
  if (token) req.headers.authorization = `Bearer ${token}`
  req.socket = { remoteAddress: '127.0.0.1' }
  return req
}
function mockRes() {
  const res = {
    status: 0,
    headers: {},
    body: '',
    writeHead(status, headers) {
      this.status = status
      // 键名统一小写（对齐 Node 真实发送行为）
      this.headers = Object.fromEntries(Object.entries(headers || {}).map(([k, v]) => [k.toLowerCase(), v]))
    },
    end(chunk) {
      if (chunk !== undefined) this.body += chunk
      this.done?.()
    },
  }
  res.finished = new Promise((resolve) => { res.done = resolve })
  return res
}
async function callRaw(api, req) {
  const res = mockRes()
  await api.handle(req, res, new URL(req.url, 'http://localhost'))
  await res.finished
  return { status: res.status, json: (() => { try { return JSON.parse(res.body) } catch { return null } })() }
}

async function call(api, method, pathname, opts = {}) {
  const req = mockReq(method, pathname, opts)
  const res = mockRes()
  const handled = await api.handle(req, res, new URL(pathname, 'http://localhost'))
  if (!handled) { res.done?.() }
  await res.finished
  let json = null
  try { json = JSON.parse(res.body) } catch { /* 非 JSON（204） */ }
  return { status: res.status, json, headers: res.headers }
}

/* ============================================================
   ① accountData 纯函数
   ============================================================ */
check('① accountData：文档校验（形状 / 键名 / 64KB）', () => {
  assert(normalizeAccountDoc({ 'stars.ammo': ['a'] }) !== null, '合法文档应通过')
  assert(normalizeAccountDoc(null) === null, 'null 拒绝')
  assert(normalizeAccountDoc([1]) === null, '数组拒绝')
  assert(normalizeAccountDoc('x') === null, '字符串拒绝')
  assert(normalizeAccountDoc({ 'bad key!': 1 }) === null, '非法键名拒绝')
  assert(normalizeAccountDoc({ '': 1 }) === null, '空键名拒绝')
  const big = { 'stars.ammo': ['x'.repeat(1000)] }
  big['k'] = 'y'.repeat(ACCOUNT_DOC_MAX_BYTES)
  assert(normalizeAccountDoc(big) === null, '超 64KB 拒绝')
  const doc = { 'stars.ammo': ['b', 'a'] }
  const out = normalizeAccountDoc(doc)
  assert(Array.isArray(out['stars.ammo']), '返回普通对象')
  doc['stars.ammo'].length = 0
  assert(out['stars.ammo'].length === 2, '深拷贝：改原对象不影响产物')
})

check('① accountData：星标并集（去重 / 排序 / 容错）', () => {
  assert(
    JSON.stringify(mergeStars(['b', 'a'], ['a', 'c'])) === JSON.stringify(['a', 'b', 'c']),
    '并集去重排序'
  )
  assert(JSON.stringify(mergeStars([], null)) === '[]', '非法侧按空处理')
  assert(JSON.stringify(mergeStars(undefined, ['b', 'a'])) === JSON.stringify(['a', 'b']), '单侧为空仍成立')
  assert(JSON.stringify(mergeStars(['a', 1, null, ''], ['a'])) === '["a"]', '非字符串/空串元素剔除')
})

check('① accountData：台账合并（按名并集 / 同名本地优先 / 清洗钳位）', () => {
  const local = [
    { name: '弹B', qty: 100, cost: 300 },
    { name: '弹A', qty: 50, cost: 200 },
  ]
  const remote = [
    { name: '弹A', qty: 999, cost: 1 }, // 同名：本地优先，远端丢弃
    { name: '弹C', qty: 10, cost: 50 },
  ]
  const merged = mergePositions(local, remote)
  assert(
    JSON.stringify(merged.map((p) => p.name)) === JSON.stringify(['弹A', '弹B', '弹C']),
    `按名并集且排序，实际 ${JSON.stringify(merged)}`
  )
  assert(merged[0].qty === 50 && merged[0].cost === 200, '同名冲突应本地胜出')
  assert(JSON.stringify(mergePositions(null, null)) === '[]', '两侧非法按空处理')
  // 清洗：qty 取整 ≥1、cost ≥0、非法条目剔除（口径对齐 loadPositions / ledgerEntry）
  const dirty = mergePositions([{ name: 'X', qty: 2.6, cost: 300 }, { name: '', qty: 1, cost: 1 }, 'not-obj'], [])
  assert(dirty.length === 1 && dirty[0].qty === 3, `qty 2.6 → 3、空名与非对象剔除，实际 ${JSON.stringify(dirty)}`)
})

check('① accountData：平对象合并（按键并集 / 同名本地优先 / 非对象按空）', () => {
  const merged = mergeLocalWins({ '弹A': 200, '弹B': 300 }, { '弹B': 1, '弹C': 50 })
  assert(merged['弹B'] === 300, '同名应本地胜出')
  assert(merged['弹A'] === 200 && merged['弹C'] === 50, '两侧独有键全保留')
  assert(JSON.stringify(mergeLocalWins(null, null)) === '{}', '非对象输入按空对象')
  assert(JSON.stringify(mergeLocalWins([1], 'x')) === '{}', '数组/字符串按空对象')
})

/* ============================================================
   ② store：注册 / 登录 / ③ 令牌 / ④ 云数据
   ============================================================ */
check('②③④ store：注册 / 登录 / 令牌 / 登出 / 云数据全链路', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'df-auth-'))
  try {
    const store = openAuthStore({ rootDir: root })
    const reg = await store.register({ username: '玩家一号', password: 'password123' })
    assert(/^[0-9a-f]{16}$/.test(reg.user.uid), 'uid 应为 16 位 hex')
    assert(reg.user.username === '玩家一号', '返回用户名')
    assert(typeof reg.token === 'string' && reg.token.startsWith('v1.'), '返回 v1 令牌')

    // 重名（大小写不敏感）
    let dup = null
    try { await store.register({ username: '玩家一号', password: 'password456' }) } catch (e) { dup = e }
    assert(dup instanceof AuthError && dup.code === 'USERNAME_TAKEN', '重名应 409 语义')

    // 凭证校验
    for (const [u, p, code] of [
      ['x', 'password123', 'INVALID_USERNAME'], // 过短
      ['ok_user ', 'password123', 'INVALID_USERNAME'], // 首尾空格
      ['玩家一号', 'short', 'INVALID_PASSWORD'], // 密码过短
    ]) {
      let e = null
      try { await store.register({ username: u, password: p }) } catch (err) { e = err }
      assert(e && e.code === code, `${JSON.stringify(u)} 应报 ${code}，实际 ${e && e.code}`)
    }

    // 登录对错 + 不存在用户（AUTH_FAILED，不区分）
    const ok = await store.login({ username: '玩家一号', password: 'password123' })
    assert(ok.token.startsWith('v1.'), '登录发令牌')
    for (const [u, p] of [['玩家一号', 'wrong-pass'], ['不存在的', 'password123']]) {
      let e = null
      try { await store.login({ username: u, password: p }) } catch (err) { e = err }
      assert(e && e.code === 'AUTH_FAILED' && e.status === 401, `${u} 登录失败应统一 AUTH_FAILED`)
    }

    // 令牌：往返 / 篡改 / 过期
    const me = await store.verifyToken(ok.token)
    assert(me.username === '玩家一号', '令牌校验往返')
    let bad = null
    try { await store.verifyToken(ok.token.slice(0, -2) + 'ff') } catch (e) { bad = e }
    assert(bad && bad.code === 'BAD_TOKEN', '篡改签名应拒绝')
    const expired = store.signToken({ uid: me.uid, tokenVersion: 1 }, -1)
    let exp = null
    try { await store.verifyToken(expired) } catch (e) { exp = e }
    assert(exp && exp.code === 'TOKEN_EXPIRED', '过期应拒绝')

    // 云数据：put/get 往返 + 隔离 + 不合规
    const put = await store.putData(me.uid, { 'stars.ammo': ['b', 'a'] })
    assert(typeof put.savedAt === 'string', 'put 返回 savedAt')
    const got = await store.getData(me.uid)
    assert(JSON.stringify(got.data['stars.ammo']) === JSON.stringify(['b', 'a']), 'get 往返一致')
    assert((await store.getData('ffffffffffffffff')).data && Object.keys((await store.getData('ffffffffffffffff')).data).length === 0, '无数据用户得空文档')
    let docErr = null
    try { await store.putData(me.uid, { 'bad key': 1 }) } catch (e) { docErr = e }
    assert(docErr && docErr.code === 'BAD_DOC', '不合规文档应拒绝')

    // 登出：tokenVersion +1 → 旧令牌全失效
    await store.logout(me.uid)
    let dead = null
    try { await store.verifyToken(ok.token) } catch (e) { dead = e }
    assert(dead && dead.code === 'BAD_TOKEN', '登出后旧令牌应失效')
    const reLogin = await store.login({ username: '玩家一号', password: 'password123' })
    await store.verifyToken(reLogin.token)
    assert(reLogin.token !== ok.token, '重新登录发新令牌')

    // 落盘形状：账号表不含明文密码；盐/哈希均为 hex
    const table = JSON.parse(await readFile(path.join(root, 'data', 'auth', 'accounts.json'), 'utf8'))
    const u = table.users[me.uid]
    assert(u && /^[0-9a-f]{32}$/.test(u.salt) && /^[0-9a-f]{64}$/.test(u.hash), '盐 32 hex / 哈希 64 hex')
    assert(!JSON.stringify(table).includes('password123'), '账号表不得出现明文密码')
    assert(!('password' in u), '不得存 password 字段')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

/* ============================================================
   ⑤ api HTTP 层（mock req/res）
   ============================================================ */
check('⑤ api：状态码 / 错误 code / 鉴权 / 预检 / 404 / 限速', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'df-api-'))
  try {
    const api = createAuthApi({ rootDir: root })

    const reg = await call(api, 'POST', '/api/auth/register', { body: { username: 'tester', password: 'password123' } })
    assert(reg.status === 201 && reg.json.token && reg.json.user.username === 'tester', '注册 201 带会话')
    assert(reg.headers['cache-control'] === 'no-store', '鉴权响应 no-store')

    const dup = await call(api, 'POST', '/api/auth/register', { body: { username: 'tester', password: 'password123' } })
    assert(dup.status === 409 && dup.json.code === 'USERNAME_TAKEN', '重名 409')

    const login = await call(api, 'POST', '/api/auth/login', { body: { username: 'tester', password: 'password123' } })
    assert(login.status === 200 && login.json.token, '登录 200')
    const wrong = await call(api, 'POST', '/api/auth/login', { body: { username: 'tester', password: 'wrong-pass' } })
    assert(wrong.status === 401 && wrong.json.code === 'AUTH_FAILED', '错密码 401')

    const noAuth = await call(api, 'GET', '/api/auth/me')
    assert(noAuth.status === 401 && noAuth.json.code === 'NO_TOKEN', '无令牌 401')
    const badAuth = await call(api, 'GET', '/api/auth/me', { token: 'v1.garbage' })
    assert(badAuth.status === 401 && badAuth.json.code === 'BAD_TOKEN', '坏令牌 401')
    const me = await call(api, 'GET', '/api/auth/me', { token: login.json.token })
    assert(me.status === 200 && me.json.uid === reg.json.user.uid, 'me 往返')

    const put = await call(api, 'PUT', '/api/account/data', { body: { 'stars.ammo': ['a'] }, token: login.json.token })
    assert(put.status === 200 && put.json.savedAt, 'put 200')
    const get = await call(api, 'GET', '/api/account/data', { token: login.json.token })
    assert(get.status === 200 && JSON.stringify(get.json.data) === JSON.stringify({ 'stars.ammo': ['a'] }), 'get 往返')
    const badDoc = await call(api, 'PUT', '/api/account/data', { body: { 'bad key': 1 }, token: login.json.token })
    assert(badDoc.status === 413 && badDoc.json.code === 'BAD_DOC', '不合规文档 413')

    const preflight = await call(api, 'OPTIONS', '/api/auth/login')
    assert(preflight.status === 204 && preflight.headers['access-control-allow-origin'] === '*', 'OPTIONS 预检 204')
    const notFound = await call(api, 'GET', '/api/auth/nope')
    assert(notFound.status === 404 && notFound.json.code === 'NOT_FOUND', '未知路径 404 JSON')
    const notHandled = await api.handle(mockReq('GET', '/other'), mockRes(), new URL('http://localhost/other'))
    assert(notHandled === false, '非 /api 路径应交还（返回 false）')

    // 限速：注册 10 次/小时 → 第 11 次 429（新 store 免受上一段计数影响）
    const api2 = createAuthApi({ rootDir: root })
    let last = null
    for (let i = 0; i < 11; i++) {
      last = await call(api2, 'POST', '/api/auth/register', { body: { username: `u${i}`, password: 'password123' } })
    }
    assert(last.status === 429 && last.json.code === 'RATE_LIMITED', '注册限速 429')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

/* ============================================================
   ⑥ 站点集成：createSiteServer 挂 /api（不 start，不触发抓取）
   ============================================================ */
check('⑥ 站点集成：register/login/me/logout 走真实 HTTP', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'df-site-'))
  let site = null
  try {
    site = createSiteServer({ rootDir: root, webDir: root })
    await new Promise((resolve) => site.server.listen(0, '127.0.0.1', resolve))
    const base = `http://127.0.0.1:${site.server.address().port}`

    const reg = await fetch(`${base}/api/auth/register`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: '玩家二号', password: 'password123' }),
    })
    assert(reg.status === 201, `register 应 201，实际 ${reg.status}`)
    const session = await reg.json()
    assert(session.token && session.user.username === '玩家二号', '注册返回会话')

    const me = await fetch(`${base}/api/auth/me`, { headers: { Authorization: `Bearer ${session.token}` } })
    assert(me.status === 200 && (await me.json()).uid === session.user.uid, 'me 走 HTTP 往返')

    const put = await fetch(`${base}/api/account/data`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${session.token}` },
      body: JSON.stringify({ 'stars.ammo': ['a', 'b'] }),
    })
    assert(put.status === 200, 'put 走 HTTP')
    const doc = await fetch(`${base}/api/account/data`, { headers: { Authorization: `Bearer ${session.token}` } })
    assert((await doc.json()).data['stars.ammo'].length === 2, 'get 走 HTTP')

    const out = await fetch(`${base}/api/auth/logout`, { method: 'POST', headers: { Authorization: `Bearer ${session.token}` } })
    assert(out.status === 204, 'logout 204')
    const dead = await fetch(`${base}/api/auth/me`, { headers: { Authorization: `Bearer ${session.token}` } })
    assert(dead.status === 401, '登出后旧令牌 401')

    // 静态侧行为不受影响：GET /api 之外的 POST 仍 405；GET 不存在路径 404
    const post405 = await fetch(`${base}/anything`, { method: 'POST' })
    assert(post405.status === 405, `非 /api 的 POST 应仍 405，实际 ${post405.status}`)
    const get404 = await fetch(`${base}/no-such-file.json`)
    assert(get404.status === 404, 'GET 未知文件 404')
  } finally {
    if (site) await site.close().catch(() => {})
    await rm(root, { recursive: true, force: true })
  }
})

/* ---------- XFF 采信开关（直连默认不采信，--trust-proxy 才取首段） ---------- */
check('⑤ 限速 IP：默认不采信 XFF，trustProxy 才按首段计', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'df-xff-'))
  try {
    let seq = 0
    const mk = (xff) => {
      const req = Readable.from([JSON.stringify({ username: `u${seq++}${Date.now() % 100000}`, password: 'password123' })])
      req.method = 'POST'; req.url = '/api/auth/register'
      req.headers = xff ? { 'x-forwarded-for': xff } : {}
      req.socket = { remoteAddress: '127.0.0.1' }
      return req
    }
    // 默认（直连）：11 个不同 XFF 也全按 127.0.0.1 一个桶计 → 第 11 次 429
    const api1 = createAuthApi({ rootDir: root })
    let last1 = null
    for (let i = 0; i < 11; i++) {
      last1 = await callRaw(api1, mk(`9.9.9.${i}`))
    }
    assert(last1.status === 429, `默认形态伪造 XFF 不应绕过限速，实际 ${last1.status}`)
    // trustProxy：不同 XFF 各自计数 → 11 个不同 IP 不触发 429
    const api2 = createAuthApi({ rootDir: root, trustProxy: true })
    let last2 = null
    for (let i = 0; i < 11; i++) {
      last2 = await callRaw(api2, mk(`8.8.8.${i}`))
    }
    assert(last2.status === 201, `trustProxy 下不同 XFF 应各计各的，实际 ${last2.status}`)
    // 密钥 / 账号文件权限 0600（多用户主机安全底线）
    const { stat } = await import('node:fs/promises')
    for (const f of ['data/auth/secret.key', 'data/auth/accounts.json']) {
      const mode = (await stat(path.join(root, f))).mode & 0o777
      assert(mode === 0o600, `${f} 应 0600，实际 ${mode.toString(8)}`)
    }
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

/* ---------- 限速器纯逻辑 ---------- */
check('⑤ 限速器：窗口内计数 / 窗口翻转', async () => {
  const limiter = createRateLimiter(2, 50)
  assert(limiter.take('a') && limiter.take('a'), '前两次放行')
  assert(!limiter.take('a'), '第三次拒绝')
  assert(limiter.take('b'), '不同 key 互不影响')
  await new Promise((r) => setTimeout(r, 60))
  assert(limiter.take('a'), '窗口翻转后放行')
})

/* ---------- 跑测 ---------- */
let failed = 0
for (const [name, fn] of checks) {
  try {
    await fn()
    console.log(`✓ ${name}`)
  } catch (e) {
    failed++
    console.error(`✗ ${name}\n    ${e.message}`)
  }
}
if (failed) {
  console.error(`\n${failed}/${checks.length} 项未通过`)
  process.exit(1)
}
console.log(`\n全部 ${checks.length} 项通过（离线模式，未打外网）`)
