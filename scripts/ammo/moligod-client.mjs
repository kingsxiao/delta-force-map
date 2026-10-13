/* ============================================================
   moligod-client.mjs — 三角洲攻略站（moligod.com）子弹行情客户端【主源】
   ------------------------------------------------------------
   数据源：moligod.com 社区行情站（2026-10-13 实测，接口无鉴权）：
     · GET /api/market/ammo-catalog
       67 种子弹：latest_price 现价 + today/yesterday/seven_day 高低点，
       last_update 分钟位滚动（ttl_seconds=60，分钟级推进）
     · GET /api/market/history?name=<enc>&interval=1h&limit=168&lookup=name
       近 7 天小时级曲线，明文 JSON：{status:'ok', data:[{time:'MM-DD HH:mm',
       avg, min, max, last}, ...]}（time 无年份，按北京时间跨年补年）
   注意：响应体恒为裸 gzip 且不带 Content-Encoding 头（浏览器同源自动解，
   Node fetch 不会自动解）——需 arrayBuffer + node:zlib 手动 gunzip。
   输出适配为 kkrb-client 的原始快照形状（itemName / grade / pic /
   currectPrice / priceCurve），下游 analyze.mjs 零改动；moligod 无税后
   字段，税率自动回退 15%（analyze.mjs 既有兜底）。
   曲线缓存为模块态（fast / auto / full 路径共享，TTL 30 分钟）：
     · fast：只打 1 次 catalog，曲线全部取缓存，绝不补发 history 请求
     · auto：只补抓缺失 / 过期（≥30min）的曲线（monitor 每轮、live 慢环用）
     · full：全部曲线串行重抓（默认 400ms 间隔，CLI / live 冷启动用）
   进程重启可从 public/ammo/market.json 的 items[].curve 预热（见
   primeCurveCache），避免每次启动都全量打 history 接口。
   ============================================================ */
import { gunzipSync } from 'node:zlib'

const BASE = 'https://moligod.com'
const UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
/** catalog 低于该条数视为形状异常（实测 67；防上游改版后静默产出残缺快照） */
const CATALOG_MIN_ITEMS = 50
/** 曲线缓存 TTL：live 慢环 30min 对齐，到期后 auto 路径才重抓 */
export const CURVE_TTL_MS = 30 * 60 * 1000

const curveCache = new Map() // name -> { points: [[key, price], ...], fetchedAt }

/* ---------- 北京时间工具（上游时间为东八区墙钟，无时区标记） ---------- */
const TZ_OFFSET_MS = 8 * 3600 * 1000
const pad2 = (n) => String(n).padStart(2, '0')

/** 把任意时刻映射为北京墙钟分量（用 +8 平移后取 ISO 各位，无 DST 问题） */
export function beijingParts(date = new Date()) {
  const s = new Date(date.getTime() + TZ_OFFSET_MS).toISOString()
  return {
    year: Number(s.slice(0, 4)),
    month: Number(s.slice(5, 7)),
    day: Number(s.slice(8, 10)),
    hour: Number(s.slice(11, 13)),
    minute: Number(s.slice(14, 16)),
  }
}

/**
 * history 的 time 形如 'MM-DD HH:mm'，无年份。默认取当年；若结果比北京
 * 时间 now 晚超过 1 天（年初取到去年 12 月的尾巴），判为上一年。
 * @returns {number|null} 四位年份，格式不符返回 null
 */
export function inferYear(timeStr, now = new Date()) {
  const m = /^(\d{2})-(\d{2}) (\d{2}):(\d{2})$/.exec(String(timeStr || '').trim())
  if (!m) return null
  const [, mo, d, h, mi] = m
  const p = beijingParts(now)
  // 候选与 now 都投影到「Date.UTC(墙钟分量)」的同一平移帧，比较自洽
  const candidate = (y) => Date.UTC(y, mo - 1, d, h, mi)
  const nowShift = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute)
  let year = p.year
  if (candidate(year) - nowShift > 24 * 3600 * 1000) year -= 1
  return year
}

/** 'MM-DD HH:mm' → 'YYYYMMDDHHmm'（与 kkrb priceCurve 键同构），失败返回 null */
export function historyTimeToKey(timeStr, now = new Date()) {
  const m = /^(\d{2})-(\d{2}) (\d{2}):(\d{2})$/.exec(String(timeStr || '').trim())
  if (!m) return null
  const y = inferYear(timeStr, now)
  if (y == null) return null
  return `${y}${m[1]}${m[2]}${m[3]}${m[4]}`
}

/* ---------- HTTP（裸 gzip 手动解压） ---------- */
async function httpGetJson(url) {
  const res = await fetch(url, {
    headers: { 'User-Agent': UA, Accept: 'application/json', Referer: BASE + '/market/ammo' },
  })
  if (!res.ok) throw new Error(`HTTP ${res.status} ${url.replace(/\?.*/, '')}`)
  const buf = Buffer.from(await res.arrayBuffer())
  const text = buf[0] === 0x1f && buf[1] === 0x8b ? gunzipSync(buf).toString('utf8') : buf.toString('utf8')
  return JSON.parse(text)
}

/** catalog 快照（已做形状校验；失败 throw，由调用方决定重试/回落） */
export async function fetchCatalog() {
  const j = await httpGetJson(`${BASE}/api/market/ammo-catalog`)
  if (!j || j.status !== 'ok' || !Array.isArray(j.items) || j.items.length < CATALOG_MIN_ITEMS) {
    throw new Error(`ammo-catalog 形状异常 status=${j && j.status} items=${j && j.items && j.items.length}`)
  }
  return j
}

/**
 * 单弹小时级曲线 → [[key, price], ...]（时间升序）。
 * 点价优先 last（小时末成交），缺省退 avg。
 */
export async function fetchHistory(name, { interval = '1h', limit = 168 } = {}) {
  const u =
    `${BASE}/api/market/history?name=${encodeURIComponent(name)}` +
    `&interval=${interval}&limit=${limit}&lookup=name`
  const j = await httpGetJson(u)
  if (!j || j.status !== 'ok' || !Array.isArray(j.data)) {
    throw new Error(`history 形状异常 name=${name} status=${j && j.status}`)
  }
  const now = new Date()
  const points = []
  for (const p of j.data) {
    const key = historyTimeToKey(p.time, now)
    const last = Number(p.last)
    const avg = Number(p.avg)
    const price = Number.isFinite(last) && last > 0 ? last : avg
    if (key && Number.isFinite(price) && price > 0) points.push([key, price])
  }
  points.sort(([a], [b]) => (a < b ? -1 : 1))
  return points
}

/* ---------- 曲线缓存（模块态） ---------- */
const isFresh = (entry) => entry && Date.now() - entry.fetchedAt < CURVE_TTL_MS

/** 从既有 market.json 的 items[].curve 预热缓存（live/monitor 启动时调用；
 *  fetchedAt 可注入，selftest 用它构造「已过期」缓存） */
export function primeCurveCache(items, { fetchedAt = Date.now() } = {}) {
  for (const it of items || []) {
    if (it && it.name && Array.isArray(it.curve) && it.curve.length) {
      curveCache.set(it.name, { points: it.curve, fetchedAt })
    }
  }
}

/** 给定名称集合的缓存覆盖情况（live 冷启动判断、selftest 断言用） */
export function curveCacheStats(names) {
  let fresh = 0
  let stale = 0
  for (const n of names || []) {
    if (isFresh(curveCache.get(n))) fresh++
    else stale++
  }
  return { fresh, stale, total: (names || []).length }
}

/** 清空缓存（selftest 用） */
export function clearCurveCache() {
  curveCache.clear()
}

/**
 * 组装一份 kkrb 形状的完整快照（供 fetch-once / analyze 消费）。
 * @param {{mode?:'fast'|'auto'|'full', paceMs?:number}} opts
 *   fast  只打 1 次 catalog，曲线全取缓存（缺失 → 该弹 priceCurve 为空，
 *         analyze 判「数据不足」）——绝不补发 history 请求
 *   auto  只补抓缺失 / 过期（≥ CURVE_TTL_MS）的曲线
 *   full  全部曲线串行重抓（paceMs 默认 400ms，约 45s 铺完 67 条）
 * @returns {Promise<{code:number, version:string, source:'moligod',
 *                     data:Array, fetchedAt:string}>} kkrb 原始形状
 */
export async function getSnapshot({ mode = 'auto', paceMs = 400 } = {}) {
  const catalog = await fetchCatalog()
  const names = catalog.items.map((i) => i.name)

  if (mode === 'auto' || mode === 'full') {
    const need = names.filter((n) => (mode === 'full' ? true : !isFresh(curveCache.get(n))))
    for (let i = 0; i < need.length; i++) {
      const name = need[i]
      try {
        curveCache.set(name, { points: await fetchHistory(name), fetchedAt: Date.now() })
      } catch (e) {
        // 单弹曲线失败不炸整份快照：沿用旧缓存（可能已过期）或留空判「数据不足」，
        // 下一轮 auto 会重试该弹；绝不把失败写进落盘数据。
        console.error(`[moligod] history 失败（沿用旧曲线/留空）: ${name} — ${e.message}`)
      }
      if (i < need.length - 1 && paceMs > 0) await new Promise((r) => setTimeout(r, paceMs))
    }
  }

  const fetchedAt = new Date().toISOString()
  return {
    code: 1,
    version: versionFromCatalog(catalog, fetchedAt),
    source: 'moligod',
    data: catalog.items.map((it) => ({
      itemName: it.name,
      grade: Number(it.grade) || null,
      pic: it.icon_url || null,
      currectPrice: Number.isFinite(Number(it.latest_price)) && Number(it.latest_price) > 0
        ? Number(it.latest_price)
        : null,
      priceCurve: Object.fromEntries(curveCache.get(it.name)?.points || []),
    })),
    fetchedAt,
  }
}

/**
 * 用数据自身的时钟（today_price_day_key + 各弹 last_update 的最大值）
 * 生成 12 位分钟级 version（YYYYMMDDHHmm，北京时间）。字段缺失时退回
 * 抓取时刻。version 只在源真正滚动分钟时变化，天然适合做留档名/展示。
 */
function versionFromCatalog(catalog, fetchedAtIso) {
  let best = ''
  for (const it of catalog.items) {
    const day = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(it.today_price_day_key || ''))
    const time = /^(\d{2}):(\d{2})/.exec(String(it.last_update || ''))
    if (day && time) {
      const v = `${day[1]}${day[2]}${day[3]}${time[1]}${time[2]}`
      if (v > best) best = v
    }
  }
  if (/^\d{12}$/.test(best)) return best
  const p = beijingParts(new Date(fetchedAtIso))
  return `${p.year}${pad2(p.month)}${pad2(p.day)}${pad2(p.hour)}${pad2(p.minute)}`
}
