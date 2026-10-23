/* ============================================================
   snapshot.mjs — 特勤处制造利润快照（工作台 / 防具台 / 技术中心 / 制药台）
   ------------------------------------------------------------
   数据源：moligod.com 特勤处制造页的同名接口（2026-10-23 实测定稿）：
     · GET /api/market/special-ops-snapshot —— 配方全量（当前 230 条）+
       逐材料 / 产出现价（分钟级）+ 预估成本 / 手续费 / 净利润 / 今日与
       7 日最高利润，免登录
     · 响应体为公开传输编码（非鉴权，密钥随每个响应下发）：裸二进制
       [0]=0x01 版本 + [1,13) 12B IV + 其后 AES-256-GCM 密文（尾附 16B
       auth tag），密钥 = SHA-256(响应头 x-special-ops-key)，AAD 固定
       'special-ops-snapshot-v1'，明文再套一层 gzip（前端 publicWireCrypto
       chunk 公开算法的 Node 同构）
     · 上游已按「材料现价买入 → 产出按现价挂卖 → 扣手续费」口径算好
       预估：revenue = 产出价 × 数量；profit = revenue − fee − cost
       （实测逐条对账成立）。本模块只做传输解码 + 字段整形 + 时利派生，
       不另立利润口径
   产物 apps/web/public/craft/craft.json（+ dist 联动），契约见
   shared/API.md §1.3；SSE 事件 craft（server.mjs 集成，同雷达范式）。
   用法：node server/craft/snapshot.mjs [--once] [--interval 分钟=10]
   ============================================================ */
import { createDecipheriv, createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { gunzipSync as gunzip } from 'node:zlib'
import { writeJsonAtomic } from '../ammo/fetch-once.mjs'

const BASE = 'https://moligod.com'
const SNAPSHOT_URL = `${BASE}/api/market/special-ops-snapshot`
const UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
/** 传输编码常量（与前端 publicWireCrypto 同构） */
const WIRE_VERSION = 0x01
const WIRE_IV_LEN = 12
const WIRE_TAG_LEN = 16
const WIRE_AAD = 'special-ops-snapshot-v1'

/** 制造台展示序与文案（raw.filters.places 为字母序，展示序在这里定调） */
export const PLACE_ORDER = ['workbench', 'armory', 'tech', 'pharmacy']
export const PLACE_LABELS = {
  workbench: '工作台',
  armory: '防具台',
  tech: '技术中心',
  pharmacy: '制药台',
}

/* ---------- 传输解码（纯函数，selftest 覆盖） ---------- */

/**
 * 解码特勤处快照的公开传输编码。
 * @param {{body:Uint8Array|Buffer, keyHeader:string}} raw 响应体与 x-special-ops-key 头
 * @returns {Promise<object>} 解出的 JSON 快照
 * @throws 格式版本不符 / 密钥缺失 / 认证失败（密钥不对或密文被改）
 */
export function decodeWireSnapshot({ body, keyHeader }) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(body)
  if (!buf.length) throw new Error('特勤处快照响应体为空')
  // 明文 JSON 直通（上游若撤掉传输编码，这里零改动兼容）
  if (buf[0] === 0x7b /* '{' */) return JSON.parse(buf.toString('utf8'))
  if (buf[0] !== WIRE_VERSION) throw new Error(`特勤处快照版本字节不符：0x${buf[0].toString(16)}`)
  if (!keyHeader) throw new Error('响应缺少 x-special-ops-key 头')
  if (buf.length <= 1 + WIRE_IV_LEN + WIRE_TAG_LEN) throw new Error('特勤处快照密文长度异常')

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
    throw new Error(`特勤处快照解密失败（密钥不匹配或密文损坏）：${e.message}`)
  }
  if (plain[0] === 0x1f && plain[1] === 0x8b) plain = gunzip(plain)
  return JSON.parse(plain.toString('utf8'))
}

/** 拉一份上游原始快照（解码后） */
export async function fetchCraftRaw() {
  const res = await fetch(SNAPSHOT_URL, {
    headers: { 'User-Agent': UA, Accept: 'application/json', Referer: `${BASE}/crafting` },
  })
  if (!res.ok) throw new Error(`HTTP ${res.status} special-ops-snapshot`)
  const keyHeader = res.headers.get('x-special-ops-key') || ''
  const body = Buffer.from(await res.arrayBuffer())
  return decodeWireSnapshot({ body, keyHeader })
}

/* ---------- 整形（纯函数，selftest 覆盖） ---------- */

const num = (v) => {
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

/** 配方条目整形：上游 snake_case → 契约 camelCase，派生时利与回报率 */
export function buildCraftItem(r) {
  const periodHours = num(r.period_hours)
  const profit = num(r.estimated_profit)
  const cost = num(r.estimated_material_cost)
  return {
    id: r.id,
    place: r.place,
    requiredLevel: num(r.required_level),
    category: r.output_category || null,
    output: {
      name: r.output_display_name || r.output_name,
      grade: num(r.output_grade),
      pic: r.output_icon_url || null,
      count: num(r.per_count) ?? 1,
      price: num(r.output_current_price),
      lastUpdate: r.output_last_update || null,
    },
    materials: (r.materials || []).map((m) => ({
      name: m.display_name || m.name,
      grade: num(m.grade),
      pic: m.icon_url || null,
      count: num(m.required_count) ?? 1,
      price: m.has_price ? num(m.current_price) : null,
      cost: num(m.material_cost),
    })),
    cost,
    fee: num(r.estimated_fee),
    feeRate: num(r.fee_rate),
    revenue: num(r.estimated_revenue),
    profit,
    profitPerHour:
      profit != null && periodHours != null && periodHours > 0 ? profit / periodHours : null,
    roi: profit != null && cost != null && cost > 0 ? profit / cost : null,
    periodHours,
    periodLabel: r.period || null,
    todayMaxProfit: num(r.today_max_profit),
    sevenDayMaxProfit: num(r.seven_day_max_profit),
    missingPriceCount: num(r.missing_price_count) ?? 0,
  }
}

/**
 * 上游原始快照 → 契约快照（纯函数）。
 * 过滤 is_special_ops_visible === false 的条目；version 取全部产出
 * last_update（'YYYY-MM-DD HH:mm' 北京墙钟）的最大值 → 'YYYYMMDDHHmm'。
 */
export function buildCraftSnapshot(raw, { fetchedAt = new Date().toISOString() } = {}) {
  const places = PLACE_ORDER.map((id) => ({ id, label: PLACE_LABELS[id] }))
  const recipes = Array.isArray(raw?.recipes) ? raw.recipes : []
  const items = recipes.filter((r) => r && r.is_special_ops_visible !== false).map(buildCraftItem)

  const complete = items.filter((i) => i.missingPriceCount === 0)
  const out = {
    version: deriveCraftVersion(items, fetchedAt),
    fetchedAt,
    generatedAt: new Date(Number(raw?.generated_at) || Date.now()).toISOString(),
    source: 'moligod-craft',
    places,
    items,
    stats: {
      total: items.length,
      complete: complete.length,
      profitable: complete.filter((i) => (i.profit ?? 0) > 0).length,
    },
  }
  return out
}

/** 'YYYY-MM-DD HH:mm' → 'YYYYMMDDHHmm'；取全量产出更新时间最大值；全部缺失退回抓取时刻（北京墙钟） */
export function deriveCraftVersion(items, fallbackIso = new Date().toISOString()) {
  let best = ''
  for (const it of items || []) {
    const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$/.exec(String(it?.output?.lastUpdate || ''))
    if (m) {
      const v = `${m[1]}${m[2]}${m[3]}${m[4]}${m[5]}`
      if (v > best) best = v
    }
  }
  if (/^\d{12}$/.test(best)) return best
  const d = new Date(fallbackIso)
  const p = (n) => String(n).padStart(2, '0')
  const bj = new Date(d.getTime() + 8 * 3600 * 1000)
  return `${bj.getUTCFullYear()}${p(bj.getUTCMonth() + 1)}${p(bj.getUTCDate())}${p(bj.getUTCHours())}${p(bj.getUTCMinutes())}`
}

/* ---------- 落盘与循环 ---------- */

/**
 * 抓一轮并落盘（public + dist 联动）。利润估算随分钟价滚动，默认 10 分钟
 * 一轮与雷达同节奏即可；写频低，原子直写。
 * @returns {Promise<{version:string, items:Array, stats:object}>}
 */
export async function runCraftCycle({ webDir } = {}) {
  const raw = await fetchCraftRaw()
  const out = buildCraftSnapshot(raw)
  const text = JSON.stringify(out)
  await writeJsonAtomic(path.join(webDir || process.cwd(), 'public', 'craft', 'craft.json'), text)
  const distPath = path.join(webDir || process.cwd(), 'dist', 'craft', 'craft.json')
  if (existsSync(path.dirname(distPath))) await writeJsonAtomic(distPath, text)
  return out
}

/* ---------- CLI：单跑 / 常驻监控（selftest import 时不执行） ---------- */

const IS_CLI =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)

if (IS_CLI) {
  const argv = process.argv.slice(2)
  const INTERVAL_MIN = argv.includes('--interval') ? Number(argv[argv.indexOf('--interval') + 1]) || 10 : 10
  const ONCE = argv.includes('--once')
  const WEB_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../apps/web')

  async function cycle() {
    try {
      const r = await runCraftCycle({ webDir: WEB_DIR })
      const s = r.stats
      console.log(
        `[${new Date().toLocaleString('zh-CN')}] version ${r.version} · 配方 ${s.total} · 价格完整 ${s.complete} · 可盈利 ${s.profitable}`,
      )
      const best = r.items
        .filter((i) => i.missingPriceCount === 0 && i.profitPerHour != null)
        .sort((a, b) => b.profitPerHour - a.profitPerHour)[0]
      if (best) {
        console.log(
          `   🏆 ${PLACE_LABELS[best.place]} ${best.output.name} 时利 ${Math.round(best.profitPerHour).toLocaleString('zh-CN')}/h · 单次利润 ${Math.round(best.profit).toLocaleString('zh-CN')}`,
        )
      }
    } catch (e) {
      console.error(`[${new Date().toLocaleString('zh-CN')}] 特勤处快照抓取失败: ${e.message}`)
    }
  }

  if (ONCE) {
    await cycle()
  } else {
    console.log(`特勤处制造快照监控启动：每 ${INTERVAL_MIN} 分钟一轮（Ctrl+C 退出）`)
    await cycle()
    const schedule = () => setTimeout(async () => { await cycle(); schedule() }, INTERVAL_MIN * 60 * 1000)
    schedule()
  }
}
