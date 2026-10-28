/* ============================================================
   fetch-once.mjs — 单次抓取 + 分析 + 落盘（可独立运行，被 monitor / live 复用）
   ------------------------------------------------------------
   产物：
     apps/web/public/ammo/market.json  前端唯一数据源（原始快照 + 分析字段合并，
                                       顶层含 source / fingerprint / rules /
                                       officialAnchor；items 带 chg24h / chg7d /
                                       official 官方均价参照）
     apps/web/dist/ammo/market.json    构建产物存在时联动（vite preview 同样吃
                                       新数据；--no-dist 可关）
     data/ammo/history/<version>.json  原始快照留档（.gitignore；仅内容指纹变化
                                       且距上次留档 ≥10 分钟才写；超 7 天或超
                                       1000 份自动清理，防分钟级 version 撑爆磁盘）
   选源：默认主源 moligod（分钟级，67 种）；moligod 重试 2 次仍失败（网络 /
       429 / 形状校验不过）自动回落既有 kkrb（小时级，88 种）。--source 可指定，
       --no-fallback 关闭自动回落。
   写盘：同目录 .tmp 写入后 rename 原子替换（live 下写频约每分钟，直写会让
       页面 fetch 撞上半截 JSON）；门槛 = 指纹（sha256 价格向量）变化，或距
       上次写盘超 5 分钟心跳（心跳用于区分「价格没动」与「链路断了」——
       心跳会刷新 fetchedAt，页面的数据年龄标签随之归零）。
   用法：node server/ammo/fetch-once.mjs [--source moligod|kkrb] [--no-fallback] [--no-dist]
   ============================================================ */
import { createHash, randomUUID } from 'node:crypto'
import { mkdir, writeFile, readFile, readdir, stat, rename, unlink } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { fetchAmmoMarket } from './kkrb-client.mjs'
import { getSnapshot } from './moligod-client.mjs'
import { analyzeMarket } from './analyze.mjs'
import { fetchQuartermaster } from './quartermaster.mjs'
import { fetchSeason } from './season.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
/** 网页端目录（多端 monorepo：public/ 与 dist/ 都在 apps/web 下；selftest 注入临时 rootDir 时 webDir 跟随 rootDir） */
const WEB_DIR = path.join(ROOT, 'apps', 'web')

/** 官方均价锚产物相对路径（server/official/ammo-anchor.mjs 每 24h 一轮写入；
 *  fetch-once 挂在 rootDir 下读——selftest 注入临时 rootDir 时自然无锚即跳过。
 *  不反向 import 该模块：它已 import 本文件的 writeJsonAtomic，再反向会成环） */
const ANCHOR_REL = path.join('data', 'ammo', 'official-anchor.json')

/** 同指纹最长静默：超过则重写一次盘（心跳，刷新 fetchedAt） */
export const HEARTBEAT_MS = 5 * 60 * 1000
const ARCHIVE_MIN_GAP_MS = 10 * 60 * 1000
const ARCHIVE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000
const ARCHIVE_MAX_FILES = 1000

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** 内容指纹：任一弹现价 / 曲线长度 / 曲线末点变化即翻转（sha256） */
export function priceFingerprint(items) {
  const vec = (items || []).map((i) => [
    i.name,
    Math.round((Number(i.current) || 0) * 100),
    (i.curve && i.curve.length) || 0,
    i.curve && i.curve.length ? i.curve[i.curve.length - 1][1] : null,
  ])
  return createHash('sha256').update(JSON.stringify(vec)).digest('hex')
}

/** 原子写 JSON：tmp 落盘后 rename，读方永远不会看到半截文件。
 *  tmp 名带 pid+随机段——违反「同时只跑一个写盘者」时（monitor 挂着又手动
 *  ammo:fetch），并发写者各自独立 tmp、两个 rename 都原子成立（后写胜出，
 *  下轮自愈），不会互相搬走对方正在写的半截内容 */
export async function writeJsonAtomic(filePath, text) {
  await mkdir(path.dirname(filePath), { recursive: true })
  const tmp = `${filePath}.${process.pid}.${randomUUID().slice(0, 8)}.tmp`
  await writeFile(tmp, text)
  try {
    await rename(tmp, filePath)
  } catch (e) {
    await unlink(tmp).catch(() => {}) // rename 失败（如目录被删）不留孤儿 tmp
    throw e
  }
}

/**
 * 快照双写：public 恒写，dist 目录存在（跑过 build）时同内容联动——vite
 * preview serve dist/，不同步会复现「线上刷新永远拿到构建时旧快照」的原始
 * 问题。四处「public + dist 双写」（fetch-once / market/radar / craft/
 * snapshot / ttk/official-audit）统一复用本助手，dist 存在性判定归一为
 * existsSync(dist 文件所在目录)。
 * @param {string} webDir 网页端目录（public/ 与 dist/ 的共同父目录）
 * @param {string} relPath 产物相对路径（public 与 dist 下同名同层，如 'ammo/market.json'）
 * @param {string} text 落盘内容（序列化后的 JSON 字符串）
 * @returns {Promise<string[]>} 实际写入的绝对路径列表（public 恒在，dist 命中时追加）
 */
export async function writeSnapshotPair(webDir, relPath, text) {
  const pub = path.join(webDir, 'public', relPath)
  await writeJsonAtomic(pub, text)
  const written = [pub]
  const dist = path.join(webDir, 'dist', relPath)
  if (existsSync(path.dirname(dist))) {
    await writeJsonAtomic(dist, text)
    written.push(dist)
  }
  return written
}

/**
 * join 官方均价锚（读取 data/ammo/official-anchor.json，缺档/坏档静默跳过——
 * 官方锚是旁路参照，永不因它阻塞主链路）：逐弹挂 official = { avg, dev, at }，
 * dev 按本快照现价现算（锚文件里的 dev 是锚抓取时刻对 moligod 的，口径过期）。
 * 官方 avg 与服务源无关（官方是官方），moligod / kkrb 快照都 join；按弹名精确
 * 匹配，锚里没有的弹不造字段。返回新数组，不改动入参。
 * @param {Array<{name:string, current:number}>} items 分析产物 items
 * @returns {{items: Array, officialAnchor: {fetchedAt:string, joined:number}|null}}
 */
export async function joinOfficialAnchor(items, anchorPath = path.join(ROOT, ANCHOR_REL)) {
  let anchor = null
  try {
    anchor = JSON.parse(await readFile(anchorPath, 'utf8'))
  } catch {
    return { items, officialAnchor: null } // 未跑过 anchor:fetch / 文件损坏：如实无参照
  }
  const byName = new Map()
  for (const it of anchor.items || []) {
    if (it && typeof it.name === 'string' && Number.isFinite(Number(it.official)) && Number(it.official) > 0)
      byName.set(it.name, Number(it.official))
  }
  if (!byName.size) return { items, officialAnchor: null }
  const at = typeof anchor.fetchedAt === 'string' ? anchor.fetchedAt : null
  const merged = items.map((i) => {
    const avg = byName.get(i.name)
    if (avg == null || !(i.current > 0)) return i
    return { ...i, official: { avg, dev: Math.round(((i.current - avg) / avg) * 1e4) / 1e4, at } }
  })
  return { items: merged, officialAnchor: { fetchedAt: at, joined: byName.size } }
}

/**
 * join 军需处兑换折算（fetchQuartermaster 的产物按弹名精确合并）：
 * items[].trade = { costPerRound, perCount, marketPrice, materials, version }。
 * 军需处是弹价地板之一（Playbook 01「军需处倒挂」），折算价/发给用户
 * 「先扫军需处还是直接扫交易行」的判断依据。按名精确匹配（实测 6/7 命中，
 * 命名差异宁缺毋滥），交易行现价在快照里另有 current，trade 不重复存。
 * @param {Array<{name:string}>} items 分析产物 items
 * @param {{version:string, items:Array}|null} trade fetchQuartermaster 产物（null 跳过）
 * @returns {Array} 新数组，不改动入参
 */
export function joinQuartermaster(items, trade) {
  if (!trade || !Array.isArray(trade.items) || !trade.items.length) return items
  const byName = new Map(trade.items.map((t) => [t.name, t]))
  return items.map((i) => {
    const t = byName.get(i.name)
    return t ? { ...i, trade: { costPerRound: t.costPerRound, perCount: t.perCount, marketPrice: t.marketPrice, materials: t.materials, version: t.version } } : i
  })
}

/**
 * join 赛季日历到快照顶层（season = {name, start, end, fetchedAt, events}）。
 * Playbook「版本与赛季窗口」的倒计时与阶段判定数据源；null 跳过。
 */
export function joinSeason(analysis, season) {
  if (!season) return analysis
  return { ...analysis, season }
}

/**
 * 抓取并分析一次，按门槛落盘。
 * @param {{force?:boolean, source?:'moligod'|'kkrb', mode?:'fast'|'auto'|'full',
 *          fallback?:boolean, syncDist?:boolean, rootDir?:string, webDir?:string,
 *          paceMs?:number}} opts
 *   mode 透传 moligod-client.getSnapshot（kkrb 路径忽略）；rootDir 仓库根
 *   （data/ 留档挂这里），webDir 网页端目录（public/dist 写入，默认 = rootDir，
 *   selftest 传临时目录即原行为）；paceMs 为 full 曲线串行抓取间隔（默认
 *   400ms，selftest 传 0）
 * @returns {Promise<{changed:boolean, version:string, source:string, analysis:object}>}
 * @throws 两个源都失败时抛出（调用方决定退避）
 */
export async function fetchOnce({
  force = false,
  source = 'moligod',
  mode = 'auto',
  fallback = true,
  syncDist = true,
  rootDir = ROOT,
  webDir = rootDir,
  paceMs = 400,
} = {}) {
  // —— 抓取：主源 moligod（重试 2 次）→ 兜底 kkrb ——
  let usedSource = source
  let snapshot = null
  let primaryErr = null
  if (source === 'moligod') {
    for (let attempt = 0; attempt < 3 && !snapshot; attempt++) {
      try {
        snapshot = await getSnapshot({ mode, paceMs })
      } catch (e) {
        primaryErr = e
        if (attempt < 2) await sleep(1500 * (attempt + 1))
      }
    }
    if (!snapshot) {
      if (!fallback) throw primaryErr
      console.error(`[fetch-once] moligod 主源失败（${primaryErr.message}），回落 kkrb`)
      usedSource = 'kkrb'
    }
  }
  if (!snapshot) snapshot = await fetchAmmoMarket() // kkrb：直选或回落

  // 旁路参照三件套 join（口径同 official-anchor：失败静默跳过、不进指纹、
  // 不阻塞主链路）：官方均价 / 军需处兑换折算 / 赛季日历
  let analysis = { ...analyzeMarket(snapshot), source: usedSource }
  const joined = await joinOfficialAnchor(analysis.items, path.join(rootDir, ANCHOR_REL))
  analysis.items = joined.items
  analysis.officialAnchor = joined.officialAnchor
  try {
    analysis = { ...analysis, items: joinQuartermaster(analysis.items, await fetchQuartermaster()) }
  } catch { /* 军需处上游失败：无参照地照常出快照 */ }
  try {
    const season = await fetchSeason()
    if (season) analysis = joinSeason(analysis, season)
  } catch { /* 赛季日历上游失败：同上 */ }
  const outPath = path.join(webDir, 'public', 'ammo', 'market.json')

  // —— 写盘门槛：无上次快照 / 指纹变化 / 距上次写盘超 5 分钟心跳 / force ——
  let prev = null
  if (existsSync(outPath)) {
    try {
      prev = JSON.parse(await readFile(outPath, 'utf8'))
    } catch {
      /* 损坏则视为无上次快照，直接重写 */
    }
  }
  const fp = priceFingerprint(analysis.items)
  const prevMtimeMs = existsSync(outPath) ? (await stat(outPath)).mtimeMs : 0
  const contentChanged = !prev || prev.fingerprint !== fp
  const changed = force || contentChanged || Date.now() - prevMtimeMs > HEARTBEAT_MS
  if (!changed) return { changed: false, version: analysis.version, source: usedSource, analysis }

  const text = JSON.stringify({ ...analysis, fingerprint: fp })
  // public + dist 双写统一走 writeSnapshotPair；--no-dist（syncDist=false）时只写 public
  if (syncDist) await writeSnapshotPair(webDir, path.join('ammo', 'market.json'), text)
  else await writeJsonAtomic(outPath, text)
  await maybeArchive(rootDir, snapshot, analysis, fp, contentChanged)
  return { changed: true, version: analysis.version, source: usedSource, analysis }
}

/** 留档：仅内容变化且距上次留档 ≥10 分钟；顺带清理超龄 / 超量旧档 */
async function maybeArchive(rootDir, snapshot, analysis, fp, contentChanged) {
  const dir = path.join(rootDir, 'data', 'ammo', 'history')
  await mkdir(dir, { recursive: true })
  const files = (await readdir(dir)).filter((f) => f.endsWith('.json'))
  const now = Date.now()
  const metas = []
  let lastAt = 0
  for (const f of files) {
    const m = await stat(path.join(dir, f))
    metas.push([f, m.mtimeMs])
    if (m.mtimeMs > lastAt) lastAt = m.mtimeMs
  }

  let archived = false
  if (contentChanged && (metas.length === 0 || now - lastAt >= ARCHIVE_MIN_GAP_MS)) {
    await writeJsonAtomic(
      path.join(dir, `${snapshot.version}.json`),
      JSON.stringify({ ...snapshot, analysis: { signals: analysis.signals, stats: analysis.stats } })
    )
    archived = true
  }

  // 清理：>7 天先删；仍超 1000 份（含刚写的）按 mtime 从最旧开始删
  const doomed = new Set(metas.filter(([, t]) => now - t > ARCHIVE_MAX_AGE_MS).map(([f]) => f))
  const rest = metas.filter(([f, t]) => now - t <= ARCHIVE_MAX_AGE_MS).sort((a, b) => a[1] - b[1])
  const total = metas.length + (archived ? 1 : 0)
  let excess = total - doomed.size - ARCHIVE_MAX_FILES
  let idx = 0
  while (excess > 0 && idx < rest.length) {
    doomed.add(rest[idx][0])
    excess--
    idx++
  }
  for (const f of doomed) await unlink(path.join(dir, f)).catch(() => {})
}

// ---- CLI 直跑 ----
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2)
  const optStr = (name, dflt) => {
    const i = argv.indexOf(`--${name}`)
    return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : dflt
  }
  try {
    const r = await fetchOnce({
      force: true,
      source: optStr('source', 'moligod'),
      fallback: !argv.includes('--no-fallback'),
      syncDist: !argv.includes('--no-dist'),
      webDir: WEB_DIR,
    })
    const s = r.analysis.signals
    console.log(`✅ [${r.source}] version ${r.version} · ${r.analysis.stats.total} 种弹药`)
    console.log(`   买入信号 ${s.buy.length} · 卖出信号 ${s.sell.length} · 低位关注 ${s.watch.length}`)
    for (const i of s.buy.slice(0, 5)) {
      console.log(`   🎯 ${i.name} 买≤${Math.round(i.current)} 目标卖${Math.round(i.targetSell)}(税后${Math.round(i.netSell)}) 预赚+${Math.round(i.profitPerRound)}/发(${(i.profitPct * 100).toFixed(1)}%)`)
    }
  } catch (e) {
    console.error(`❌ 抓取失败: ${e.message}`)
    process.exit(1)
  }
}
