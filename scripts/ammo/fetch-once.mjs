/* ============================================================
   fetch-once.mjs — 单次抓取 + 分析 + 落盘（可独立运行，也被 monitor 复用）
   ------------------------------------------------------------
   产物：
     public/ammo/market.json      前端唯一数据源（原始快照 + 分析字段合并）
     data/ammo/history/<version>.json  原始快照留档（.gitignore）
   用法：node scripts/ammo/fetch-once.mjs
   ============================================================ */
import { mkdir, writeFile, readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { fetchAmmoMarket } from './kkrb-client.mjs'
import { analyzeMarket } from './analyze.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const PUBLIC_DIR = path.join(ROOT, 'public', 'ammo')
const HISTORY_DIR = path.join(ROOT, 'data', 'ammo', 'history')

/**
 * 抓取并分析一次。
 * @param {{force?:boolean}} opts force=true 时即使 version 与上次相同也重新落盘
 * @returns {Promise<{changed:boolean, version:string, analysis:object}|null>} 失败返回 null
 */
export async function fetchOnce({ force = false } = {}) {
  const snapshot = await fetchAmmoMarket()
  const analysis = analyzeMarket(snapshot)

  await mkdir(PUBLIC_DIR, { recursive: true })
  const prevPath = path.join(PUBLIC_DIR, 'market.json')
  let prevVersion = null
  if (existsSync(prevPath)) {
    try {
      prevVersion = JSON.parse(await readFile(prevPath, 'utf8')).version
    } catch { /* 损坏则视为无上次版本 */ }
  }
  const changed = force || prevVersion !== snapshot.version
  if (!changed) return { changed: false, version: snapshot.version, analysis }

  await writeFile(path.join(PUBLIC_DIR, 'market.json'), JSON.stringify(analysis))
  await mkdir(HISTORY_DIR, { recursive: true })
  await writeFile(
    path.join(HISTORY_DIR, `${snapshot.version}.json`),
    JSON.stringify({ ...snapshot, analysis: { signals: analysis.signals, stats: analysis.stats } })
  )
  return { changed: true, version: snapshot.version, analysis }
}

// ---- CLI 直跑 ----
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const r = await fetchOnce({ force: true })
    const s = r.analysis.signals
    console.log(`✅ version ${r.version} · ${r.analysis.stats.total} 种弹药`)
    console.log(`   买入信号 ${s.buy.length} · 卖出信号 ${s.sell.length} · 低位关注 ${s.watch.length}`)
    for (const i of s.buy.slice(0, 5)) {
      console.log(`   🎯 ${i.name} 买≤${Math.round(i.current)} 目标卖${Math.round(i.targetSell)}(税后${Math.round(i.netSell)}) 预赚+${Math.round(i.profitPerRound)}/发(${(i.profitPct * 100).toFixed(1)}%)`)
    }
  } catch (e) {
    console.error(`❌ 抓取失败: ${e.message}`)
    process.exit(1)
  }
}
