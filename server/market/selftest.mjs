/* ============================================================
   selftest.mjs — 异动雷达纯逻辑离线自测（node 直接运行，零依赖零外网）
   ------------------------------------------------------------
   覆盖（radar.mjs 的可测面，不含网络路径）：
     ① crossDeviation：同曲线偏差 0 / 不足 24 重叠点无结论 / 中位数抗
        尖峰离群 / 空输入
     ② buildRadarItem 适配层：BUY·SELL 信号命中（复用 analyze 分位回归）、
        分钟尾点作现价、moligod 曲线过短回退榜单曲线、税后字段缺失走
        15% 兜底税率
     ③ 双源异常门：中位偏差 >15% → anomaly 且 signal 压制 WAIT，
        rawSignal 保留原判定（通知层只见 WAIT，天然不触发）
     ④ deriveVersion：跨物品取曲线最新点键的最大 12 位版本
   全部通过 exit 0；失败写 stderr 后 exit 1。
   用法：node scripts/market/selftest.mjs
   ============================================================ */
import { crossDeviation, buildRadarItem, deriveVersion, ANOMALY_DEV, MIN_OVERLAP } from './radar.mjs'

function assert(cond, msg) {
  if (!cond) throw new Error(msg)
}
const checks = []
const check = (name, fn) => checks.push([name, fn])

/* ---------- fixture：48 个小时点（YYYYMMDDHHmm 键），2026-10-01 00 时起 ---------- */
const KEYS = Array.from({ length: 48 }, (_, i) => {
  const d = new Date(Date.UTC(2026, 9, 1) + i * 3600 * 1000)
  const p = (n) => String(n).padStart(2, '0')
  return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}00`
})

/** 基准曲线：100↔200 锯齿（现价 100/200 的分位均为 0.5/1） */
const zigzag = KEYS.map((k, i) => [k, 100 + Math.round(100 * (i % 2))])
/** 低位尾曲线：前 36 点 150、后 12 点 100——现价 100 的分位恰为 12/48=0.25（BUY 门槛），
 *  P75=150 → 税后 127.5，收益率 27.5%（≥8%） */
const lowTail = KEYS.map((k, i) => [k, i < 36 ? 150 : 100])
const hiItem = (prices, { name = '测试物资', grade = 5, type = 'props' } = {}) => ({
  objectName: name,
  itemGrade: grade,
  objectType: type,
  pic: null,
  prices: Object.fromEntries(prices),
})

check('crossDeviation：同曲线 → 中位偏差 0', () => {
  const r = crossDeviation(zigzag, zigzag)
  assert(r.overlap === 48, `overlap=${r.overlap}`)
  assert(r.medianDev === 0, `medianDev=${r.medianDev}`)
})

check(`crossDeviation：重叠 < ${MIN_OVERLAP} → 无结论（null）`, () => {
  const short = zigzag.slice(0, 10)
  const r = crossDeviation(short, short)
  assert(r.overlap === 10, `overlap=${r.overlap}`)
  assert(r.medianDev === null, 'medianDev 应为 null')
})

check('crossDeviation：中位数按多数定调，不被少数尖峰拉爆', () => {
  // 48 点中 12 点（1/4）抬高 50%，其余一致：中位数仍为 0
  const b = zigzag.map(([k, v], i) => [k, i % 4 === 0 ? v * 1.5 : v])
  const r = crossDeviation(zigzag, b)
  assert(r.medianDev === 0, `medianDev=${r.medianDev}`)
  // 36 点（3/4 多数）抬 50% → 中位偏差取多数档 0.5/1.5 = 1/3
  const c = zigzag.map(([k, v], i) => [k, i % 4 !== 0 ? v * 1.5 : v])
  const r2 = crossDeviation(zigzag, c)
  assert(Math.abs(r2.medianDev - 1 / 3) < 1e-9, `medianDev=${r2.medianDev}`)
})

check('crossDeviation：空输入不炸', () => {
  const r = crossDeviation([], [])
  assert(r.overlap === 0 && r.medianDev === null, JSON.stringify(r))
})

check('buildRadarItem：低位+税后利润达标 → BUY，现价取分钟尾点', () => {
  const it = buildRadarItem(hiItem(lowTail), { moliCurve: lowTail, minuteTail: 100 })
  assert(it.signal === 'BUY', `signal=${it.signal}`)
  assert(it.current === 100, `current=${it.current}`)
  assert(it.taxRate === 0.15, '非子弹无税后字段应兜底 15%')
  assert(it.curveSource === 'moligod', it.curveSource)
  assert(it.anomaly === false && it.crossDev === 0, '同曲线不应异常')
  assert(it.category === 'props', `category=${it.category}`)
})

check('buildRadarItem：高位 → SELL；分钟尾点覆盖曲线尾点', () => {
  const it = buildRadarItem(hiItem(lowTail), { moliCurve: lowTail, minuteTail: 200 })
  assert(it.signal === 'SELL', `signal=${it.signal}`)
  assert(it.current === 200, `current=${it.current}`)
})

check('buildRadarItem：moligod 曲线过短（<24 点）→ 回退榜单曲线', () => {
  const it = buildRadarItem(hiItem(zigzag), { moliCurve: zigzag.slice(-5), minuteTail: null })
  assert(it.curveSource === 'kkrb-radar', it.curveSource) // 枚举对齐 schema：["moligod","kkrb-radar"]
  assert(it.curve.length === 48, `curve=${it.curve.length}`)
  // 曲线尾点 200（锯齿末点是高位）作现价 → SELL
  assert(it.current === 200 && it.signal === 'SELL', `current=${it.current} signal=${it.signal}`)
})

check(`buildRadarItem：双源中位偏差 > ${ANOMALY_DEV} → 压制观望，rawSignal 保留`, () => {
  const up = lowTail.map(([k, v]) => [k, v * 1.3]) // 全点抬 30% → 中位偏差恒为 3/13 ≈ 0.23
  const it = buildRadarItem(hiItem(up), { moliCurve: lowTail, minuteTail: 100 })
  assert(it.anomaly === true, '应判异常')
  assert(it.signal === 'WAIT', `压制后 signal=${it.signal}`)
  assert(it.rawSignal === 'BUY', `rawSignal=${it.rawSignal}`)
  assert(it.crossDev > ANOMALY_DEV, `crossDev=${it.crossDev}`)
})

check('buildRadarItem：数据不足（<24 点）→ WAIT 且 rank 为 null', () => {
  const short = lowTail.slice(0, 12)
  const it = buildRadarItem(hiItem(short), { moliCurve: short, minuteTail: 100 })
  assert(it.signal === 'WAIT' && it.rank === null, `signal=${it.signal} rank=${it.rank}`)
})

check('deriveVersion：取全部曲线最新点键的最大值', () => {
  const a = { curve: [['202610130800', 1], ['202610130900', 2]] }
  const b = { curve: [['202610140800', 1]] }
  const c = { curve: [] }
  assert(deriveVersion([a, b, c]) === '202610140800', deriveVersion([a, b, c]))
  assert(deriveVersion([]) === '', '空输入应得空串')
})

/* ---------- 跑测 ---------- */
let failed = 0
for (const [name, fn] of checks) {
  try {
    await fn()
    console.log(`✓ ${name}`)
  } catch (e) {
    failed++
    console.error(`✗ ${name}\n  ${e.message}`)
  }
}
if (failed) {
  console.error(`\n${failed}/${checks.length} 项失败`)
  process.exit(1)
}
console.log(`\n全部 ${checks.length} 项通过（离线模式，未打外网）`)
