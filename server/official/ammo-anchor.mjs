/* ============================================================
   ammo-anchor.mjs — 子弹官方均价锚 sidecar（只读交叉校验，纯库零依赖）
   ------------------------------------------------------------
   目的：拿腾讯官方 352246 的 avg_buyprice（「近期平均交易价格」口径，按
   objectID 给值、无小时曲线）给 moligod 主源的 67 弹现价做一个外部参照：
   逐弹算 dev=(moli−official)/official，|dev|>15% 逐弹 console.warn。官方
   口径与 moligod 分钟级现价不是同一个量，所以本模块只校验、不替代、不改
   口径——绝不写 apps/web/public/ammo/market.json、不碰契约、不碰页面文案。
   数据源：
     · moli 侧：apps/web/public/ammo/market.json 的 items[].name / current /
       grade（只读）
     · 官方目录：object-directory.getDirectory({primaries:['ammo']})（TTL 24h
       自维护，命中缓存零请求）
     · 官方均价：ams-client.fetchHourlyAvgPrice（≤5 id/批、串行、≥400ms 间隔；
       67 弹 ≤14 请求）
   名称映射（宁缺毋滥，绝不模糊匹配）：精确 objectName → normalizeName 归一
   化 → 显式别名表 AMMO_NAME_ALIASES（market 名 → objectID，运行时再校验
   objectID 在目录且 grade 一致）；一对多记 ambiguous（附候选），未命中记
   missed，两者都不请求均价。
   产物 data/ammo/official-anchor.json（/data/ 整体 gitignore；仅服务端
   sidecar，不经 HTTP/SSE 外发）：
     { fetchedAt, total, joined, missed:[name],
       ambiguous:[{name, candidates:[{objectID,officialName,grade}]}],
       items:[{name,objectID,officialName,via,moli,official,dev}] }
     via ∈ exact / normalized / alias（审计别名命中）；official/dev 为 null =
     该批失败或未请求（--limit 之外）。
   用法：node server/official/ammo-anchor.mjs --once [--limit N]
     末行打印单行 JSON：SUMMARY {"total","joined","missed","ambiguous",
     "devOver15","maxDev":{"name","dev"},"requests"}
     --limit N 是开发期预算工具：只对前 N 个已映射 id 请求均价（其余
     official=null），映射与落盘照常。
   定时：server.mjs 每 24h 一轮（启动延迟 2 分钟首跑；--no-anchor 关闭）。
   ============================================================ */
import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { getDirectory, normalizeName } from './object-directory.mjs'
import { fetchHourlyAvgPrice } from './ams-client.mjs'
import { writeJsonAtomic } from '../ammo/fetch-once.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')

/** 产物路径（相对仓库根） */
export const ANCHOR_REL = path.join('data', 'ammo', 'official-anchor.json')
/** |dev| 超过即逐弹告警 */
export const DEV_WARN_THRESHOLD = 0.15
/** 352246 单批硬限（上游约束，见 ams-client） */
export const PRICE_BATCH_SIZE = 5

/**
 * 显式别名表：market 弹名 → 官方 objectID。只登记精确 / 归一化都对不上、但
 * 对应关系能被独立证据钉死的条目；拿不准的宁可留在 missed。
 * .300BLK：官方三条同名「.300BLK」只靠 grade 区分（3/4/5）；moligod 以品质色
 * 前缀 蓝/紫/金 命名，且 market.json 自带 grade 3/4/5 与之一一吻合（2026-10-26
 * 实测，现价与官方均价差 <6%）。运行时仍校验 objectID 在目录且 grade 一致，
 * 任一不符即记 missed——别名失效不会被静默放行。
 */
export const AMMO_NAME_ALIASES = {
  '蓝.300BLK': '37280300001',
  '紫.300BLK': '37280400001',
  '金.300BLK': '37280500001',
}

const pushTo = (map, key, v) => {
  const arr = map.get(key)
  if (arr) arr.push(v)
  else map.set(key, [v])
}

/**
 * 弹名映射（纯函数）：精确 → 归一化 → 别名；一对多 → ambiguous；其余 missed。
 * 口径与 object-directory.findByName 一致，这里做成批量纯函数便于离线自测。
 * @param {Array<{name:string, current?:number, grade?:number}>} marketItems
 * @param {Array<{objectID:string|number, objectName:string, grade?:number}>} directoryItems
 * @param {{aliases?:Record<string,string>}} opts
 * @returns {{matched:Array<{name:string,objectID:string,officialName:string,via:string,moli:number|null}>,
 *            missed:string[],
 *            ambiguous:Array<{name:string,candidates:Array<{objectID:string,officialName:string,grade:number|null}>}>}}
 */
export function matchAmmoNames(marketItems, directoryItems, { aliases = AMMO_NAME_ALIASES } = {}) {
  const byExact = new Map()
  const byNorm = new Map()
  const byId = new Map()
  for (const it of directoryItems || []) {
    pushTo(byExact, it.objectName, it)
    pushTo(byNorm, normalizeName(it.objectName), it)
    byId.set(String(it.objectID), it)
  }
  const candidate = (it) => ({ objectID: String(it.objectID), officialName: it.objectName, grade: it.grade ?? null })
  const matched = []
  const missed = []
  const ambiguous = []
  for (const m of marketItems || []) {
    const name = String(m.name ?? '')
    const moli = Number.isFinite(Number(m.current)) ? Number(m.current) : null
    let hits = byExact.get(name) || []
    let via = 'exact'
    if (!hits.length) {
      hits = byNorm.get(normalizeName(name)) || []
      via = 'normalized'
    }
    if (hits.length === 1) {
      matched.push({ name, objectID: String(hits[0].objectID), officialName: hits[0].objectName, via, moli })
      continue
    }
    if (hits.length > 1) {
      ambiguous.push({ name, candidates: hits.map(candidate) })
      continue
    }
    // 别名兜底：objectID 必须在目录；双方都带 grade 时必须一致（防品质色前缀对错档）
    const hit = aliases && Object.hasOwn(aliases, name) ? byId.get(String(aliases[name])) : undefined
    const gradeOk = hit && (m.grade == null || hit.grade == null || Number(m.grade) === Number(hit.grade))
    if (hit && gradeOk) {
      matched.push({ name, objectID: String(hit.objectID), officialName: hit.objectName, via: 'alias', moli })
      continue
    }
    missed.push(name)
  }
  return { matched, missed, ambiguous }
}

/** dev = (moli − official) / official；任一缺失或 official 非正 → null。保留 4 位小数 */
export function computeDeviation(moli, official) {
  if (!Number.isFinite(moli) || !Number.isFinite(official) || official <= 0) return null
  return Math.round(((moli - official) / official) * 1e4) / 1e4
}

/** SUMMARY 行数据体：计数 + |dev| 最大项 + 实际批次数（键序固定，便于日志 grep） */
export function buildSummary(anchor, requests) {
  const priced = anchor.items.filter((i) => i.dev !== null)
  let maxDev = { name: null, dev: null }
  for (const i of priced) {
    if (maxDev.dev === null || Math.abs(i.dev) > Math.abs(maxDev.dev)) maxDev = { name: i.name, dev: i.dev }
  }
  return {
    total: anchor.total,
    joined: anchor.joined,
    missed: anchor.missed.length,
    ambiguous: anchor.ambiguous.length,
    devOver15: priced.filter((i) => Math.abs(i.dev) > DEV_WARN_THRESHOLD).length,
    maxDev,
    requests,
  }
}

/** CLI 末行格式：`SUMMARY ` + 单行 JSON */
export const formatSummaryLine = (summary) => `SUMMARY ${JSON.stringify(summary)}`

/**
 * 跑一轮官方均价锚：读 market.json（只读）→ 官方 ammo 目录 → 名称映射 →
 * 分批拉均价 → 写 data/ammo/official-anchor.json。
 * @param {{rootDir?:string, webDir?:string, limit?:number, paceMs?:number,
 *          loadDirectory?:Function, fetchPrices?:Function, aliases?:object, warn?:Function}} opts
 *   rootDir 仓库根（产物与目录缓存挂 data/）；webDir 网页端目录（默认
 *   rootDir/apps/web，market.json 从其 public/ammo/ 读）；limit 只对前 N 个
 *   已映射 objectID 请求均价（开发期预算，其余 official=null）；paceMs 批间隔
 *   （默认 400，selftest 传 0）；loadDirectory / fetchPrices 可注入替身（离线
 *   自测），默认 getDirectory / fetchHourlyAvgPrice；warn 默认 console.warn
 * @returns {Promise<{anchor:object, summary:object, requests:number, outPath:string}>}
 *   anchor 即落盘内容；requests 为 352246 实际批次数（目录刷新的 ≤1 次不计）
 * @throws market.json 缺失 / 损坏、目录不可用时如实抛出（调用方决定回落）
 */
export async function runAnchorCycle({
  rootDir = ROOT,
  webDir = path.join(rootDir, 'apps', 'web'),
  limit = Infinity,
  paceMs = 400,
  loadDirectory = (opts) => getDirectory({ primaries: ['ammo'], ...opts }),
  fetchPrices = fetchHourlyAvgPrice,
  aliases = AMMO_NAME_ALIASES,
  warn = console.warn,
} = {}) {
  const marketPath = path.join(webDir, 'public', 'ammo', 'market.json')
  const market = JSON.parse(await readFile(marketPath, 'utf8'))
  const marketItems = Array.isArray(market?.items) ? market.items : null
  if (!marketItems) throw new Error(`market.json 形状异常（items 非数组）：${marketPath}`)

  const { items: dirItems } = await loadDirectory({ rootDir })
  const { matched, missed, ambiguous } = matchAmmoNames(marketItems, dirItems, { aliases })

  const cap = Number.isFinite(limit) && limit >= 0 ? limit : Infinity
  const ids = [...new Set(matched.map((m) => m.objectID))].slice(0, cap)
  const requests = Math.ceil(ids.length / PRICE_BATCH_SIZE)
  const prices = ids.length ? await fetchPrices(ids, { batchSize: PRICE_BATCH_SIZE, paceMs }) : {}

  const items = matched.map((m) => {
    const raw = prices[m.objectID]
    const official = raw !== undefined && raw !== null && Number.isFinite(Number(raw)) ? Number(raw) : null
    const dev = computeDeviation(m.moli, official)
    if (dev !== null && Math.abs(dev) > DEV_WARN_THRESHOLD) {
      warn(`[anchor] ${m.name} moli ${m.moli} vs 官方 ${official} 偏差 ${(dev * 100).toFixed(1)}%`)
    }
    return { name: m.name, objectID: m.objectID, officialName: m.officialName, via: m.via, moli: m.moli, official, dev }
  })
  const anchor = {
    fetchedAt: new Date().toISOString(),
    total: marketItems.length,
    joined: items.length,
    missed,
    ambiguous,
    items,
  }
  const outPath = path.join(rootDir, ANCHOR_REL)
  await writeJsonAtomic(outPath, JSON.stringify(anchor))
  return { anchor, summary: buildSummary(anchor, requests), requests, outPath }
}

// ---- CLI 直跑 ----
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2)
  if (!argv.includes('--once')) {
    console.error('用法：node server/official/ammo-anchor.mjs --once [--limit N]')
    console.error('  只跑单轮；定时循环由 server.mjs 承担（默认 24h 一轮，--no-anchor 关闭）')
    process.exit(2)
  }
  let limit = Infinity
  const li = argv.indexOf('--limit')
  if (li >= 0) {
    limit = Number(argv[li + 1])
    if (!Number.isInteger(limit) || limit < 0) {
      console.error('--limit 需要非负整数')
      process.exit(2)
    }
  }
  try {
    const r = await runAnchorCycle({ limit })
    const a = r.anchor
    console.log(
      `✅ 官方均价锚已写入 ${path.relative(ROOT, r.outPath)} · 映射 ${a.joined}/${a.total}` +
        ` · 未命中 ${a.missed.length} · 歧义 ${a.ambiguous.length} · 请求 ${r.requests}` +
        (Number.isFinite(limit) ? `（--limit ${limit}）` : '')
    )
    for (const n of a.missed) console.log(`   ⚠ 未命中：${n}`)
    for (const x of a.ambiguous) console.log(`   ⚠ 歧义：${x.name} → ${x.candidates.map((c) => `${c.officialName}#${c.objectID}(g${c.grade})`).join(' / ')}`)
    for (const i of a.items.filter((i) => i.via === 'alias')) console.log(`   ↳ 别名命中：${i.name} → ${i.officialName}#${i.objectID}`)
    console.log(formatSummaryLine(r.summary))
  } catch (e) {
    console.error(`❌ 官方均价锚失败: ${e.message}`)
    process.exit(1)
  }
}
