/* ============================================================
   tradehouse.mjs — 交易行全量市场快照 + 市场指数 + 战备值差价
   ------------------------------------------------------------
   三个上游（2026-11-05 实测，均免登录、同主机 moligod.com）：
     · GET /api/market/trade-house-snapshot —— 全市场 1753 件（当前 1753：
       props 610 / acc ~580 / protect ~250 / ammo ~130 / gun ~69 …），逐件
       现价 / 昨日均价与高低 / 7 日高低 / 品类 / 品级 / 官方图标。响应体为
       公开传输编码（与特勤处快照同族，server/craft/snapshot.mjs 前例）：
       0x01 + 12B IV + AES-256-GCM（尾 16B tag），密钥 = SHA-256(响应头
       x-trade-house-key)，AAD = 'trade-house-snapshot-v1'，明文再套 gzip
     · GET /api/market/preparedness-valuation —— 战备值差价 100 项（明文
       JSON）：system_price（游戏内战备折算价）与 current_price 的差，
       上游已过滤只回差价 > 0 的条目，小时级更新
     · GET /api/market/one-flow-market-prediction —— 集市物品预测 2 项
       （明文 JSON）：带 max_sell_profit 的「低买高卖」预期
   产物（public + dist 联动，契约 shared/API.md §1.5–§1.7）：
     · market/tradehouse.json —— 全量物品（交易行全览页数据源）
     · market/index.json     —— 五大市场指数（level 以「昨日均价合计=1000」
       归一）+ 本服务自积累的小时级指数历史（data/market/tradehouse-
       history.json，逐版本一档、封顶 720 档）+ 预测卡
     · market/loadout.json   —— 战备值差价（小时级，页面轮询不吃 SSE）
   请求预算：每轮 3 请求（上游 ttl 10 分钟级），默认 10 分钟一轮。
   用法：node server/market/tradehouse.mjs [--once] [--interval 分钟=10]
   ============================================================ */
import { createDecipheriv, createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { gunzipSync as gunzip } from 'node:zlib'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { writeSnapshotPair, writeJsonAtomic } from '../ammo/fetch-once.mjs'

const BASE = 'https://moligod.com'
const TRADEHOUSE_URL = `${BASE}/api/market/trade-house-snapshot`
const PREPAREDNESS_URL = `${BASE}/api/market/preparedness-valuation`
const PREDICTION_URL = `${BASE}/api/market/one-flow-market-prediction`
const UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

/** 传输编码常量（与特勤处同族、AAD 不同） */
const WIRE_VERSION = 0x01
const WIRE_IV_LEN = 12
const WIRE_TAG_LEN = 16
const WIRE_AAD = 'trade-house-snapshot-v1'

/** 五大市场（index.json 的固定展示序；sub 层用上游 category_cn 原文） */
export const MARKET_ORDER = ['ammo', 'acc', 'gun', 'props', 'protect']
export const MARKET_LABELS = { ammo: '子弹', acc: '配件', gun: '枪械', props: '物品', protect: '防具' }
/** 指数历史封顶（10 分钟一轮 ≈ 120 点/天，720 点 ≈ 6 天；页内图表取 7 天内实际点数） */
export const HISTORY_CAP = 720

/* ---------- 传输解码（纯函数，selftest 覆盖） ---------- */

/**
 * 解码交易行全量快照的公开传输编码（AAD = trade-house-snapshot-v1）。
 * @param {{body:Uint8Array|Buffer, keyHeader:string}} raw 响应体与 x-trade-house-key 头
 * @returns {Promise<object>} 解出的 JSON 快照
 * @throws 格式版本不符 / 密钥缺失 / 认证失败（密钥不对或密文被改）
 */
export function decodeWireTradehouse({ body, keyHeader }) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(body)
  if (!buf.length) throw new Error('交易行快照响应体为空')
  // 明文 JSON 直通（上游若撤掉传输编码，这里零改动兼容）
  if (buf[0] === 0x7b /* '{' */) return JSON.parse(buf.toString('utf8'))
  if (buf[0] !== WIRE_VERSION) throw new Error(`交易行快照版本字节不符：0x${buf[0].toString(16)}`)
  if (!keyHeader) throw new Error('响应缺少 x-trade-house-key 头')
  if (buf.length <= 1 + WIRE_IV_LEN + WIRE_TAG_LEN) throw new Error('交易行快照密文长度异常')

  const iv = buf.subarray(1, 1 + WIRE_IV_LEN)
  const cipherAndTag = buf.subarray(1 + WIRE_IV_LEN)
  const key = createHash('sha256').update(keyHeader, 'utf8').digest()
  const decipher = createDecipheriv('aes-256-gcm', key, iv)
  decipher.setAAD(Buffer.from(WIRE_AAD, 'utf8'))
  decipher.setAuthTag(cipherAndTag.subarray(cipherAndTag.length - WIRE_TAG_LEN))
  let plain
  try {
    plain = Buffer.concat([decipher.update(cipherAndTag.subarray(0, cipherAndTag.length - WIRE_TAG_LEN)), decipher.final()])
  } catch (e) {
    throw new Error(`交易行快照解密失败（密钥不匹配或密文损坏）：${e.message}`)
  }
  if (plain[0] === 0x1f && plain[1] === 0x8b) plain = gunzip(plain)
  return JSON.parse(plain.toString('utf8'))
}

async function getJson(url) {
  const res = await fetch(url, {
    headers: { 'User-Agent': UA, Accept: 'application/json', Referer: `${BASE}/trade` },
    signal: AbortSignal.timeout(20000),
  })
  if (!res.ok) throw new Error(`HTTP ${res.status} ${new URL(url).pathname}`)
  return res.json()
}

/** 拉一份交易行全量快照（解码后） */
export async function fetchTradehouseRaw() {
  const res = await fetch(TRADEHOUSE_URL, {
    headers: { 'User-Agent': UA, Accept: 'application/json', Referer: `${BASE}/trade` },
    signal: AbortSignal.timeout(20000),
  })
  if (!res.ok) throw new Error(`HTTP ${res.status} trade-house-snapshot`)
  const keyHeader = res.headers.get('x-trade-house-key') || ''
  const body = Buffer.from(await res.arrayBuffer())
  return decodeWireTradehouse({ body, keyHeader })
}

/* ---------- 整形（纯函数，selftest 覆盖） ---------- */

const num = (v) => {
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

/** 交易行条目整形：snake_case → 契约 camelCase */
export function buildTradehouseItem(r) {
  return {
    objectId: String(r.object_id || ''),
    name: r.display_name || r.name,
    alias: r.alias_name || null,
    category: r.category || null,
    categoryCn: r.category_cn || null,
    subcategory: r.subcategory || r.item_subtype || null,
    grade: num(r.grade),
    pic: r.icon_url || null,
    current: num(r.current_price),
    base: num(r.base_price),
    yesterdayAvg: num(r.yesterday_avg_price),
    yesterdayHigh: num(r.yesterday_high),
    yesterdayLow: num(r.yesterday_low),
    sevenDayHigh: num(r.seven_day_high),
    sevenDayLow: num(r.seven_day_low),
    lastUpdate: r.last_update || null,
  }
}

/** 上游全量快照 → 契约快照（纯函数）；version 取全部 last_update 最大值 */
export function buildTradehouseSnapshot(raw, { fetchedAt = new Date().toISOString() } = {}) {
  const rows = Array.isArray(raw?.items) ? raw.items : []
  const items = rows.map(buildTradehouseItem)
  const out = {
    version: deriveVersion(items.map((i) => i.lastUpdate), fetchedAt),
    fetchedAt,
    generatedAt: new Date(Number(raw?.generated_at) || Date.now()).toISOString(),
    source: 'moligod-tradehouse',
    items,
    stats: { total: items.length, priced: items.filter((i) => i.current != null && i.current > 0).length },
  }
  return out
}

/** 'YYYY-MM-DD HH:mm'（北京墙钟）最大值 → 'YYYYMMDDHHmm'；全缺失退回抓取时刻 */
export function deriveVersion(lastUpdates, fallbackIso = new Date().toISOString()) {
  let best = ''
  for (const v of lastUpdates || []) {
    const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$/.exec(String(v || ''))
    if (m) {
      const s = `${m[1]}${m[2]}${m[3]}${m[4]}${m[5]}`
      if (s > best) best = s
    }
  }
  if (/^\d{12}$/.test(best)) return best
  const d = new Date(fallbackIso)
  const p = (n) => String(n).padStart(2, '0')
  const bj = new Date(d.getTime() + 8 * 3600 * 1000)
  return `${bj.getUTCFullYear()}${p(bj.getUTCMonth() + 1)}${p(bj.getUTCDate())}${p(bj.getUTCHours())}${p(bj.getUTCMinutes())}`
}

/* ---------- 指数（纯函数，selftest 覆盖） ----------
   口径（如实标注在页面）：固定篮子 = 该市场内「现价与昨日均价双全」的物品；
   level = 1000 × Σ现价 / Σ昨日均价 —— 即「昨日均价合计 = 1000」的归一读数，
   24h 涨跌幅 = level/1000 − 1。昨日均价是滚动窗口，随其缓慢移动基座平滑，
   日界处可能有轻微跳变（如实，不做平滑修饰）。 */

/** 单市场指数：返回 null 表示篮子为空（如实缺席，不造数） */
export function marketLevel(items) {
  let cur = 0
  let base = 0
  let universe = 0
  for (const it of items) {
    if (it.current > 0 && it.yesterdayAvg > 0) {
      cur += it.current
      base += it.yesterdayAvg
      universe++
    }
  }
  if (!universe) return null
  const level = (1000 * cur) / base
  return { level, change24h: level / 1000 - 1, universe }
}

/** 五大市场 + 总览 + 子市场两级指数 */
export function buildIndexMarkets(items) {
  const byCat = new Map()
  for (const it of items) {
    const c = it.category
    if (!c) continue
    if (!byCat.has(c)) byCat.set(c, [])
    byCat.get(c).push(it)
  }
  const markets = MARKET_ORDER.filter((c) => byCat.has(c)).map((c) => {
    const list = byCat.get(c)
    const top = marketLevel(list)
    const subMap = new Map()
    for (const it of list) {
      const s = it.subcategory || '-'
      if (!subMap.has(s)) subMap.set(s, [])
      subMap.get(s).push(it)
    }
    const subs = [...subMap.entries()]
      .map(([s, list2]) => {
        const m = marketLevel(list2)
        return m && { id: s, label: list2[0].categoryCn || s, universe: m.universe, level: m.level, change24h: m.change24h }
      })
      .filter(Boolean)
      .sort((a, b) => b.universe - a.universe)
    return {
      id: c,
      label: MARKET_LABELS[c] || c,
      level: top?.level ?? null,
      change24h: top?.change24h ?? null,
      universe: top?.universe ?? 0,
      subs,
    }
  })
  const all = marketLevel(items)
  return { all, markets }
}

/**
 * 指数历史追加：逐版本一档（同版本覆盖），超 HISTORY_CAP 截掉最旧的。
 * @param {{points:Array<{t:string, all:number, [cat:string]:number}>}} hist
 * @param {string} version 12 位版本
 * @param {Record<string, number|null>} levels {all, ammo, acc, ...}
 * @returns 新历史对象（不改动入参）
 */
export function appendHistoryPoint(hist, version, levels) {
  const points = Array.isArray(hist?.points) ? hist.points.slice() : []
  const point = { t: version, ...levels }
  const idx = points.findIndex((p) => p.t === version)
  if (idx >= 0) points[idx] = point
  else points.push(point)
  points.sort((a, b) => (a.t < b.t ? -1 : 1))
  while (points.length > HISTORY_CAP) points.shift()
  return { points }
}

/* ---------- 战备值差价与预测（纯函数，selftest 覆盖） ---------- */

export function buildLoadoutItem(r) {
  const current = num(r.current_price)
  const system = num(r.system_price)
  // 上游差价缺发（null/undefined）时现算 system − current；注意 num(null)=0，
  // 必须先显式判空，否则「缺失」会被误当「差价为 0」
  const diffRaw = r.preparedness_diff == null ? null : num(r.preparedness_diff)
  return {
    objectId: String(r.object_id || ''),
    name: r.display_name || r.name,
    category: r.category || null,
    categoryCn: r.category_cn || null,
    subcategory: r.item_subtype || r.subcategory || null,
    grade: num(r.grade),
    pic: r.icon_url || null,
    current,
    system,
    diff: diffRaw ?? (current != null && system != null ? system - current : null),
    lastUpdate: r.last_update || null,
  }
}

export function buildLoadoutSnapshot(raw, { fetchedAt = new Date().toISOString() } = {}) {
  const rows = Array.isArray(raw?.items) ? raw.items : []
  const items = rows.map(buildLoadoutItem)
  return {
    version: deriveVersion(items.map((i) => i.lastUpdate), fetchedAt),
    fetchedAt,
    source: 'moligod-preparedness',
    items,
    stats: {
      total: items.length,
      diffSum: items.reduce((s, i) => s + (i.diff > 0 ? i.diff : 0), 0),
    },
  }
}

export function buildPredictionItems(raw) {
  const rows = Array.isArray(raw?.items) ? raw.items : []
  return rows.map((r) => ({
    objectId: String(r.object_id || ''),
    name: r.display_name || r.name,
    grade: num(r.grade),
    pic: r.icon_url || null,
    current: num(r.current_price),
    maxSellProfit: num(r.max_sell_profit),
    lastUpdate: r.last_update || null,
  }))
}

/* ---------- 循环 ---------- */

const HISTORY_REL = path.join('data', 'market', 'tradehouse-history.json')

async function readHistory(rootDir) {
  try {
    return JSON.parse(await readFile(path.join(rootDir, HISTORY_REL), 'utf8'))
  } catch {
    return { points: [] }
  }
}

/**
 * 抓一轮：三个上游各自隔离——交易行是主产物（失败整轮抛出），战备差价 /
 * 预测失败降级为 null（快照对应字段缺失，页面如实显示「暂无」，不阻塞主链路）。
 * @param {{webDir?:string, rootDir?:string, fetchJson?:Function, fetchWire?:Function, now?:string}} opts
 * @returns {Promise<{version:string, total:number, indexAll:number|null, loadoutTotal:number|null}>}
 */
export async function runTradehouseCycle({ webDir, rootDir, fetchJson = getJson, fetchWire = fetchTradehouseRaw, now } = {}) {
  const dir = webDir || process.cwd()
  const dataDir = rootDir || dir
  const fetchedAt = now ? new Date(now).toISOString() : new Date().toISOString()

  const raw = await fetchWire()
  const snap = buildTradehouseSnapshot(raw, { fetchedAt })
  const { all, markets } = buildIndexMarkets(snap.items)

  // 指数历史：本服务自积累（首次部署从零开始，页内如实标注起算时点）。
  // 只在内存里追加、落盘挪到三份快照写盘之后（见轮尾）——历史积累失败
  // 不得连累主产物
  const levels = { all: all ? round4(all.level) : null }
  for (const m of markets) levels[m.id] = m.level != null ? round4(m.level) : null
  const hist = await readHistory(dataDir)
  const histNew = appendHistoryPoint(hist, snap.version, levels)
  const versionChanged = !hist.points.some((p) => p.t === snap.version)

  const indexSnap = {
    version: snap.version,
    fetchedAt,
    source: 'moligod-tradehouse',
    anchor: '昨日均价合计 = 1000',
    markets,
    all: all ? { level: round4(all.level), change24h: round6(all.change24h), universe: all.universe } : null,
    history: histNew.points,
    historySince: histNew.points[0]?.t || null,
    prediction: null,
    stats: { total: snap.stats.total, priced: snap.stats.priced },
  }
  // 预测卡：失败降级 null（同一上游主机，单独隔离）
  try {
    indexSnap.prediction = buildPredictionItems(await fetchJson(PREDICTION_URL))
  } catch {
    indexSnap.prediction = null
  }

  await writeSnapshotPair(dir, path.join('market', 'tradehouse.json'), JSON.stringify(snap))
  await writeSnapshotPair(dir, path.join('market', 'index.json'), JSON.stringify(indexSnap))

  // 战备值差价：失败降级不写盘（保留上一轮快照，页面照常吃旧数据）
  let loadoutTotal = null
  try {
    const lo = buildLoadoutSnapshot(await fetchJson(PREPAREDNESS_URL), { fetchedAt })
    await writeSnapshotPair(dir, path.join('market', 'loadout.json'), JSON.stringify(lo))
    loadoutTotal = lo.stats.total
  } catch {
    /* 保留旧档 */
  }

  // 指数历史落盘（原在读档后立刻写、失败会连累整轮）：挪到三份快照写盘
  // 之后且降级为日志——主产物已落盘，历史只少本轮一个点，下一轮从盘上
  // 旧档重新追加自愈。写盘复用 writeJsonAtomic（随机 tmp + 失败清理），
  // 替换原 `${p}.${pid}.tmp` 固定名（并发写者会互搬对方半截文件）
  if (versionChanged) {
    try {
      await writeJsonAtomic(path.join(dataDir, HISTORY_REL), JSON.stringify(histNew))
    } catch (e) {
      console.error(`[tradehouse] 指数历史落盘失败（不影响快照主产物）: ${e.message}`)
    }
  }

  return { version: snap.version, total: snap.stats.total, indexAll: indexSnap.all?.level ?? null, loadoutTotal }
}

const round4 = (n) => Math.round(n * 1e4) / 1e4
const round6 = (n) => Math.round(n * 1e6) / 1e6

/* ---------- CLI：单跑 / 常驻监控（selftest import 时不执行） ---------- */

const IS_CLI =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)

if (IS_CLI) {
  const argv = process.argv.slice(2)
  const INTERVAL_MIN = argv.includes('--interval') ? Number(argv[argv.indexOf('--interval') + 1]) || 10 : 10
  const ONCE = argv.includes('--once')
  const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
  const WEB_DIR = path.join(ROOT, 'apps', 'web')

  async function cycle() {
    try {
      const r = await runTradehouseCycle({ webDir: WEB_DIR, rootDir: ROOT })
      console.log(
        `[${new Date().toLocaleString('zh-CN')}] version ${r.version} · 全市场 ${r.total} 件 · 总指数 ${r.indexAll?.toFixed(1) ?? '—'} · 战备差价 ${r.loadoutTotal ?? '保留旧档'}`,
      )
    } catch (e) {
      console.error(`[${new Date().toLocaleString('zh-CN')}] 交易行快照抓取失败: ${e.message}`)
    }
  }

  if (ONCE) {
    await cycle()
  } else {
    console.log(`交易行全量快照监控启动：每 ${INTERVAL_MIN} 分钟一轮（Ctrl+C 退出）`)
    await cycle()
    const schedule = () => setTimeout(async () => { await cycle(); schedule() }, INTERVAL_MIN * 60 * 1000)
    schedule()
  }
}
