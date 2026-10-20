/* ============================================================
   radar.mjs — 全品类异动雷达（子弹以外的钥匙/护甲/配件/物资行情监控）
   ------------------------------------------------------------
   数据管线（2026-10-14 实测定稿，见 README「扩品类数据源」）：
     · 异动物品清单：kkrb「全物品价格变化曲线」页的涨幅榜
       getHIPriceCurveData（Top10，自带 7 天小时曲线，免登录免配额）
     · 曲线主源：moligod /api/market/history?lookup=name —— 不限品类，
       小时级 168 点 + 分钟级尾点（现价取 1m 尾点，比榜单小时曲线新鲜）
     · 双源交叉：同一物品 kkrb 与 moligod 曲线在重叠小时上的中位偏差；
       >15% 判「双源异常」——信号强制观望不发通知（口径分歧时宁可漏报）
   分析复用 scripts/ammo/analyze.mjs 的分位数回归（analyzeItem 纯函数，
   适配 kkrb 原始形状；非子弹无税后字段，税率走 15% 兜底）。
   产物 apps/web/public/market/radar.json（+ 其 dist 联动）；通知去重复用
   notify-policy.judgeSignals，state 落 data/market/radar-state.json。
   注意：kkrb 单物品曲线查询（getQueryItemPriceCurveData）未登录配额为
   0，本脚本不用它；物品名一律以榜单返回的游戏内名称为准（moligod 按
   名查曲线，名称不匹配会拿到旧赛季数据或空曲线）。
   用法：node server/market/radar.mjs [--interval 分钟=30] [--once] [--no-notify]
   ============================================================ */
import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { kkrbRequest } from '../ammo/kkrb-client.mjs'
import { fetchHistory } from '../ammo/moligod-client.mjs'
import { analyzeItem, fmtPrice, fmtPct } from '../ammo/analyze.mjs'
import { judgeSignals, emptyState } from '../ammo/notify-policy.mjs'
import { notify } from '../ammo/notify.mjs'
import { writeJsonAtomic } from '../ammo/fetch-once.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const WEB_DIR = path.join(ROOT, 'apps', 'web')
const OUT_PATH = path.join(WEB_DIR, 'public', 'market', 'radar.json')
const STATE_PATH = path.join(ROOT, 'data', 'market', 'radar-state.json')
const HI_REFERER = 'https://www.kkrb.net/?viewpage=view%2Fmarket%2Fall_item_price_curve'

/** 双源一致性门槛：重叠小时中位偏差超过该值判异常（信号压为观望） */
export const ANOMALY_DEV = 0.15
/** 交叉判定所需最少重叠小时数（低于此不做结论，crossDev 记 null） */
export const MIN_OVERLAP = 24
/** 榜单物品间抓 moligod 曲线的串行间隔（对上游客气一点） */
const PACE_MS = 400

/**
 * 双源曲线中位偏差（纯函数，selftest 覆盖）。
 * @param {Array<[string, number]>} curveA 如 kkrb 榜单曲线
 * @param {Array<[string, number]>} curveB 如 moligod 小时曲线
 * @returns {{overlap:number, medianDev:number|null}} 重叠点数与 |A−B|/B 的中位数；
 *   overlap 不足 MIN_OVERLAP 时 medianDev 为 null（无结论，不判异常）
 */
export function crossDeviation(curveA, curveB) {
  const mapA = new Map(curveA || [])
  const devs = []
  for (const [k, v] of curveB || []) {
    const a = mapA.get(k)
    if (Number.isFinite(a) && a > 0 && Number.isFinite(v) && v > 0) {
      devs.push(Math.abs(a - v) / v)
    }
  }
  if (devs.length < MIN_OVERLAP) return { overlap: devs.length, medianDev: null }
  devs.sort((x, y) => x - y)
  const mid = Math.floor(devs.length / 2)
  const median = devs.length % 2 ? devs[mid] : (devs[mid - 1] + devs[mid]) / 2
  return { overlap: devs.length, medianDev: median }
}

/**
 * 榜单项 + moligod 曲线 → 雷达条目（纯函数，selftest 覆盖）。
 * @param {object} hiItem getHIPriceCurveData 的一个 data.cn 元素
 *   （objectName / itemGrade / pic / objectType / prices{"YYYYMMDDHHmm": price}）
 * @param {{moliCurve?:Array, minuteTail?:number|null}} fetched 预取的 moligod 数据
 *   （moliCurve 小时曲线缺省/太短时回退榜单自带曲线；minuteTail 为 1m 尾点现价）
 */
export function buildRadarItem(hiItem, { moliCurve = [], minuteTail = null } = {}) {
  const kkrbCurve = Object.entries(hiItem.prices || {})
    .map(([k, p]) => [k, Number(p)])
    .filter(([, p]) => Number.isFinite(p) && p > 0)
    .sort(([a], [b]) => (a < b ? -1 : 1))
  // 曲线主源 moligod（与子弹管线同源同口径）；名称对不上时回退榜单曲线
  const curve = (moliCurve || []).length >= 24 ? moliCurve : kkrbCurve
  const cross = crossDeviation(kkrbCurve, moliCurve || [])
  const current =
    (Number.isFinite(minuteTail) && minuteTail > 0 ? minuteTail : null) ??
    (curve.length ? curve[curve.length - 1][1] : null)

  // analyzeItem 吃 kkrb 原始形状；非子弹无税后字段 → 税率兜底 15%
  const analysis = analyzeItem({
    itemName: hiItem.objectName,
    grade: hiItem.itemGrade ?? null,
    pic: hiItem.pic || null,
    currectPrice: current,
    priceCurve: Object.fromEntries(curve),
  })

  const anomaly = cross.medianDev != null && cross.medianDev > ANOMALY_DEV
  return {
    ...analysis,
    hiRank: null, // 由调用方按榜单顺序回填
    category: hiItem.objectType || null,
    crossDev: cross.medianDev,
    crossOverlap: cross.overlap,
    anomaly,
    rawSignal: analysis.signal,
    // 双源口径打架时不发信号：通知层（judgeSignals）只见 WAIT，天然不触发
    signal: anomaly ? 'WAIT' : analysis.signal,
    curveSource: curve === kkrbCurve ? 'kkrb' : 'moligod',
  }
}

/** 雷达快照版本：全部物品曲线最新点键的最大值（12 位 YYYYMMDDHHmm） */
export function deriveVersion(items) {
  let best = ''
  for (const it of items || []) {
    const tail = it.curve && it.curve.length ? it.curve[it.curve.length - 1][0] : ''
    if (typeof tail === 'string' && /^\d{12}$/.test(tail) && tail > best) best = tail
  }
  return best
}

/* ---------- 落盘与状态 ---------- */

async function loadState() {
  try {
    return JSON.parse(await readFile(STATE_PATH, 'utf8'))
  } catch {
    return emptyState()
  }
}

/** 抓一轮榜单 + 逐物品补 moligod 曲线/现价，返回完整雷达条目（涨幅榜原序） */
async function fetchRadarItems({ paceMs = PACE_MS } = {}) {
  const hi = await kkrbRequest('getHIPriceCurveData', {
    body: { globalData: 'false' },
    referer: HI_REFERER,
  })
  const list = Array.isArray(hi.data?.cn) ? hi.data.cn : []
  if (!list.length) throw new Error('涨幅榜为空（上游形状异常？）')

  const items = []
  for (let i = 0; i < list.length; i++) {
    const hiItem = list[i]
    let moliCurve = []
    let minuteTail = null
    try {
      moliCurve = await fetchHistory(hiItem.objectName, { interval: '1h', limit: 168 })
    } catch (e) {
      console.error(`[radar] moligod 曲线失败（仅用榜单曲线）: ${hiItem.objectName} — ${e.message}`)
    }
    try {
      const tail = await fetchHistory(hiItem.objectName, { interval: '1m', limit: 10 })
      if (tail.length) minuteTail = tail[tail.length - 1][1]
    } catch {
      /* 分钟尾点失败不致命：现价回退曲线尾点 */
    }
    items.push(buildRadarItem(hiItem, { moliCurve, minuteTail }))
    if (i < list.length - 1 && paceMs > 0) await new Promise((r) => setTimeout(r, paceMs))
  }
  for (let i = 0; i < items.length; i++) items[i].hiRank = i + 1
  return items
}

/** 雷达通知正文（与子弹通知同骨架；非子弹按「每件」计利润） */
function radarBuyLine(i) {
  return `${i.name} 买入≤${fmtPrice(i.current)} → 挂卖${fmtPrice(i.targetSell)}(到手${fmtPrice(i.netSell)}) 预赚${fmtPrice(i.profitPerRound)}/件(${fmtPct(i.profitPct)})`
}
function radarSellLine(i) {
  return `${i.name} 现价${fmtPrice(i.current)}，处7天${Math.round(i.rank * 100)}%高位，建议挂卖`
}

async function sendRadarNotifications(buys, sells, notifyFn) {
  if (buys.length) {
    const top = buys.slice(0, 3)
    const body = top.map((i) => `🎯 ${radarBuyLine(i)}`).join('\n')
    await notifyFn({
      title: `异动雷达 · 买入信号 ×${buys.length}`,
      body: buys.length > top.length ? body + `\n…还有${buys.length - top.length}项见 #/radar 页` : body,
      sound: 'Glass',
    })
  }
  if (sells.length) {
    const top = sells.slice(0, 3)
    const body = top.map((i) => `📈 ${radarSellLine(i)}`).join('\n')
    await notifyFn({
      title: `异动雷达 · 卖出信号 ×${sells.length}`,
      body: sells.length > top.length ? body + `\n…还有${sells.length - top.length}项见 #/radar 页` : body,
      sound: 'Hero',
    })
  }
}

/**
 * 抓取一轮并落盘。涨幅榜约每小时更新，默认 30 分钟一轮足够，不做指纹
 * 门槛（写频低，原子直写即可）。
 * @returns {Promise<{version:string, items:Array, stats:object}>}
 */
export async function runRadarCycle({ rootDir = ROOT, webDir = rootDir, notifyFn = notify, noNotify = false, state } = {}) {
  const items = await fetchRadarItems()
  const stats = { total: items.length, anomaly: items.filter((i) => i.anomaly).length }
  for (const s of ['BUY', 'SELL', 'WATCH']) stats[s.toLowerCase()] = items.filter((i) => i.signal === s).length
  const out = {
    version: deriveVersion(items),
    fetchedAt: new Date().toISOString(),
    generatedAt: new Date().toISOString(),
    source: 'kkrb-radar+moligod',
    items,
    stats,
  }

  const outPath = path.join(webDir, 'public', 'market', 'radar.json')
  const text = JSON.stringify(out)
  await writeJsonAtomic(outPath, text)
  const distPath = path.join(webDir, 'dist', 'market', 'radar.json')
  if (existsSync(path.dirname(distPath))) await writeJsonAtomic(distPath, text)

  if (state) {
    const { buys, sells } = judgeSignals(state, items)
    if (!noNotify && (buys.length || sells.length)) await sendRadarNotifications(buys, sells, notifyFn)
  }
  return out
}

/* ---------- CLI：单跑 / 常驻监控（被 selftest import 时不执行） ---------- */

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2)
  const flag = (name) => argv.includes(`--${name}`)
  const opt = (name, dflt) => {
    const i = argv.indexOf(`--${name}`)
    return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? Number(argv[i + 1]) : dflt
  }
  const INTERVAL_MIN = opt('interval', 30)
  const ONCE = flag('once')
  const NO_NOTIFY = flag('no-notify')

  const state = await loadState()

  async function cycle() {
    let r
    try {
      r = await runRadarCycle({ state, noNotify: NO_NOTIFY, webDir: WEB_DIR })
    } catch (e) {
      console.error(`[${new Date().toLocaleString('zh-CN')}] 雷达抓取失败: ${e.message}`)
      return
    }
    await writeJsonAtomic(STATE_PATH, JSON.stringify(state))
    const s = r.stats
    console.log(
      `[${new Date().toLocaleString('zh-CN')}] version ${r.version} · 榜单 ${s.total} 项 · 买入 ${s.buy} / 卖出 ${s.sell} / 关注 ${s.watch}` +
        (s.anomaly ? ` / 双源异常 ${s.anomaly}` : ''),
    )
    for (const i of r.items) {
      if (i.signal === 'BUY') {
        console.log(`   🎯 #${i.hiRank} ${i.name} 买≤${fmtPrice(i.current)} 挂卖${fmtPrice(i.targetSell)} 预赚${fmtPrice(i.profitPerRound)}/件(${fmtPct(i.profitPct)})`)
      } else if (i.anomaly) {
        console.log(`   ⚠️ #${i.hiRank} ${i.name} 双源中位偏差 ${(i.crossDev * 100).toFixed(1)}%，信号压制为观望`)
      }
    }
  }

  if (ONCE) {
    await cycle()
  } else {
    console.log(`全品类异动雷达启动：每 ${INTERVAL_MIN} 分钟一轮（Ctrl+C 退出）`)
    await cycle()
    const schedule = () => setTimeout(async () => { await cycle(); schedule() }, INTERVAL_MIN * 60 * 1000)
    schedule()
  }
}
