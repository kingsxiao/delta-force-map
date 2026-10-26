/* ============================================================
   ams-client.mjs — 腾讯官方 AMS 数据接口客户端（免登录，纯库零依赖）
   ------------------------------------------------------------
   数据源：三角洲行动官方 AMS IDE 流程接口（2026-10-26 双人 curl 复核），
   免登录公开接口，仅需浏览器 UA 与 Origin/Referer https://df.qq.com/：
     · 物品目录 object.list：chartId 352143 @ comm.ams.game.qq.com/ide/
       （param={primary,second,third,objectID}，primary 逐类传 gun/ammo/
        protect/acc/props；取值路径 jData.data.data.list）
     · 小时均价：chartId 352246 @ dfm.ams.game.qq.com/ide/
       （表单直传 propid=<id,...> 与 stat_hour=YYYYMMDDHH 北京墙钟；stat_hour
        必填但值被忽略；实测 jData.data 为 {<id>:{avg_buyprice}} 直接映射，
        兼容累计数组取末元素口径；单次 ≤5 个 id）
   响应 Content-Type 是 text/html 但正文 JSON——按 text() 读回再 JSON.parse，
   不能信 Content-Type。
   token 兜底链：内置现行 sIdeToken 表（352143:'YWRywA' / 352246:'Zek01X'）；
   请求失败且症状像 token 问题时 GET 流目录（token 是活动配置会轮换，非凭据）
   刷新模块态 token 表并重试一次。流目录刷新带冷却窗口（默认 10 分钟，仅成功
   后计时）——daemon 常驻下瞬时故障不会永久烧掉刷新机会，token 真轮换时窗口
   过后即可再刷；429/5xx 一律不触发（限流与服务端故障刷目录无用）。
   本文件只做请求与归一化：不落盘、不起服务、不碰 apps/web/public 快照。
   网络可注入（setFetch / 参数 fetch），selftest 全桩离线跑。
   用法：import { fetchObjectList, fetchHourlyAvgPrice } from './ams-client.mjs'
   ============================================================ */

/** 浏览器伪装头：官方接口按 UA + Origin/Referer 校验来源，缺了可能被网关拦 */
const COMMON_HEADERS = {
  'User-Agent':
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
  Origin: 'https://df.qq.com',
  Referer: 'https://df.qq.com/',
}

/** 各流程默认域名：352246 实测在 dfm 子域，其余默认 comm（内置值均双人 curl 复核；
 *  流目录的 sIdeUrl 只兜底内置表没有的 chartId——实测有效的域名不被目录值覆盖） */
const BUILTIN_IDE_URLS = {
  352143: 'https://comm.ams.game.qq.com/ide/',
  352246: 'https://dfm.ams.game.qq.com/ide/',
}
const DEFAULT_IDE_URL = 'https://comm.ams.game.qq.com/ide/'

/** 内置现行 sIdeToken（chartId → token）；流目录刷新后合并覆盖（目录优先） */
const BUILTIN_TOKENS = { 352143: 'YWRywA', 352246: 'Zek01X' }

/** 流目录页：返回 {iRet, sIdeUrl, tokens: {token → chartId 约 71 项}, flows} */
export const FLOW_DIR_URL = 'https://comm.ams.game.qq.com/ide/page/21_3LXYAj'

/** 单请求超时：与仓库 curl 核验口径 --max-time 20 对齐 */
const REQUEST_TIMEOUT_MS = 20000

/**
 * 流目录刷新冷却窗口：daemon 常驻形态下不用「每进程一次」闸——一次瞬时故障
 * 会永久烧掉刷新机会，token 真轮换时反而刷不了。冷却只在刷新**成功**后计时
 * （刷新自身失败不烧冷却），窗口过后允许再刷；429/5xx 根本不触发刷新。
 */
export const FLOW_DIR_REFRESH_COOLDOWN_MS = 10 * 60 * 1000

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/* ---------- 模块态（selftest 用 _resetForTest 清空） ---------- */

let injectedFetch = null
let moduleTokens = { ...BUILTIN_TOKENS } // 流目录刷新后的 token 表（chartId → token）
let moduleIdeUrlFallback = null // 流目录 sIdeUrl：仅兜底内置表未覆盖的 chartId
let lastFlowDirRefreshAt = 0 // 上次流目录刷新**成功**的时刻（0 = 从未）

/** 注入 fetch 替身（selftest 离线桩）；传 null 恢复全局 fetch */
export function setFetch(fn) {
  injectedFetch = fn || null
}

/** 清空全部模块态（selftest 场景隔离专用，业务代码勿调） */
export function _resetForTest() {
  injectedFetch = null
  moduleTokens = { ...BUILTIN_TOKENS }
  moduleIdeUrlFallback = null
  lastFlowDirRefreshAt = 0
}

function getFetch() {
  const f = injectedFetch || globalThis.fetch
  if (!f) throw new Error('当前环境无 fetch（Node ≥18 自带；或先 setFetch 注入）')
  return f
}

/** 北京墙钟当前小时键 YYYYMMDDHH（352246 的 stat_hour 口径；值被忽略但必填） */
export function beijingHourKey(now = new Date()) {
  return new Date(now.getTime() + 8 * 3600 * 1000).toISOString().slice(0, 13).replace(/[-T]/g, '')
}

/* ---------- 流目录（token 兜底） ---------- */

/** 失败症状是否「像 token 问题」：非 JSON 网关页 / 4xx（429 与 5xx 是限流和服务端故障，
 *  刷目录无用且白白多打一枪）/ 流程未发布(-11009，chartId↔token 错配) / sMsg 带凭据类
 *  关键词（词边界匹配——裸子串会把 provide/side/author 等无关文案误判成 token 问题） */
function looksLikeTokenProblem(err) {
  if (err && err.amsNetwork) return false // 断网 / 超时：刷目录同样不可达，不浪费请求
  if (err && err.amsHttpStatus) {
    const s = Number(err.amsHttpStatus)
    return s >= 400 && s < 500 && s !== 429 // 401/403 等客户端侧可疑；429 限流 / 5xx 服务端故障不算
  }
  if (err && err.amsNonJson) return true
  if (err && Number(err.ret) === -11009) return true
  return /\b(?:s?ide_?token|token|sign|publish|invalid|illegal|auth)\b|非法|无权限|未授权/i.test(
    String(err?.sMsg ?? '')
  )
}

/** GET 流目录 → 反转 tokens（token→chartId 变 chartId→token）存模块态。
 *  冷却窗口由 callFlow 掌握；这里只在成功后记时刻（失败不烧冷却） */
async function refreshFlowDirectory() {
  const res = await getFetch()(FLOW_DIR_URL, {
    headers: COMMON_HEADERS,
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  })
  const text = await res.text()
  let data = null
  try {
    data = JSON.parse(text)
  } catch {
    throw Object.assign(new Error(`流目录返回非 JSON: ${text.slice(0, 120)}`), { amsNonJson: true })
  }
  if (Number(data.iRet ?? 0) !== 0) throw new Error(`流目录 iRet=${data.iRet}: ${data.sMsg ?? ''}`)
  const tokens = { ...BUILTIN_TOKENS } // 内置保底，目录值覆盖
  for (const [tok, cid] of Object.entries(data.tokens ?? {})) tokens[Number(cid)] = tok
  moduleTokens = tokens
  if (data.sIdeUrl) {
    const url = /^https?:\/\//.test(data.sIdeUrl) ? data.sIdeUrl : `https://${data.sIdeUrl}`
    moduleIdeUrlFallback = url
  }
  lastFlowDirRefreshAt = Date.now()
  return true
}

/* ---------- 通用流程调用 ---------- */

/** 单次 POST 一个 IDE 流程（表单编码 + JSON 解析 + ret≠0 抛错），不做 token 兜底 */
async function postFlowOnce({ chartId, token, params, ideUrl }) {
  const form = new URLSearchParams()
  form.set('iChartId', String(chartId))
  form.set('iSubChartId', String(chartId))
  form.set('sIdeToken', String(token))
  for (const [k, v] of Object.entries(params || {})) {
    form.set(k, v !== null && typeof v === 'object' ? JSON.stringify(v) : String(v))
  }
  let res
  try {
    res = await getFetch()(ideUrl, {
      method: 'POST',
      headers: { ...COMMON_HEADERS, 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
      body: form.toString(),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    })
  } catch (e) {
    throw Object.assign(new Error(`AMS 请求失败（${chartId}）: ${e.message}`), { amsNetwork: true })
  }
  const text = await res.text()
  if (!res.ok) {
    throw Object.assign(new Error(`AMS HTTP ${res.status}（${chartId}）: ${text.slice(0, 120)}`), {
      amsHttpStatus: res.status,
    })
  }
  let data
  try {
    data = JSON.parse(text)
  } catch {
    // 正文是 JSON 但 Content-Type 是 text/html；这里是真的解析不出 → 多半是网关拦截页
    throw Object.assign(new Error(`AMS 返回非 JSON（${chartId}）: ${text.slice(0, 120)}`), { amsNonJson: true })
  }
  const ret = Number(data.ret ?? data.iRet ?? 0)
  if (ret !== 0) {
    // 错误文案在 sMsg（顶层优先，jData 内兜底）——ret=-11009 表示流程未发布
    const msg = data.sMsg ?? data.jData?.sMsg ?? data.msg ?? data.jData?.msg ?? `ret=${ret}`
    throw Object.assign(new Error(`AMS 流程 ${chartId} ret=${ret}: ${msg}`), { ret, sMsg: msg })
  }
  return data
}

/**
 * 通用 IDE 流程调用（token 兜底链内置）。
 * @param {{chartId:number, token?:string, params?:object, ideUrl?:string}} opts
 *   params 为表单附加字段（object 值自动 JSON.stringify，如 object.list 的 param）；
 *   token 缺省查内置表 → 失败且像 token 问题且不在冷却窗口时刷流目录重试一次（用目录新 token）
 * @returns {Promise<object>} 解析后的完整响应（ret=0）
 * @throws ret≠0 / 非 JSON / HTTP 非 2xx（错误对象带 .ret / .sMsg）
 */
export async function callFlow({ chartId, token, params = {}, ideUrl } = {}) {
  if (!chartId) throw new Error('callFlow 需要 chartId')
  const url = ideUrl ?? BUILTIN_IDE_URLS[chartId] ?? moduleIdeUrlFallback ?? DEFAULT_IDE_URL
  const tok = token ?? moduleTokens[chartId]
  if (!tok) throw new Error(`无 ${chartId} 的 sIdeToken（内置表缺且流目录未刷新到）`)
  try {
    return await postFlowOnce({ chartId, token: tok, params, ideUrl: url })
  } catch (e) {
    // 不像 token 问题 → 如实抛；冷却窗口内（刚刷成过）不再刷——daemon 形态下
    // 刷成后短时间内仍失败，说明问题不在 token，重刷目录无意义
    if (!looksLikeTokenProblem(e)) throw e
    if (Date.now() - lastFlowDirRefreshAt < FLOW_DIR_REFRESH_COOLDOWN_MS) throw e
    try {
      await refreshFlowDirectory() // 失败不记时刻：不烧冷却，下一轮失败仍可再试
    } catch (refreshErr) {
      throw Object.assign(new Error(`${e.message}；（token 兜底：流目录刷新也失败: ${refreshErr.message}）`), {
        ret: e.ret,
        sMsg: e.sMsg,
      })
    }
    // 重试用目录里的新 token；调用方显式传的 token 已被证伪，不再沿用
    const retryTok = moduleTokens[chartId] ?? tok
    return await postFlowOnce({
      chartId,
      token: retryTok,
      params,
      ideUrl: ideUrl ?? BUILTIN_IDE_URLS[chartId] ?? url,
    })
  }
}

/* ---------- 业务封装 ---------- */

const numOrNull = (v) => (v === null || v === undefined || v === '' ? null : Number.isFinite(Number(v)) ? Number(v) : null)

/** object.list 原始条目 → 稳定形状（objectID 统一 String 便于做键；detail 仅存在时透传） */
function normalizeItem(x) {
  const it = {
    objectID: String(x.objectID ?? x.id ?? ''),
    objectName: String(x.objectName ?? ''),
    grade: numOrNull(x.grade),
    primaryClass: x.primaryClass ?? null,
    secondClass: x.secondClass ?? null,
    avgPrice: numOrNull(x.avgPrice),
    pic: x.pic ?? null,
  }
  if (x.gunDetail) it.gunDetail = x.gunDetail
  if (x.ammoDetail) it.ammoDetail = x.ammoDetail
  if (x.protectDetail) it.protectDetail = x.protectDetail
  return it
}

/**
 * 官方物品目录 object.list（chartId 352143，免登录）。
 * @param {{primary:string}} opts primary ∈ gun / ammo / protect / acc / props（逐类单独拉）
 * @returns {Promise<Array<{objectID,objectName,grade,primaryClass,secondClass,avgPrice,pic,
 *   gunDetail?,ammoDetail?,protectDetail?}>>}
 */
export async function fetchObjectList({ primary } = {}) {
  if (!primary) throw new Error('fetchObjectList 需要 primary（gun/ammo/protect/acc/props）')
  const data = await callFlow({
    chartId: 352143,
    params: {
      source: 1,
      method: 'dfm/object.list',
      param: { primary, second: '', third: '', objectID: '' },
    },
  })
  const list = data?.jData?.data?.data?.list
  if (!Array.isArray(list)) {
    throw new Error(`object.list 响应形状异常（primary=${primary}：jData.data.data.list 非数组）`)
  }
  return list.map(normalizeItem)
}

/**
 * 官方小时均价（chartId 352246 @ dfm 域名，免登录；单批硬限 5 个 id）。
 * jData.data 实测（2026-10-26）为 objectID → {avg_buyprice} 直接映射；亦兼容
 * 累计数组形状（取末元素 = 最新一小时），两种口径都给出同一结果。
 * 分批串行（默认 400ms 间隔防压），单批失败记录后继续，不炸整体。
 * @param {Array<string|number>} objectIds
 * @param {{batchSize?:number, paceMs?:number}} opts batchSize 上限 5（上游硬限）
 * @returns {Promise<object>} objectID → avg_buyprice（Number）；失败批的 id 缺席
 */
export async function fetchHourlyAvgPrice(objectIds, { batchSize = 5, paceMs = 400 } = {}) {
  const ids = [...new Set((objectIds || []).map(String))].filter(Boolean)
  const out = {}
  if (!ids.length) return out
  const size = Math.max(1, Math.min(5, batchSize))
  const batches = []
  for (let i = 0; i < ids.length; i += size) batches.push(ids.slice(i, i + size))
  for (let b = 0; b < batches.length; b++) {
    if (b > 0 && paceMs > 0) await sleep(paceMs)
    try {
      const data = await callFlow({
        chartId: 352246,
        params: { propid: batches[b].join(','), stat_hour: beijingHourKey() },
      })
      const payload = data?.jData?.data
      let latest
      if (Array.isArray(payload)) {
        if (!payload.length) throw new Error('jData.data 累计数组为空')
        latest = payload[payload.length - 1]
      } else if (payload && typeof payload === 'object') {
        latest = payload
      } else {
        throw new Error('jData.data 形状异常（非数组非对象映射）')
      }
      for (const id of batches[b]) {
        const v = latest?.[id]
        if (v && Number.isFinite(Number(v.avg_buyprice))) out[id] = Number(v.avg_buyprice)
      }
    } catch (e) {
      console.error(`[ams-client] 352246 批次失败（${batches[b].join(',')}）：${e.message}，跳过继续`)
    }
  }
  return out
}
