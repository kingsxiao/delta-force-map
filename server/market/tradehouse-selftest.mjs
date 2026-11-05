/* ============================================================
   tradehouse-selftest.mjs — 交易行快照 / 指数 / 战备差价 纯逻辑离线自测
   ------------------------------------------------------------
   覆盖（tradehouse.mjs 的可测面，网络全走注入桩）：
     ① decodeWireTradehouse：加密往返 / 错误密钥 / 缺 key 头 / 版本字节 /
        空体 / 明文 JSON 直通
     ② buildTradehouseItem / buildTradehouseSnapshot：字段映射 + 版本取
        last_update 最大值 + 缺失回退北京墙钟
     ③ marketLevel / buildIndexMarkets：篮子过滤（双全才计入）、空篮 null、
        五大市场展示序、子市场按篮子数排序、总览
     ④ appendHistoryPoint：逐版本一档 / 同版本覆盖 / HISTORY_CAP 截断
     ⑤ buildLoadoutItem / buildLoadoutSnapshot：diff 缺失时现算 / stats
     ⑥ buildPredictionItems
     ⑦ runTradehouseCycle（注入桩 + 临时目录）：三份快照落盘、预测失败降级
        null、战备差价失败保留旧档、指数历史落盘与同版本不重复追加
   全部通过 exit 0；失败写 stderr 后 exit 1。
   用法：node server/market/tradehouse-selftest.mjs
   ============================================================ */
import { createCipheriv, createHash } from 'node:crypto'
import { gzipSync } from 'node:zlib'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import {
  decodeWireTradehouse,
  buildTradehouseItem,
  buildTradehouseSnapshot,
  deriveVersion,
  marketLevel,
  buildIndexMarkets,
  appendHistoryPoint,
  buildLoadoutItem,
  buildLoadoutSnapshot,
  buildPredictionItems,
  runTradehouseCycle,
  HISTORY_CAP,
  MARKET_ORDER,
} from './tradehouse.mjs'

function assert(cond, msg) {
  if (!cond) throw new Error(msg)
}
const checks = []
const check = (name, fn) => checks.push([name, fn])

/** 按上游传输编码打包（selftest 专用；密钥 = SHA-256(keyHeader)） */
function encodeWire(obj, keyHeader, { versionByte = 0x01, aad = 'trade-house-snapshot-v1' } = {}) {
  const iv = Buffer.alloc(12, 9)
  const key = createHash('sha256').update(keyHeader, 'utf8').digest()
  const cipher = createCipheriv('aes-256-gcm', key, iv)
  cipher.setAAD(Buffer.from(aad, 'utf8'))
  const plain = gzipSync(Buffer.from(JSON.stringify(obj), 'utf8'))
  const body = Buffer.concat([cipher.update(plain), cipher.final(), cipher.getAuthTag()])
  return Buffer.concat([Buffer.from([versionByte]), iv, body])
}

/* ---------- ① 解码 ---------- */

const SAMPLE = { status: 'ok', total: 2, items: [] }

check('decodeWireTradehouse：加密往返（gzip + AES-256-GCM + 尾部 tag）', () => {
  const wire = encodeWire(SAMPLE, 'th-key-1')
  const out = decodeWireTradehouse({ body: wire, keyHeader: 'th-key-1' })
  assert(out.status === 'ok' && out.total === 2, JSON.stringify(out).slice(0, 80))
})

check('decodeWireTradehouse：错误密钥 / 缺 key 头 / 版本字节 / 空体 → throw', () => {
  for (const [body, key, why] of [
    [encodeWire(SAMPLE, 'real'), 'wrong', '错误密钥'],
    [encodeWire(SAMPLE, 'real'), '', '缺 key 头'],
    [encodeWire(SAMPLE, 'real', { versionByte: 0x02 }), 'real', '版本字节'],
    [Buffer.alloc(0), 'real', '空体'],
  ]) {
    let threw = false
    try {
      decodeWireTradehouse({ body, keyHeader: key })
    } catch {
      threw = true
    }
    assert(threw, `${why}应 throw`)
  }
})

check('decodeWireTradehouse：明文 JSON 直通', () => {
  const out = decodeWireTradehouse({ body: Buffer.from(JSON.stringify(SAMPLE)), keyHeader: '' })
  assert(out.status === 'ok', '明文应直接解析')
})

/* ---------- ② 整形与版本 ---------- */

const RAW_ITEM = (over = {}) => ({
  object_id: '11010006002-1',
  name: 'H70',
  display_name: 'H70 精英头盔（全新）',
  alias_name: null,
  category: 'protect',
  category_cn: '头盔',
  subcategory: 'helmet',
  item_subtype: null,
  grade: '6',
  icon_url: 'https://example.com/a.png',
  current_price: 2274281,
  base_price: 843493,
  yesterday_avg_price: 3150675,
  yesterday_high: 4003281,
  yesterday_low: 252681,
  seven_day_high: 4003281,
  seven_day_low: 252681,
  last_update: '2026-11-05 13:19',
  ...over,
})

check('buildTradehouseItem：字段映射', () => {
  const it = buildTradehouseItem(RAW_ITEM())
  assert(it.objectId === '11010006002-1' && it.name === 'H70 精英头盔（全新）', 'id/name')
  assert(it.category === 'protect' && it.categoryCn === '头盔' && it.subcategory === 'helmet', '品类')
  assert(it.current === 2274281 && it.yesterdayAvg === 3150675 && it.sevenDayLow === 252681, '价格')
  assert(it.grade === 6 && it.lastUpdate === '2026-11-05 13:19', '品级/更新')
})

check('buildTradehouseSnapshot：版本取 last_update 最大值 + stats', () => {
  const raw = { status: 'ok', generated_at: 1794000000000, items: [
    RAW_ITEM(),
    RAW_ITEM({ last_update: '2026-11-05 14:02' }),
    RAW_ITEM({ last_update: null }),
  ] }
  const snap = buildTradehouseSnapshot(raw, { fetchedAt: '2026-11-05T06:00:00.000Z' })
  assert(snap.version === '202611051402', `version=${snap.version}`)
  assert(snap.stats.total === 3 && snap.stats.priced === 3, 'stats')
  assert(snap.source === 'moligod-tradehouse', 'source')
})

check('deriveVersion：全缺失回退北京墙钟', () => {
  assert(deriveVersion([null, ''], '2026-11-05T04:05:06.000Z') === '202611051205', 'UTC+8 12:05')
})

/* ---------- ③ 指数 ---------- */

const P = (cur, yavg) => ({ current: cur, yesterdayAvg: yavg })

check('marketLevel：篮子只计双全条目，空篮 null', () => {
  const m = marketLevel([P(100, 200), P(50, 50), P(null, 100), P(10, null), P(0, 100)])
  // 双全：100/200 + 50/50 → level = 1000×150/250 = 600
  assert(m.universe === 2, `universe=${m.universe}`)
  assert(Math.abs(m.level - 600) < 1e-9, `level=${m.level}`)
  assert(Math.abs(m.change24h - (-0.4)) < 1e-9, 'change24h')
  assert(marketLevel([P(null, 1)]) === null, '空篮应 null')
})

check('buildIndexMarkets：五大市场展示序 + 子市场按篮子数排序 + 总览', () => {
  // buildIndexMarkets 吃契约形状（camelCase），上游原始行先过 buildTradehouseItem
  const items = [
    buildTradehouseItem(RAW_ITEM()), // protect/helmet
    buildTradehouseItem(RAW_ITEM({ category: 'ammo', category_cn: '子弹', subcategory: 'ammo5.56x45', current_price: 1000, yesterday_avg_price: 1000 })),
    buildTradehouseItem(RAW_ITEM({ category: 'ammo', category_cn: '子弹', subcategory: 'ammo9x19', current_price: 2000, yesterday_avg_price: 1000 })),
    buildTradehouseItem(RAW_ITEM({ category: 'ammo', category_cn: '子弹', subcategory: 'ammo9x19', current_price: 3000, yesterday_avg_price: 1000 })),
    buildTradehouseItem(RAW_ITEM({ category: 'props', category_cn: '钥匙', subcategory: 'key', current_price: 1, yesterday_avg_price: 2 })),
  ]
  const { all, markets } = buildIndexMarkets(items)
  assert(markets.map((m) => m.id).join() === 'ammo,props,protect', `只含有篮子市场且按 MARKET_ORDER 序：${markets.map((m) => m.id)}`)
  assert(MARKET_ORDER.join() === 'ammo,acc,gun,props,protect', '展示序常量')
  const ammo = markets.find((m) => m.id === 'ammo')
  assert(ammo.subs[0].id === 'ammo9x19' && ammo.subs[0].universe === 2, '子市场按篮子数排序')
  assert(ammo.level != null && Math.abs(ammo.level - 2000) < 1e-9, `ammo level=${ammo.level}（6000/3000×1000）`)
  assert(all != null && all.universe === 5, '总览篮子（五条双全）')
})

/* ---------- ④ 历史 ---------- */

check('appendHistoryPoint：逐版本一档 / 同版本覆盖 / CAP 截断', () => {
  let h = { points: [] }
  h = appendHistoryPoint(h, '202611050001', { all: 1000, ammo: 1000 })
  h = appendHistoryPoint(h, '202611050002', { all: 1001, ammo: 1002 })
  h = appendHistoryPoint(h, '202611050001', { all: 999, ammo: 999 }) // 同版本覆盖
  assert(h.points.length === 2 && h.points[0].all === 999, JSON.stringify(h.points))
  assert(h.points[0].t === '202611050001' && h.points[1].t === '202611050002', '按版本排序')
  for (let i = 0; i < HISTORY_CAP + 5; i++) {
    h = appendHistoryPoint(h, String(202611060000 + i).padStart(12, '0'), { all: i })
  }
  assert(h.points.length === HISTORY_CAP, `cap=${h.points.length}`)
  assert(h.points[0].t === String(202611060000 + 5).padStart(12, '0'), '最旧的被截掉')
})

/* ---------- ⑤⑥ 战备差价与预测 ---------- */

check('buildLoadoutItem / buildLoadoutSnapshot：diff 缺失现算 + stats', () => {
  // buildLoadoutSnapshot 吃上游原始行（内部自行 buildLoadoutItem），
  // 字段级断言与快照级断言分开喂，避免二次整形
  const RAW_LO = {
    object_id: '15080050142', display_name: '海洋之泪', category: 'props', category_cn: '收集品',
    item_subtype: '工艺藏品', grade: '6', icon_url: 'https://example.com/b.png',
    current_price: 30467068, system_price: 32234568, preparedness_diff: 1767500,
    last_update: '2026-11-05 07:36',
  }
  const it = buildLoadoutItem(RAW_LO)
  assert(it.diff === 1767500 && it.system === 32234568 && it.subcategory === '工艺藏品', '字段')
  const it2 = buildLoadoutItem({ object_id: 'x', display_name: '无差价字段', current_price: 100, system_price: 150, preparedness_diff: null })
  assert(it2.diff === 50, 'diff 缺失应现算 system−current')
  const snap = buildLoadoutSnapshot({ items: [RAW_LO, { object_id: 'x', display_name: '无差价字段', current_price: 100, system_price: 150, preparedness_diff: null }] }, { fetchedAt: '2026-11-05T00:00:00.000Z' })
  assert(snap.stats.total === 2 && snap.stats.diffSum === 1767500 + 50, `diffSum=${snap.stats.diffSum}`)
  assert(snap.version === '202611050736', '版本取最大 last_update')
})

check('buildPredictionItems：max_sell_profit 透传', () => {
  const items = buildPredictionItems({ items: [{ object_id: '1', display_name: '古老的海盗望远镜', current_price: 40185, max_sell_profit: 80173.5, grade: '3' }] })
  assert(items.length === 1 && items[0].maxSellProfit === 80173.5 && items[0].current === 40185, JSON.stringify(items))
})

/* ---------- ⑦ 循环 ---------- */

async function tempDirs() {
  const root = await mkdtemp(path.join(tmpdir(), 'df-th-'))
  await (await import('node:fs/promises')).mkdir(path.join(root, 'dist', 'market'), { recursive: true })
  return root
}

function stubs({ thOk = true, predOk = true, loOk = true } = {}) {
  const wire = () => {
    if (!thOk) throw new Error('TH down')
    return {
      status: 'ok', generated_at: 1794000000000,
      items: [RAW_ITEM(), RAW_ITEM({ category: 'ammo', category_cn: '子弹', subcategory: 'ammo9x19', current_price: 2000, yesterday_avg_price: 1000, last_update: '2026-11-05 14:02' })],
    }
  }
  return {
    fetchWire: wire,
    fetchJson: (url) => {
      if (url.includes('one-flow-market-prediction')) {
        if (!predOk) throw new Error('pred down')
        return Promise.resolve({ items: [{ object_id: '1', display_name: '预测物品', current_price: 100, max_sell_profit: 200, grade: '3' }] })
      }
      if (url.includes('preparedness-valuation')) {
        if (!loOk) throw new Error('lo down')
        return Promise.resolve({ items: [{ object_id: '2', display_name: '战备物品', current_price: 100, system_price: 150, preparedness_diff: 50, last_update: '2026-11-05 07:36' }] })
      }
      return Promise.reject(new Error('未知 URL ' + url))
    },
  }
}

check('runTradehouseCycle：三份快照落盘 + 指数历史', async () => {
  const dir = await tempDirs()
  try {
    const r = await runTradehouseCycle({ webDir: dir, rootDir: dir, ...stubs(), now: '2026-11-05T06:30:00.000Z' })
    assert(r.version === '202611051402' && r.total === 2, JSON.stringify(r))
    assert(r.indexAll != null && r.loadoutTotal === 1, '指数与差价')
    const th = JSON.parse(await readFile(path.join(dir, 'public', 'market', 'tradehouse.json'), 'utf8'))
    assert(th.items.length === 2 && th.stats.priced === 2, 'tradehouse.json')
    const idx = JSON.parse(await readFile(path.join(dir, 'public', 'market', 'index.json'), 'utf8'))
    assert(idx.markets.length === 2 && idx.history.length === 1 && idx.prediction.length === 1, 'index.json')
    assert(idx.historySince === '202611051402', 'historySince')
    const lo = JSON.parse(await readFile(path.join(dir, 'public', 'market', 'loadout.json'), 'utf8'))
    assert(lo.items[0].diff === 50, 'loadout.json')
    // 同版本二轮：历史不重复追加
    await runTradehouseCycle({ webDir: dir, rootDir: dir, ...stubs(), now: '2026-11-05T06:40:00.000Z' })
    const idx2 = JSON.parse(await readFile(path.join(dir, 'public', 'market', 'index.json'), 'utf8'))
    assert(idx2.history.length === 1, `同版本历史应去重，got ${idx2.history.length}`)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

check('runTradehouseCycle：预测 / 战备差价失败降级，主产物不受阻', async () => {
  const dir = await tempDirs()
  try {
    const r = await runTradehouseCycle({ webDir: dir, rootDir: dir, ...stubs({ predOk: false, loOk: false }), now: '2026-11-05T06:30:00.000Z' })
    assert(r.version === '202611051402' && r.loadoutTotal === null, JSON.stringify(r))
    const idx = JSON.parse(await readFile(path.join(dir, 'public', 'market', 'index.json'), 'utf8'))
    assert(idx.prediction === null, '预测应降级 null')
    let loMissing = false
    try {
      await readFile(path.join(dir, 'public', 'market', 'loadout.json'), 'utf8')
    } catch {
      loMissing = true
    }
    assert(loMissing, '战备差价失败不应写盘（保留旧档语义）')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

check('runTradehouseCycle：交易行主源失败 → 整轮抛出（不写半套快照）', async () => {
  let threw = false
  try {
    await runTradehouseCycle({ webDir: await tempDirs(), ...stubs({ thOk: false }) })
  } catch {
    threw = true
  }
  assert(threw, '主源失败应上抛')
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
console.log(`\n全部 ${checks.length} 项通过（离线模式，网络走注入桩）`)
