/* ============================================================
   refresh-data.mjs — 统一数据刷新（CI 定时任务 / 本地手动共用）
   ------------------------------------------------------------
   弹药：先按上次快照的 fetchedAt 预热曲线缓存（TTL 从真实抓取时间起算，
   30min 内的曲线不重抓——CI 冷 runner 上等效 live 服务的稳态节奏，不会
   对上游打满 67 条 history），再 fetchOnce(auto)。
   雷达：runRadarCycle 一轮（双源交叉验证）。
   两路独立容错：一路失败不拖累另一路；两路全挂才 exit 1（CI 侧配合
   continue-on-error，部署降级为旧快照 + 页面如实标注数据年龄）。
   用法：node scripts/refresh-data.mjs（npm run refresh）
   ============================================================ */
import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { primeCurveCache } from './ammo/moligod-client.mjs'
import { fetchOnce } from './ammo/fetch-once.mjs'
import { runRadarCycle } from './market/radar.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const log = (msg) => console.log(`[${new Date().toLocaleString('zh-CN')}] ${msg}`)

async function refreshAmmo() {
  const marketPath = path.join(ROOT, 'public', 'ammo', 'market.json')
  if (existsSync(marketPath)) {
    try {
      const prev = JSON.parse(await readFile(marketPath, 'utf8'))
      // 按真实抓取时间预热（同 live.mjs 启动序列）：刚抓过的曲线不重抓
      const t = Date.parse(prev.fetchedAt)
      primeCurveCache(prev.items, Number.isFinite(t) ? { fetchedAt: t } : {})
    } catch {
      /* 损坏快照忽略，冷启动全量补齐 */
    }
  }
  const r = await fetchOnce({ mode: 'auto' })
  log(`[ammo] ${r.source} version ${r.version}${r.changed ? '' : '（内容未变，心跳）'}`)
}

async function refreshRadar() {
  const out = await runRadarCycle({ noNotify: true })
  log(`[radar] version ${out.version} · ${out.stats.total} 项 · 异常 ${out.stats.anomaly}`)
}

let failed = 0
await refreshAmmo().catch((e) => {
  failed++
  console.error(`[${new Date().toLocaleString('zh-CN')}] [ammo] 刷新失败：${e.message}`)
})
await refreshRadar().catch((e) => {
  failed++
  console.error(`[${new Date().toLocaleString('zh-CN')}] [radar] 刷新失败：${e.message}`)
})
process.exit(failed >= 2 ? 1 : 0)
