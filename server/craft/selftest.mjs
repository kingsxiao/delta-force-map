/* ============================================================
   selftest.mjs — 特勤处制造快照纯逻辑离线自测（node 直接运行，零外网）
   ------------------------------------------------------------
   覆盖（snapshot.mjs 的可测面，不含网络路径）：
     ① decodeWireSnapshot：加密往返（自建 AES-256-GCM + gzip 线格式）、
        版本字节不符、密钥不匹配（认证失败）、缺 key 头、空体、明文 JSON 直通
     ② buildCraftItem：字段映射、时利 / 回报率派生、缺价材料 price=null
     ③ buildCraftSnapshot：不可见配方过滤、stats 三计数、places 展示序
     ④ deriveCraftVersion：产出 last_update 最大值 → 12 位版本；全缺失回退
        抓取时刻（北京墙钟）
   全部通过 exit 0；失败写 stderr 后 exit 1。
   用法：node server/craft/selftest.mjs
   ============================================================ */
import { createCipheriv, createHash } from 'node:crypto'
import { gzipSync } from 'node:zlib'
import {
  decodeWireSnapshot,
  buildCraftItem,
  buildCraftSnapshot,
  deriveCraftVersion,
  PLACE_ORDER,
} from './snapshot.mjs'

function assert(cond, msg) {
  if (!cond) throw new Error(msg)
}
const checks = []
const check = (name, fn) => checks.push([name, fn])

/* ---------- 线格式助手：与 decodeWireSnapshot 互逆的本地加密 ---------- */

/** 按上游传输编码打包一份快照（selftest 专用；密钥 = SHA-256(keyHeader)） */
function encodeWireSnapshot(obj, keyHeader, { versionByte = 0x01, aad = 'special-ops-snapshot-v1' } = {}) {
  const iv = Buffer.alloc(12, 7)
  const key = createHash('sha256').update(keyHeader, 'utf8').digest()
  const cipher = createCipheriv('aes-256-gcm', key, iv)
  cipher.setAAD(Buffer.from(aad, 'utf8'))
  const plain = gzipSync(Buffer.from(JSON.stringify(obj), 'utf8'))
  const body = Buffer.concat([cipher.update(plain), cipher.final(), cipher.getAuthTag()])
  return Buffer.concat([Buffer.from([versionByte]), iv, body])
}

const SAMPLE = { status: 'ok', recipes: [], generated_at: 1792727539993 }

check('decodeWireSnapshot：加密往返（gzip + AES-256-GCM + 尾部 tag）', () => {
  const wire = encodeWireSnapshot(SAMPLE, 'go-rewrite-special-ops-key')
  const out = decodeWireSnapshot({ body: wire, keyHeader: 'go-rewrite-special-ops-key' })
  assert(out.status === 'ok' && Array.isArray(out.recipes), JSON.stringify(out).slice(0, 80))
})

check('decodeWireSnapshot：密钥不匹配 → 认证失败 throw', () => {
  const wire = encodeWireSnapshot(SAMPLE, 'real-key')
  let threw = false
  try {
    decodeWireSnapshot({ body: wire, keyHeader: 'wrong-key' })
  } catch {
    threw = true
  }
  assert(threw, '错误密钥不应解出')
})

check('decodeWireSnapshot：版本字节不符 / 缺 key 头 / 空体 → throw', () => {
  const badVer = encodeWireSnapshot(SAMPLE, 'k', { versionByte: 0x02 })
  for (const [body, key, why] of [
    [badVer, 'k', '版本字节'],
    [encodeWireSnapshot(SAMPLE, 'k'), '', '缺 key 头'],
    [Buffer.alloc(0), 'k', '空体'],
  ]) {
    let threw = false
    try {
      decodeWireSnapshot({ body, keyHeader: key })
    } catch {
      threw = true
    }
    assert(threw, `${why}不符应 throw`)
  }
})

check('decodeWireSnapshot：明文 JSON 直通（上游撤编码时零改动兼容）', () => {
  const out = decodeWireSnapshot({ body: Buffer.from(JSON.stringify(SAMPLE)), keyHeader: '' })
  assert(out.status === 'ok', '明文应直接解析')
})

/* ---------- 整形 ---------- */

/** 上游形状的最小配方（字段名 snake_case，含缺价材料） */
const RAW_RECIPE = (over = {}) => ({
  id: 883,
  place: 'armory',
  required_level: 1,
  output_category: 'protect',
  output_display_name: 'MAP侦察背包',
  output_grade: '4',
  output_icon_url: 'https://example.com/a.png',
  output_current_price: 28638,
  output_last_update: '2026-10-23 11:51',
  per_count: 1,
  materials: [
    {
      display_name: '高分子布料',
      grade: '3',
      icon_url: 'https://example.com/m.png',
      required_count: 2,
      has_price: true,
      current_price: 8184,
      material_cost: 16368,
    },
    {
      display_name: '未上架材料',
      grade: null,
      icon_url: null,
      required_count: 1,
      has_price: false,
      current_price: null,
      material_cost: null,
    },
  ],
  estimated_material_cost: 16368,
  estimated_fee: 3723,
  fee_rate: 0.13,
  estimated_revenue: 28638,
  estimated_profit: 8547,
  period_hours: 12,
  period: '12h',
  today_max_profit: 16718,
  seven_day_max_profit: 20083,
  missing_price_count: 1,
  is_special_ops_visible: true,
  ...over,
})

check('buildCraftItem：字段映射 + 时利 / 回报率派生 + 缺价材料 price=null', () => {
  const it = buildCraftItem(RAW_RECIPE())
  assert(it.place === 'armory' && it.requiredLevel === 1, 'place/level')
  assert(it.output.name === 'MAP侦察背包' && it.output.grade === 4, 'output 映射')
  assert(it.output.count === 1 && it.output.price === 28638, 'output 数量/现价')
  assert(it.materials.length === 2, 'materials')
  assert(it.materials[0].count === 2 && it.materials[0].price === 8184 && it.materials[0].cost === 16368, '有价材料')
  assert(it.materials[1].price === null, '缺价材料 price 应为 null')
  assert(it.cost === 16368 && it.fee === 3723 && it.feeRate === 0.13, '成本/费')
  assert(it.profit === 8547 && Math.abs(it.profitPerHour - 8547 / 12) < 1e-9, '利润/时利')
  assert(Math.abs(it.roi - 8547 / 16368) < 1e-9, '回报率 = 利润/成本')
  assert(it.periodHours === 12 && it.periodLabel === '12h', '耗时')
  assert(it.missingPriceCount === 1, '缺价计数')
})

check('buildCraftItem：period_hours=0 → 时利 null（不除零）', () => {
  const it = buildCraftItem(RAW_RECIPE({ period_hours: 0 }))
  assert(it.profitPerHour === null, 'period 0 时利应为 null')
})

check('buildCraftSnapshot：过滤不可见配方 + stats 三计数 + places 展示序', () => {
  const raw = {
    status: 'ok',
    generated_at: 1792727539993,
    filters: { places: ['armory', 'pharmacy', 'tech', 'workbench'], levels: [1, 2, 3] },
    recipes: [
      RAW_RECIPE(), // armory · 完整价 · 缺价 1 → 不计入 complete
      RAW_RECIPE({ id: 2, place: 'workbench', missing_price_count: 0, estimated_profit: 100 }), // 可盈利
      RAW_RECIPE({ id: 3, place: 'tech', missing_price_count: 0, estimated_profit: -50 }), // 完整但亏损
      RAW_RECIPE({ id: 4, is_special_ops_visible: false }), // 不可见 → 过滤
    ],
  }
  const snap = buildCraftSnapshot(raw, { fetchedAt: '2026-10-23T04:00:00.000Z' })
  assert(snap.items.length === 3, `不可见应被过滤，got ${snap.items.length}`)
  assert(snap.source === 'moligod-craft', 'source')
  assert(snap.stats.total === 3 && snap.stats.complete === 2 && snap.stats.profitable === 1, JSON.stringify(snap.stats))
  assert(snap.places.map((p) => p.id).join() === PLACE_ORDER.join(), 'places 按展示序')
  assert(snap.places[0].label === '工作台' && snap.places[3].label === '制药台', 'place 文案')
  assert(snap.version === '202610231151', `version=${snap.version}（应取 output_last_update 最大值）`)
})

check('buildCraftSnapshot：空 recipes 不炸，stats 全零', () => {
  const snap = buildCraftSnapshot({ recipes: [] }, { fetchedAt: '2026-10-23T04:00:00.000Z' })
  assert(snap.items.length === 0, 'items 空')
  assert(snap.stats.total === 0 && snap.stats.complete === 0 && snap.stats.profitable === 0, 'stats 零')
})

check('deriveCraftVersion：全缺失 → 回退抓取时刻（北京墙钟 12 位）', () => {
  const v = deriveCraftVersion([], '2026-10-23T04:05:06.000Z')
  assert(v === '202610231205', `v=${v}（UTC+8 应为 12:05）`)
})

check('deriveCraftVersion：多配方产出更新时间 → 取最大者', () => {
  const items = [
    { output: { lastUpdate: '2026-10-23 10:00' }, materials: [] },
    { output: { lastUpdate: '2026-10-23 11:58' }, materials: [] },
    { output: { lastUpdate: null }, materials: [] },
  ]
  assert(deriveCraftVersion(items, '2026-10-23T04:00:00.000Z') === '202610231158', '取全量最大')
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
