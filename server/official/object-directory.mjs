/* ============================================================
   object-directory.mjs — 官方物品目录缓存（gun/ammo/protect，纯库零依赖）
   ------------------------------------------------------------
   数据源：ams-client 的 object.list（腾讯官方 AMS，免登录）；目录基本只随
   版本更新变动，TTL 24h 足够。双层缓存：
     · 进程级：模块态 byPrimary（同进程二次调用零 IO）
     · 磁盘：data/official/object-directory.json（/data/ 整体 gitignore，
       原子写 tmp+rename）；未过期且覆盖所需 primaries 时直接加载不发请求
   缓存文件形状：
     { fetchedAt: ISO, fetchedAtMs: number, ttlMs: 86400000,
       primaries: { gun: [条目…], ammo: […], protect: […] } }
   条目形状同 ams-client.fetchObjectList（objectID/objectName/grade/
   primaryClass/secondClass/avgPrice/pic + 各类 detail 透传）。
   目录刷新失败如实抛错，由调用方决定回落（不做静默兜底）。
   名字匹配口径：官方名实测有「7.62*39mm AP SUB」星号变体与零宽字符，
   findByName 先精确后归一化（normalizeName），一对多返回 ambiguous。
   用法：getDirectory() / findByName('M4A1突击步枪') / normalizeName(s)
   ============================================================ */
import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { fetchObjectList } from './ams-client.mjs'
import { writeJsonAtomic } from '../ammo/fetch-once.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')

/** 目录默认覆盖的三类（枪械 / 弹药 / 护甲——信号与利润链路的名称解析域） */
export const DIRECTORY_PRIMARIES = ['gun', 'ammo', 'protect']
/** 目录 TTL：物品属性基本只随版本更新变，一天一刷 */
export const DIRECTORY_TTL_MS = 24 * 60 * 60 * 1000

const CACHE_REL = path.join('data', 'official', 'object-directory.json')

/* ---------- 模块态（selftest 用 _resetForTest 清空；不删磁盘文件） ---------- */

let memCache = null // { fetchedAtMs, byPrimary: {primary: 条目数组} }

/** 清空进程级目录缓存（selftest 场景隔离专用，业务代码勿调） */
export function _resetForTest() {
  memCache = null
}

/**
 * 官方名归一化：去零宽字符（U+200B-200D / U+FEFF / U+2060）、全角转半角
 * （含全角空格）、'*'→'x'、小写、多空格折叠。解决官方名与社区口径的
 * 「7.62*39mm ↔ 7.62x39mm」星号变体等写法漂移。
 */
export function normalizeName(name) {
  return String(name ?? '')
    .replace(/[\u200B\u200C\u200D\uFEFF\u2060]/g, '')
    .replace(/[\uFF01-\uFF5E]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xFEE0))
    .replace(/\u3000/g, ' ')
    .replace(/\*/g, 'x')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim()
}

const cacheFilePath = (rootDir) => path.join(rootDir, CACHE_REL)

/** 缓存体是否未过期且覆盖所需 primaries */
function covers(cache, primaries) {
  return Boolean(cache) && Date.now() - cache.fetchedAtMs < DIRECTORY_TTL_MS &&
    primaries.every((p) => Array.isArray(cache.byPrimary[p]))
}

/** 读磁盘缓存文件；损坏 / 缺失返回 null（不抛——损坏当无缓存重抓） */
async function loadFileCache(rootDir) {
  const fp = cacheFilePath(rootDir)
  if (!existsSync(fp)) return null
  try {
    const raw = JSON.parse(await readFile(fp, 'utf8'))
    const fetchedAtMs = Number(raw.fetchedAtMs)
    if (!Number.isFinite(fetchedAtMs) || !raw.primaries) return null
    return { fetchedAtMs, byPrimary: raw.primaries }
  } catch {
    return null
  }
}

/**
 * 取官方物品目录（三层：进程缓存 → 磁盘缓存 → 真实抓取并回写两层）。
 * @param {{primaries?:string[], force?:boolean, rootDir?:string}} opts
 *   primaries 默认 gun/ammo/protect；force=true 绕过缓存强制重抓所需类
 *   （已缓存且未过期的其他类保留）；rootDir 默认仓库根（缓存文件挂 data/）
 * @returns {Promise<{fetchedAt:string, primaries:string[], items:object[]}>}
 *   items 为所请求 primaries 的并集（按 primaries 顺序拼接）
 * @throws 所需类抓取失败时如实抛出（调用方决定回落）
 */
export async function getDirectory({ primaries = DIRECTORY_PRIMARIES, force = false, rootDir = ROOT } = {}) {
  const wanted = [...new Set(primaries)]
  if (!wanted.length) throw new Error('getDirectory：primaries 不能为空')

  if (!force) {
    if (!covers(memCache, wanted)) {
      const fromDisk = await loadFileCache(rootDir)
      if (covers(fromDisk, wanted)) memCache = fromDisk
    }
    if (covers(memCache, wanted)) return buildResult(memCache, wanted)
  }

  // 需要抓取：force 重抓全部所需类；否则只补缺失 / 过期的类（进程内已有的保留）。
  // fetchedAtMs 为本轮刷新时刻——部分类沿用旧数据时该值偏乐观（目录日更口径下误差可忽略）
  const byPrimary = force ? {} : { ...(memCache?.byPrimary ?? {}) }
  const toFetch = force ? wanted : wanted.filter((p) => !covers(memCache, [p]))
  for (const p of toFetch) byPrimary[p] = await fetchObjectList({ primary: p }) // 失败如实抛
  const fresh = { fetchedAtMs: Date.now(), byPrimary }
  memCache = fresh
  await writeJsonAtomic(
    cacheFilePath(rootDir),
    JSON.stringify({
      fetchedAt: new Date(fresh.fetchedAtMs).toISOString(),
      fetchedAtMs: fresh.fetchedAtMs,
      ttlMs: DIRECTORY_TTL_MS,
      primaries: fresh.byPrimary,
    })
  )
  return buildResult(fresh, wanted)
}

/** 拼装返回视图（items 顺序 = wanted 顺序，条目保持抓取序） */
function buildResult(cache, wanted) {
  const items = []
  for (const p of wanted) items.push(...(cache.byPrimary[p] || []))
  return {
    fetchedAt: new Date(cache.fetchedAtMs).toISOString(),
    primaries: [...wanted],
    items,
  }
}

/**
 * 按名字查目录条目：精确 objectName → 归一化匹配（normalizeName）。
 * @param {string} name 目录未加载时会经 getDirectory 触发加载（有缓存则零请求）
 * @param {{rootDir?:string}} opts rootDir 透传 getDirectory（selftest 隔离用）
 * @returns {Promise<object|null|{ambiguous:true, matches:object[]}>}
 *   唯一命中返回条目；一对多返回 {ambiguous:true, matches}（调用方人工裁决）；无命中 null
 */
export async function findByName(name, { rootDir } = {}) {
  if (!name) return null
  const { items } = await getDirectory({ rootDir })
  const exact = items.filter((it) => it.objectName === name)
  if (exact.length === 1) return exact[0]
  if (exact.length > 1) return { ambiguous: true, matches: exact }
  const key = normalizeName(name)
  const fuzzy = items.filter((it) => normalizeName(it.objectName) === key)
  if (fuzzy.length === 1) return fuzzy[0]
  if (fuzzy.length > 1) return { ambiguous: true, matches: fuzzy }
  return null
}
