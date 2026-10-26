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
     ⑤ fetchRadarItems 注桩路径（kkrb 榜单 / moligod 曲线 / 官方目录全部
        注入，零外网）：目录命中登记 objectID 与官方均价 / 域内未命中与一名
        多物归集 misses 而域外 props/acc 不登记 / 目录不可用整轮跳过且结果
        与现状逐字段一致 / 1h 曲线空且官方名仅写法不同时重查一次并采用官方
        曲线（写法相同不重查）
   全部通过 exit 0；失败写 stderr 后 exit 1。
   用法：node scripts/market/selftest.mjs
   ============================================================ */
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { crossDeviation, buildRadarItem, deriveVersion, fetchRadarItems, ANOMALY_DEV, MIN_OVERLAP } from './radar.mjs'

function assert(cond, msg) {
  if (!cond) throw new Error(msg)
}
const checks = []
const check = (name, fn) => checks.push([name, fn])

/* ---------- fixture：96 个小时点（YYYYMMDDHHmm 键），2026-10-01 00 时起 ---------- */
const KEYS = Array.from({ length: 96 }, (_, i) => {
  const d = new Date(Date.UTC(2026, 9, 1) + i * 3600 * 1000)
  const p = (n) => String(n).padStart(2, '0')
  return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}00`
})

/** v2 BUY 形态（analyze.mjs 回测口径）：0..47 高位 150 → 48 崩盘 →
 *  其后宽幅震荡缓升（每 8 小时一周期、底抬 2），末点落在震荡下沿 104：
 *  rank≈0.125、离底≈16%、低点距今 41h、48h 斜率 +0.3%/h、72h P75≈150
 *  → 税后利差 ≈22%，五重门槛全过 → BUY */
const V2_BUY = KEYS.map((k, i) => {
  const pattern = [150, 125, 105, 90, 94, 110, 130, 145]
  const price = i < 48 ? 150 : pattern[(i - 48 + 5) % 8] + 2 * Math.floor((i - 48) / 8)
  return [k, price]
})
/** v2 SELL 形态：0..47 线性爬升 60→150（退出 48h 斜率窗）→ 其后高位横盘 ±0.5（动能走弱） */
const V2_SELL = KEYS.map((k, i) => [k, i < 48 ? 60 + (90 * i) / 47 : 150 + (i % 2 ? 0.5 : -0.5)])
const hiItem = (prices, { name = '测试物资', grade = 5, type = 'props' } = {}) => ({
  objectName: name,
  itemGrade: grade,
  objectType: type,
  pic: null,
  prices: Object.fromEntries(prices),
})

check('crossDeviation：同曲线 → 中位偏差 0', () => {
  const zigzag = V2_BUY
  const r = crossDeviation(zigzag, zigzag)
  assert(r.overlap === 96, `overlap=${r.overlap}`)
  assert(r.medianDev === 0, `medianDev=${r.medianDev}`)
})

check(`crossDeviation：重叠 < ${MIN_OVERLAP} → 无结论（null）`, () => {
  const short = V2_BUY.slice(0, 10)
  const r = crossDeviation(short, short)
  assert(r.overlap === 10, `overlap=${r.overlap}`)
  assert(r.medianDev === null, 'medianDev 应为 null')
})

check('crossDeviation：中位数按多数定调，不被少数尖峰拉爆', () => {
  // 96 点中 1/4 抬高 50%，其余一致：中位数仍为 0
  const b = V2_BUY.map(([k, v], i) => [k, i % 4 === 0 ? v * 1.5 : v])
  const r = crossDeviation(V2_BUY, b)
  assert(r.medianDev === 0, `medianDev=${r.medianDev}`)
})

check('crossDeviation：空输入不炸', () => {
  const r = crossDeviation([], [])
  assert(r.overlap === 0 && r.medianDev === null, JSON.stringify(r))
})

check('buildRadarItem：低位企稳+税后利差达标 → BUY，现价取分钟尾点', () => {
  const tail = V2_BUY[V2_BUY.length - 1][1]
  const it = buildRadarItem(hiItem(V2_BUY), { moliCurve: V2_BUY, minuteTail: tail })
  assert(it.signal === 'BUY', `signal=${it.signal}（rank=${it.rank} slope=${it.slope48} bounce=${it.bounceOffLow} lowAge=${it.lowAgeH} pct=${it.profitPct}）`)
  assert(it.current === tail, `current=${it.current} 应取分钟尾点 ${tail}`)
  assert(it.taxRate === 0.15, '非子弹无税后字段应兜底 15%')
  assert(it.curveSource === 'moligod', it.curveSource)
  assert(it.anomaly === false && it.crossDev === 0, '同曲线不应异常')
  assert(it.category === 'props', `category=${it.category}`)
})

check('buildRadarItem：高位 → SELL；分钟尾点覆盖曲线尾点', () => {
  const it = buildRadarItem(hiItem(V2_SELL), { moliCurve: V2_SELL, minuteTail: 200 })
  assert(it.signal === 'SELL', `signal=${it.signal}（rank=${it.rank} slope=${it.slope48}）`)
  assert(it.current === 200, `current=${it.current}`)
})

check('buildRadarItem：moligod 曲线过短（<24 点）→ 回退榜单曲线', () => {
  const it = buildRadarItem(hiItem(V2_SELL), { moliCurve: V2_SELL.slice(-5), minuteTail: null })
  assert(it.curveSource === 'kkrb-radar', it.curveSource) // 枚举对齐 schema：["moligod","kkrb-radar"]
  assert(it.curve.length === 96, `curve=${it.curve.length}`)
  // 曲线尾点（高位横盘）作现价 → SELL
  const tail = V2_SELL[V2_SELL.length - 1][1]
  assert(it.current === tail && it.signal === 'SELL', `current=${it.current} signal=${it.signal}`)
})

check(`buildRadarItem：双源中位偏差 > ${ANOMALY_DEV} → 压制观望，rawSignal 保留`, () => {
  const up = V2_BUY.map(([k, v]) => [k, v * 1.3]) // 全点抬 30% → 中位偏差 ≈ 0.23
  const it = buildRadarItem(hiItem(up), { moliCurve: V2_BUY, minuteTail: V2_BUY[V2_BUY.length - 1][1] })
  assert(it.anomaly === true, '应判异常')
  assert(it.signal === 'WAIT', `压制后 signal=${it.signal}`)
  assert(it.rawSignal === 'BUY', `rawSignal=${it.rawSignal}`)
  assert(it.crossDev > ANOMALY_DEV, `crossDev=${it.crossDev}`)
})

check('buildRadarItem：数据不足（<24 点）→ WAIT 且 rank 为 null', () => {
  const short = V2_BUY.slice(0, 12)
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

/* ---------- fetchRadarItems 注桩：kkrb 榜单 / moligod 曲线 / 官方目录全离线 ---------- */

/** 每个用例独立临时 rootDir（审计文件隔离，用后即删） */
const tempRoot = () => mkdtemp(path.join(tmpdir(), 'radar-selftest-'))
const auditPathIn = (root) => path.join(root, 'data', 'market', 'radar-name-audit.json')
const readAudit = async (root) => JSON.parse(await readFile(auditPathIn(root), 'utf8'))

/**
 * 离线依赖桩：kkrbRequest 回固定榜单；fetchHistory 按（名, interval）分派并
 * 记调用序（1h / 1m 分开计）；getDirectory / findByName 由用例注入。
 * histories 为 名→曲线 的表或 (name, interval) => 曲线 的函数；缺省 []。
 */
function stubDeps({ list, find, getDirectory, histories = {} }) {
  const calls = { oneHour: [], oneMin: [], find: [] }
  return {
    calls,
    deps: {
      kkrbRequest: async () => ({ data: { cn: list } }),
      getDirectory: getDirectory || (async () => ({ fetchedAt: '', primaries: [], items: [] })),
      findByName: async (name) => {
        calls.find.push(name)
        return find(name)
      },
      fetchHistory: async (name, { interval } = {}) => {
        ;(interval === '1m' ? calls.oneMin : calls.oneHour).push(name)
        const h = typeof histories === 'function' ? histories(name, interval) : histories[name]
        if (h instanceof Error) throw h
        return h ?? []
      },
    },
  }
}

check('fetchRadarItems：目录命中登记 objectID 与官方均价，曲线查询仍用榜单原名', async () => {
  const root = await tempRoot()
  try {
    const entryA = { objectName: '测试物资', objectID: '1001', avgPrice: 12345 }
    const entryB = { objectName: '高位物资', objectID: '1002', avgPrice: null }
    const { calls, deps } = stubDeps({
      list: [hiItem(V2_BUY), hiItem(V2_SELL, { name: '高位物资' })],
      find: (n) => (n === '测试物资' ? entryA : entryB),
      histories: { 测试物资: V2_BUY, 高位物资: V2_SELL },
    })
    const items = await fetchRadarItems({ rootDir: root, deps, paceMs: 0 })
    assert(items.length === 2 && items[0].hiRank === 1 && items[1].hiRank === 2, '榜单原序 + hiRank 回填')
    assert(calls.find.join() === '测试物资,高位物资', `逐项查目录：${JSON.stringify(calls.find)}`)
    const audit = await readAudit(root)
    assert(typeof audit.fetchedAt === 'string' && Array.isArray(audit.retried) && audit.retried.length === 0, JSON.stringify(audit))
    assert(audit.misses.length === 0 && audit.hits.length === 2, JSON.stringify(audit))
    assert(
      audit.hits[0].name === '测试物资' && audit.hits[0].objectID === '1001' && audit.hits[0].officialAvgPrice === 12345,
      JSON.stringify(audit.hits[0]),
    )
    assert(audit.hits[1].officialAvgPrice === null, '目录无均价应记 null')
    assert(
      calls.oneHour.join() === '测试物资,高位物资' && calls.oneMin.join() === '测试物资,高位物资',
      `非空曲线不触发任何重查：${JSON.stringify(calls)}`,
    )
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

check('fetchRadarItems：域内未命中 / 一名多物归集 misses；域外 props/acc 未命中不登记（去结构性噪音）', async () => {
  const root = await tempRoot()
  try {
    const { calls, deps } = stubDeps({
      list: [
        hiItem(V2_BUY, { name: '重型突击背心（破损）', type: 'protect' }), // 域内真实未命中（状态变体名）
        hiItem(V2_SELL, { name: '撞名护甲', type: 'protect' }), // 域内一名多物
        hiItem(V2_BUY, { name: '咖啡', type: 'props' }), // 域外：目录不收录，不算未命中
        hiItem(V2_SELL, { name: 'PERST-7蓝色激光镭指', type: 'acc' }), // 域外
      ],
      find: (n) => (n === '撞名护甲' ? { ambiguous: true, matches: [{ objectName: n }, { objectName: n }] } : null),
      histories: {}, // 全空：miss / ambiguous 都拿不到唯一官方名，不应重查
    })
    const items = await fetchRadarItems({ rootDir: root, deps, paceMs: 0 })
    assert(calls.find.join() === '重型突击背心（破损）,撞名护甲,咖啡,PERST-7蓝色激光镭指', `仍逐项查目录（零请求）：${JSON.stringify(calls.find)}`)
    const audit = await readAudit(root)
    assert(audit.hits.length === 0, JSON.stringify(audit.hits))
    assert(audit.misses.join() === '重型突击背心（破损）,撞名护甲', `misses 只含目录域内物品：${JSON.stringify(audit.misses)}`)
    assert(audit.retried.length === 0, '无官方名可用不应有 retried')
    assert(
      calls.oneHour.join() === '重型突击背心（破损）,撞名护甲,咖啡,PERST-7蓝色激光镭指',
      `空曲线但无官方名不应重查，查询序与现状一致：${JSON.stringify(calls.oneHour)}`,
    )
    assert(items.length === 4 && items.every((it) => it.curveSource === 'kkrb-radar'), '空曲线回退榜单曲线（现状行为）')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

check('fetchRadarItems：目录不可用 → 整轮跳过校验，结果与现状逐字段一致', async () => {
  const root = await tempRoot()
  try {
    const { calls, deps } = stubDeps({
      list: [hiItem(V2_BUY), hiItem(V2_SELL, { name: '高位物资' })],
      getDirectory: async () => {
        throw new Error('官方目录超时')
      },
      find: () => {
        throw new Error('目录不可用时 findByName 不应被调用')
      },
      histories: { 测试物资: V2_BUY }, // 高位物资 1h / 1m 均空
    })
    const items = await fetchRadarItems({ rootDir: root, deps, paceMs: 0 })
    assert(calls.find.length === 0, '目录不可用绝不再查目录')
    assert(!existsSync(auditPathIn(root)), '目录不可用不写审计文件')
    assert(
      calls.oneHour.join() === '测试物资,高位物资' && calls.oneMin.join() === '测试物资,高位物资',
      `每物仍 1h+1m 各一次原名（现状调用序）：${JSON.stringify(calls)}`,
    )
    // 与现状（榜单直连 buildRadarItem，无校验介入）逐字段一致
    const expect = [
      { ...buildRadarItem(hiItem(V2_BUY), { moliCurve: V2_BUY, minuteTail: V2_BUY[V2_BUY.length - 1][1] }), hiRank: 1 },
      { ...buildRadarItem(hiItem(V2_SELL, { name: '高位物资' }), { moliCurve: [], minuteTail: null }), hiRank: 2 },
    ]
    assert(JSON.stringify(items) === JSON.stringify(expect), '雷达条目应与现状完全一致')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

check('fetchRadarItems：1h 曲线空且官方名仅写法不同 → 官方名重查一次成功；写法相同不重查', async () => {
  const root = await tempRoot()
  try {
    const listName = '7.62x39mm AP SUB' // 社区写法（moligod 查不到）
    const officialName = '7.62*39mm AP SUB' // 官方星号变体（normalizeName 同名）
    const { calls, deps } = stubDeps({
      list: [hiItem(V2_BUY, { name: listName }), hiItem(V2_SELL, { name: '写法相同物资' })],
      find: (n) =>
        n === listName
          ? { objectName: officialName, objectID: '3001', avgPrice: 8888 }
          : { objectName: '写法相同物资', objectID: '3002', avgPrice: 1 },
      histories: (name) => (name === officialName ? V2_BUY : []), // 只有官方名能查到
    })
    const items = await fetchRadarItems({ rootDir: root, deps, paceMs: 0 })
    assert(
      calls.oneHour.join() === [listName, officialName, '写法相同物资'].join(),
      `重查恰一次且只针对写法不同者：${JSON.stringify(calls.oneHour)}`,
    )
    assert(items[0].curveSource === 'moligod' && items[0].curve.length === 96, '重查成功应采用官方名曲线')
    assert(items[1].curveSource === 'kkrb-radar', '官方名与榜单名写法相同 → 不重查，回退榜单曲线')
    assert(calls.oneMin.join() === [listName, '写法相同物资'].join(), `1m 现价查询仍用榜单原名：${JSON.stringify(calls.oneMin)}`)
    const audit = await readAudit(root)
    assert(
      audit.retried.length === 1 &&
        audit.retried[0].from === listName &&
        audit.retried[0].to === officialName &&
        audit.retried[0].points === 96,
      JSON.stringify(audit.retried),
    )
    assert(audit.hits.length === 2 && audit.hits[0].name === listName && audit.hits[0].objectID === '3001', '写法不同仍按榜单名登记命中')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
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
