/* ============================================================
   auth.js — 账号接口客户端（契约 shared/API.md §6）
   ------------------------------------------------------------
   同源相对路径 /api/*（部署形态 = server.mjs 同进程；本地 dev 由
   vite proxy 转发到 127.0.0.1:8080，见 vite.config.js）。
   错误统一抛 AuthApiError（code 机器码 + 中文 message），调用方
   按 code 分支展示；401 语义（BAD_TOKEN / TOKEN_EXPIRED）由
   useAccount 统一清会话。
   ============================================================ */

export class AuthApiError extends Error {
  constructor(code, message, status) {
    super(message)
    this.code = code
    this.status = status
  }
}

const TOKEN_KEY = 'df.auth.token'
const USER_KEY = 'df.auth.user'

async function api(path, { method = 'GET', body, token } = {}) {
  const headers = { Accept: 'application/json' }
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  if (token) headers.Authorization = `Bearer ${token}`
  let res
  try {
    res = await fetch(path, {
      method,
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    })
  } catch {
    throw new AuthApiError('NETWORK', '网络请求失败，请检查网络或稍后再试', 0)
  }
  if (res.status === 204) return null
  let json = null
  try {
    json = await res.json()
  } catch {
    /* 非 JSON 响应按空处理 */
  }
  if (!res.ok) {
    throw new AuthApiError(json?.code || 'UNKNOWN', json?.error || `请求失败（HTTP ${res.status}）`, res.status)
  }
  return json
}

/* ---------- 会话存取（localStorage；token 是唯一凭证，user 仅展示用） ---------- */

export function getStoredSession() {
  try {
    const token = localStorage.getItem(TOKEN_KEY)
    if (!token) return null
    let user = null
    try {
      user = JSON.parse(localStorage.getItem(USER_KEY))
    } catch { /* user 展示信息损坏不阻断：下次 me() 修正 */ }
    return { token, user }
  } catch {
    return null
  }
}

export function setStoredSession({ token, user }) {
  try {
    localStorage.setItem(TOKEN_KEY, token)
    localStorage.setItem(USER_KEY, JSON.stringify(user))
  } catch { /* 隐私模式存不进：会话仅本次页面生命周期内可用 */ }
}

export function clearStoredSession() {
  try {
    localStorage.removeItem(TOKEN_KEY)
    localStorage.removeItem(USER_KEY)
  } catch { /* 同上 */ }
}

/* ---------- 接口封装 ---------- */

/** 注册成功返回 {token, user}；409 用户名已存在 */
export const authRegister = ({ username, password }) =>
  api('/api/auth/register', { method: 'POST', body: { username, password } })

/** 登录成功返回 {token, user}；401 用户名或密码错误 */
export const authLogin = ({ username, password }) =>
  api('/api/auth/login', { method: 'POST', body: { username, password } })

/** 登出（服务器使该用户全部令牌失效）；本地清理由调用方负责 */
export const authLogout = (token) => api('/api/auth/logout', { method: 'POST', token })

/** 当前用户信息；401 = 令牌失效 */
export const authMe = (token) => api('/api/auth/me', { token })

/** 云数据文档：{data, savedAt} */
export const getAccountData = (token) => api('/api/account/data', { token })

/** 整文档覆盖上传；413 = 超 64KB 或键名不合规 */
export const putAccountData = (token, data) =>
  api('/api/account/data', { method: 'PUT', body: data, token })
