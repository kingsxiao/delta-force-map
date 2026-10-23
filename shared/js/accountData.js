/* ============================================================
   accountData.js — 账号云数据的纯函数口径（契约 shared/API.md §6）
   ------------------------------------------------------------
   账号数据是「不透明 K/V 文档」：服务端只存不解析，键名与合并
   规则由三端共用本模块约定。iOS 端在 DeltaForceCore/AccountData.swift
   同构移植 stars / ledger 的合并（mycost 为网页端独有键，iOS 只透传
   保留不消费）；单测与网页端 / 后端共用同一套口径。
   ============================================================ */

/** 文档序列化后的大小上限（字节）：服务端 PUT 侧与客户端预检共用 */
export const ACCOUNT_DOC_MAX_BYTES = 64 * 1024

/** K/V 键名规则：字母/数字/点/下划线/短横线，1–64 字符（点分命名空间，如 stars.ammo） */
const KEY_RE = /^[A-Za-z0-9._-]{1,64}$/

/**
 * 校验并规范化账号数据文档（服务端 PUT 与客户端推送前共用）。
 * @param {unknown} raw 任意 JSON 值
 * @returns {Record<string, unknown>|null} 合法则返回深拷贝的普通对象，非法返回 null
 */
export function normalizeAccountDoc(raw) {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return null
  let size = 2
  for (const [k, v] of Object.entries(raw)) {
    if (!KEY_RE.test(k)) return null
    const part = JSON.stringify(v)
    if (part === undefined) return null // 函数 / undefined 等不可序列化值
    size += k.length + part.length + 4
    if (size > ACCOUNT_DOC_MAX_BYTES) return null
  }
  return JSON.parse(JSON.stringify(raw))
}

/**
 * 合并两端的自选星标（首次登录 / 多端合并口径：并集，去重，按名排序）。
 * @param {unknown} local 本地星标（弹名数组；非法输入按空处理）
 * @param {unknown} remote 云端星标（同上）
 * @returns {string[]} 并集（排序后）
 */
export function mergeStars(local, remote) {
  const names = new Set()
  for (const list of [local, remote]) {
    if (!Array.isArray(list)) continue
    for (const n of list) if (typeof n === 'string' && n) names.add(n)
  }
  return [...names].sort()
}

/**
 * 清洗单条囤货台账记录（口径对齐 AmmoMarketView.loadPositions / PositionsStore：
 * name 非空字符串、qty ≥1 取整、cost ≥0 有限数）。非法返回 null。
 * @param {unknown} p
 * @returns {{name:string, qty:number, cost:number}|null}
 */
export function normalizePosition(p) {
  if (p === null || typeof p !== 'object' || Array.isArray(p)) return null
  if (typeof p.name !== 'string' || !p.name) return null
  const qty = +p.qty
  const cost = +p.cost
  if (!Number.isFinite(qty) || !Number.isFinite(cost)) return null
  return { name: p.name, qty: Math.max(1, Math.round(qty)), cost: Math.max(0, cost) }
}

/**
 * 合并两端的囤货台账（键 ledger.ammo 的合并口径）：按弹名并集；
 * 同名条目冲突时**本地优先**（登录合并发生在用户正在用的设备上，
 * 本地刚改过的数字更可信；远端同名条目丢弃）。结果按弹名排序。
 * @param {unknown} local 本地台账（[{name, qty, cost}]；非法按空处理）
 * @param {unknown} remote 云端台账（同上）
 * @returns {{name:string, qty:number, cost:number}[]}
 */
export function mergePositions(local, remote) {
  const byName = new Map()
  const put = (p) => {
    const n = normalizePosition(p)
    if (n) byName.set(n.name, n)
  }
  if (Array.isArray(remote)) for (const p of remote) put(p)
  if (Array.isArray(local)) for (const p of local) put(p) // 本地后放：同名覆盖远端（本地优先）
  return [...byName.values()].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
}

/**
 * 通用「平对象」合并：按键并集，同名键**本地优先**（mycost.ammo 等
 * {弹名: 数值} 形状的键用；非对象输入按空对象处理，值原样保留不清洗——
 * 值的校验由写入方负责，这里只管合并次序）。
 * @param {unknown} local
 * @param {unknown} remote
 * @returns {Record<string, unknown>}
 */
export function mergeLocalWins(local, remote) {
  const pick = (v) => (v !== null && typeof v === 'object' && !Array.isArray(v) ? v : {})
  return { ...pick(remote), ...pick(local) }
}
