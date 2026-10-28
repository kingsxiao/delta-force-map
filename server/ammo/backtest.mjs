/* ============================================================
   backtest.mjs — 买卖信号 walk-forward 回测 + 参数网格（离线，零依赖）
   ------------------------------------------------------------
   数据：data/ammo/history/*.json + apps/web/public/ammo/market.json
   （analyze 产物，items[].curve 为 7 天小时级 [key, price]）。
   方法：逐物品逐小时 t 预计算特征（只用截至当时的数据，杜绝未来函数），
   变体 = 特征谓词 → 入场；离场规则统一（只比入场质量）：
     · 止盈 TP：价格 ≥ targetSell → net = target×(1−税)
     · 止损 SL：价格 ≤ stop（7天低点下方 3%，且不深于入场价 −5%）→ net 同口径
     · 超时 72h / 数据走完 → 按当时价净离场（OPEN 单列）
   同一 (物品, 入场时刻) 跨快照去重（新快照优先）。
   用法：node server/ammo/backtest.mjs [--grid] [--json]
   ============================================================ */
import { readFile, readdir } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const MAX_HOLD_H = 72
const TAX_FALLBACK = 0.15

/* ---------- 基础统计（与 analyze.mjs 同口径） ---------- */
function quantile(sorted, p) {
  const pos = (sorted.length - 1) * p
  const lo = Math.floor(pos)
  const hi = Math.ceil(pos)
  if (lo === hi) return sorted[lo]
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo)
}
/** 近 n 小时最小二乘斜率（%/h，相对区间均值归一） */
function slopePctPerH(prices, n) {
  const s = prices.slice(-n)
  if (s.length < 2) return 0
  const mean = s.reduce((a, b) => a + b, 0) / s.length
  if (!(mean > 0)) return 0
  let sx = 0, sy = 0, sxx = 0, sxy = 0
  for (let i = 0; i < s.length; i++) { sx += i; sy += s[i]; sxx += i * i; sxy += i * s[i] }
  const k = s.length
  return ((k * sxy - sx * sy) / (k * sxx - sx * sx) / mean) * 100
}

/* ---------- 特征预计算 ---------- */
/** 单物品全时间轴特征：每 t 一个对象（t 从 24 起） */
function buildFeatures(curve, tax) {
  const feats = []
  let lowIdx = -1
  for (let t = 0; t < curve.length; t++) {
    if (lowIdx < 0 || curve[t][1] < curve[lowIdx][1]) lowIdx = t
    if (t < 24) { feats.push(null); continue }
    const hist = curve.slice(0, t + 1).map((p) => p[1])
    const cur = curve[t][1]
    const sorted = [...hist].sort((a, b) => a - b)
    const loc = curve.slice(Math.max(0, t - 71), t + 1).map((p) => p[1])
    const locSorted = [...loc].sort((a, b) => a - b)
    feats.push({
      key: curve[t][0], cur, tax, n: hist.length,
      rank: hist.filter((v) => v <= cur).length / hist.length,
      p75: quantile(sorted, 0.75),
      p75loc: quantile(locSorted, 0.75),
      weekLow: sorted[0],
      lowAgeH: t - lowIdx,
      slope48: slopePctPerH(hist, 48),
      sma24: hist.slice(-24).reduce((a, b) => a + b, 0) / Math.min(24, hist.length),
    })
  }
  return feats
}

/* ---------- 变体定义 ---------- */
/** old：改动前现网口径（rank≤0.25 + 净利 ≥8% vs 7天P75，无趋势过滤） */
const VARIANTS = {
  old: { enter: (f) => f.rank <= 0.25 && f.p75 * (1 - f.tax) - f.cur > 0 && (f.p75 * (1 - f.tax) - f.cur) / f.cur >= 0.08, target: (f) => f.p75 },
}
/* prod：直接跑生产 analyzeItem（回测/上线同源，防两套口径漂移）；
   RULES 供 --mkt-min 扫描临时改市场体制门槛后复位 */
const { analyzeItem, RULES } = await import('./analyze.mjs')

/* ---------- 数据与去重 ---------- */
async function loadAll() {
  const files = []
  const histDir = path.join(ROOT, 'data', 'ammo', 'history')
  if (existsSync(histDir)) for (const f of await readdir(histDir)) if (f.endsWith('.json')) files.push(path.join(histDir, f))
  files.sort()
  const live = path.join(ROOT, 'apps', 'web', 'public', 'ammo', 'market.json')
  if (existsSync(live)) files.push(live)
  // 深历史（21 天，node server/ammo/fetch-deep.mjs 生成）优先级最高
  const deep = path.join(ROOT, 'data', 'ammo', 'backtest-deep.json')
  if (existsSync(deep)) files.push(deep)
  const out = []
  for (let f = files.length - 1; f >= 0; f--) {
    try {
      const j = JSON.parse(await readFile(files[f], 'utf8'))
      if (Array.isArray(j.items)) out.push(j.items)
    } catch { /* 坏档跳过 */ }
  }
  return out
}

/* ---------- 单变体回测 ---------- */
function runVariant(itemFeats, enter, target, stopPct = 0.05, maxHoldH = MAX_HOLD_H) {
  const trades = []
  for (const { feats } of itemFeats) {
    let pos = null
    for (let t = 24; t < feats.length; t++) {
      const f = feats[t]
      if (!f) continue
      const cur = f.cur
      if (pos) {
        const held = t - pos.entryT
        if (cur <= pos.stop) { trades.push(fin(pos, cur, 'SL', held, f)); pos = null }
        else if (cur >= pos.target) { trades.push(fin(pos, cur, 'TP', held, f)); pos = null }
        else if (held >= maxHoldH) { trades.push(fin(pos, cur, 'TIME', held, f)); pos = null }
      }
      if (!pos && t < feats.length - 2 && enter(f)) {
        pos = { name: f.name, entryT: t, entry: cur, target: target(f), stop: Math.max(f.weekLow * 0.97, cur * (1 - stopPct)) }
      }
    }
    if (pos) {
      const f = feats[feats.length - 1]
      trades.push(fin(pos, f.cur, 'OPEN', feats.length - 1 - pos.entryT, f))
    }
  }
  return trades
}
function fin(pos, exitPrice, reason, heldH, f) {
  const net = exitPrice * (1 - f.tax)
  return { name: pos.name, entry: pos.entry, net, reason, heldH, retPct: (net - pos.entry) / pos.entry }
}
function summarize(trades) {
  const closed = trades.filter((r) => r.reason !== 'OPEN')
  const wins = closed.filter((r) => r.retPct > 0)
  const rets = closed.map((r) => r.retPct).sort((a, b) => a - b)
  return {
    trades: closed.length, open: trades.length - closed.length,
    winRate: closed.length ? +((wins.length / closed.length) * 100).toFixed(1) : null,
    meanRetPct: closed.length ? +(closed.reduce((a, r) => a + r.retPct, 0) / closed.length * 100).toFixed(2) : null,
    worstRetPct: rets.length ? +(rets[0] * 100).toFixed(2) : null,
    totalRetPct: +(closed.reduce((a, r) => a + r.retPct, 0) * 100).toFixed(1),
    avgHoldH: closed.length ? +(closed.reduce((a, r) => a + r.heldH, 0) / closed.length).toFixed(1) : null,
    byReason: closed.reduce((m, r) => ((m[r.reason] = (m[r.reason] || 0) + 1), m), {}),
  }
}

/* ---------- 主流程 ---------- */
const AS_JSON = process.argv.includes('--json')
const GRID = process.argv.includes('--grid')

const snaps = await loadAll()
// 特征与市场体制（逐时间键全弹种 48h 斜率中位），跨快照按 (name, key) 去重
const seen = new Set()
const itemFeats = []
{
  const mktSlope = new Map()
  const slopeLists = new Map()
  for (const items of snaps) {
    for (const it of items || []) {
      const curve = Array.isArray(it.curve) ? it.curve.filter((p) => Number.isFinite(p[1]) && p[1] > 0) : []
      if (curve.length < 72) continue
      for (let t = 47; t < curve.length; t++) {
        const k = curve[t][0]
        if (!slopeLists.has(k)) slopeLists.set(k, [])
        slopeLists.get(k).push(slopePctPerH(curve.slice(t - 47, t + 1).map((p) => p[1]), 48))
      }
    }
  }
  for (const [k, list] of slopeLists) {
    list.sort((a, b) => a - b)
    mktSlope.set(k, list[list.length >> 1])
  }
  for (const items of snaps) {
    for (const it of items || []) {
      const curve = Array.isArray(it.curve) ? it.curve.filter((p) => Number.isFinite(p[1]) && p[1] > 0) : []
      if (curve.length < 72) continue
      const tax = Number.isFinite(it.taxRate) && it.taxRate > 0 ? it.taxRate : TAX_FALLBACK
      const feats = buildFeatures(curve, tax).map((f, t) => {
        if (!f) return null
        const tag = `${it.name}|${f.key}`
        if (seen.has(tag)) return null // 老快照重复时刻，跳过
        seen.add(tag)
        f.name = it.name
        f.t = t
        f.mktSlope = mktSlope.get(f.key) ?? null
        return f
      })
      itemFeats.push({ curve, feats })
    }
  }
}

if (GRID) {
  // 网格 2：在胜出形态（72h 局部目标 + bounce/lowAge/slope）上扫出场与入场深度
  const grid = []
  const base = { lowAge: 12, slope: 0.02, mkt: false, t7d: false }
  for (const bounce of [0.03, 0.05])
    for (const minPct of [0.08, 0.1, 0.12])
      for (const rankMax of [0.2, 0.25])
        for (const stopPct of [0.03, 0.04, 0.05])
          for (const maxHold of [48, 72, 168]) {
            const p = { ...base, bounce, minPct, rankMax, stopPct, maxHold }
            const enter = (f) =>
              f.rank <= p.rankMax &&
              (f.p75loc * (1 - f.tax) - f.cur) / f.cur >= p.minPct &&
              f.n >= 48 &&
              f.cur >= f.weekLow * (1 + p.bounce) &&
              f.lowAgeH >= p.lowAge &&
              f.slope48 >= p.slope
            const trades = runVariant(itemFeats, enter, (f) => f.p75loc, p.stopPct, p.maxHold)
            const s = summarize(trades)
            grid.push({ p, s })
          }
  grid.sort((a, b) => b.s.totalRetPct - a.s.totalRetPct)
  console.log('网格 2（21 天深样本，按总收益排序）— 前 16：')
  for (const { p, s } of grid.slice(0, 16)) {
    console.log(
      `bounce=${p.bounce} minPct=${p.minPct} rank≤${p.rankMax} stop=${(p.stopPct * 100).toFixed(0)}% hold≤${String(p.maxHold).padStart(3)}h` .padEnd(64) +
      ` trades=${String(s.trades).padStart(3)}${s.trades < 10 ? '*' : ' '} 胜率=${String(s.winRate).padStart(5)}% 均值=${String(s.meanRetPct).padStart(7)}% 总=${String(s.totalRetPct).padStart(8)}%`,
    )
  }
  const oldS = summarize(runVariant(itemFeats, VARIANTS.old.enter, VARIANTS.old.target))
  console.log('\nold 基线:', JSON.stringify(oldS))
} else {
  const out = {}
  for (const [name, v] of Object.entries(VARIANTS)) {
    const trades = runVariant(itemFeats, (f) => v.enter(f), (f) => v.target(f))
    out[name] = { summary: summarize(trades), trades }
  }
  {
    const trades = runProd(itemFeats)
    out.prod = { summary: summarize(trades), trades }
  }
  if (AS_JSON) {
    console.log(JSON.stringify({ old: out.old.summary, prod: out.prod.summary, prodTrades: out.prod.trades }, null, 1))
  } else {
    for (const [name, r] of Object.entries(out)) console.log(name.padEnd(5), JSON.stringify(r.summary))
    console.log('\n— prod（生产算法）交易明细 —')
    for (const r of out.prod.trades) console.log(`  ${r.name} ${r.reason} 净${Math.round(r.net)} (${(r.retPct * 100).toFixed(1)}%, ${r.heldH}h)`)
  }
}

/* prod 路径：逐时刻喂截断曲线给生产 analyzeItem，信号/目标/止损全用其输出。
   市场体制 ctx 逐时刻取已算好的全弹 48h 斜率中位（mktSlope Map，跨物品同键），
   与生产 analyzeMarket 的「全弹中位」同构——回测/上线同一门槛口径 */
function runProd(itemFeats) {
  const trades = []
  for (const { curve, feats } of itemFeats) {
    let pos = null
    for (let t = 24; t < feats.length; t++) {
      const f = feats[t]
      if (!f) continue
      if (pos) {
        const held = t - pos.entryT
        if (f.cur <= pos.stop) { trades.push(fin(pos, f.cur, 'SL', held, f)); pos = null }
        else if (f.cur >= pos.target) { trades.push(fin(pos, f.cur, 'TP', held, f)); pos = null }
        else if (held >= pos.maxHoldH) { trades.push(fin(pos, f.cur, 'TIME', held, f)); pos = null }
      }
      if (!pos && t < feats.length - 2) {
        const ctx = Number.isFinite(f.mktSlope) ? { mktSlope48: f.mktSlope } : {}
        const res = analyzeItem({ itemName: f.name, currectPrice: f.cur, priceCurve: Object.fromEntries(curve.slice(0, f.t + 1)) }, ctx)
        if (res.signal === 'BUY') {
          pos = { name: f.name, entryT: t, entry: f.cur, target: res.targetSell, stop: res.stopLoss, maxHoldH: res.maxHoldH || MAX_HOLD_H }
        }
      }
    }
    if (pos) {
      const f = feats[feats.length - 1]
      trades.push(fin(pos, f.cur, 'OPEN', feats.length - 1 - pos.entryT, f))
    }
  }
  return trades
}

/* --mkt-min：市场体制门槛扫描（临时改 RULES 后逐档重跑 prod 路径，跑完复位）。
   判据：门槛加入后胜率 / 单笔均值应升、笔数降幅可接受（宁缺毋滥口径）；
   全档都不改善即 BUY_MKT_SLOPE_MIN 保持 -Infinity（关闭） */
if (process.argv.includes('--mkt-min')) {
  const prod0 = RULES.BUY_MKT_SLOPE_MIN
  console.log('市场体制门槛扫描（prod 路径，其余参数不变）：')
  for (const min of [-Infinity, 0, 0.02, 0.05]) {
    RULES.BUY_MKT_SLOPE_MIN = min
    const s = summarize(runProd(itemFeats))
    const label = min === -Infinity ? '关闭' : `≥${min}`
    console.log(`  mktSlope ${String(label).padEnd(6)} trades=${String(s.trades).padStart(3)} 胜率=${String(s.winRate).padStart(5)}% 均值=${String(s.meanRetPct).padStart(7)}% 总=${String(s.totalRetPct).padStart(8)}% worst=${String(s.worstRetPct).padStart(7)}%`)
  }
  RULES.BUY_MKT_SLOPE_MIN = prod0
}
