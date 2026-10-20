/* ============================================================
   monitor.mjs — 子弹行情实时监控主程序（不开 live 服务时的通知器）
   ------------------------------------------------------------
   循环：默认每 10 分钟抓取一次（主源 moligod 分钟级；上游 version/指纹
   未变则跳过写盘，但每轮仍核对信号——冷却到期、信号切换需补发通知）。
   每轮抓取按曲线缓存状态自动选模式：冷启动 / 缓存过期时自动补抓缺失
   曲线（mode 'auto' 内核），缓存新鲜时每轮只打 1 次 catalog——不会把
   过期缓存当新数据，也不会产出全「数据不足」的快照。
   出现新的买入/卖出信号时发 macOS 系统通知，通知内容具体到：
     · 哪种子弹 / 多少价格可以买入（当前价）
     · 什么时候卖出（目标挂单价 + 到手价）
     · 能赚多少（每发利润 + 收益率，已扣交易税）
   去重（notify-policy.mjs，与 live.mjs 共用 state 文件）：每轮全量记录
   信号与 streak；首次出现立即通知；信号切换需连续 2 轮确认（分钟级
   数据在分位边界抖动防刷屏）；同信号 6 小时冷却；BUY 冷却期内价格再
   跌 5% 重新提示。
   要页面级实时（SSE ≤5s 反映落盘），改跑 npm run ammo:live。
   用法：node server/ammo/monitor.mjs [--interval 分钟=10] [--once] [--no-notify]
         （--no-notify 仅停通知；去抖 state 仍逐轮记录，恢复通知后不爆发）
   注意：live / monitor / 手动 ammo:fetch 同为写盘者，同时只跑一个。
   ============================================================ */
import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { fetchOnce, writeJsonAtomic } from './fetch-once.mjs'
import { judgeSignals, sendNotifications, emptyState } from './notify-policy.mjs'
import { notify } from './notify.mjs'
import { primeCurveCache } from './moligod-client.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const WEB_DIR = path.join(ROOT, 'apps', 'web')
const STATE_PATH = path.join(ROOT, 'data', 'ammo', 'monitor-state.json')

// ---- CLI 参数 ----
const argv = process.argv.slice(2)
const flag = (name) => argv.includes(`--${name}`)
const opt = (name, dflt) => {
  const i = argv.indexOf(`--${name}`)
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? Number(argv[i + 1]) : dflt
}
const INTERVAL_MIN = opt('interval', 10)
const ONCE = flag('once')
const NO_NOTIFY = flag('no-notify')

async function loadState() {
  try {
    return JSON.parse(await readFile(STATE_PATH, 'utf8'))
  } catch {
    return emptyState()
  }
}

async function saveState(state) {
  // 原子写：与 live.mjs 共用本文件，裸 writeFile 可能留下半截 state
  await writeJsonAtomic(STATE_PATH, JSON.stringify(state))
}

const state = await loadState()

// 启动预热：现有 market.json 的曲线进缓存，冷启动第一轮不必全量打 history
{
  const marketPath = path.join(WEB_DIR, 'public', 'ammo', 'market.json')
  if (existsSync(marketPath)) {
    try {
      primeCurveCache(JSON.parse(await readFile(marketPath, 'utf8')).items)
    } catch {
      /* 损坏快照忽略 */
    }
  }
}

async function runCycle() {
  let r
  try {
    // mode 默认 'auto'：曲线缓存有过期/缺失才补抓，稳态每轮只打 1 次 catalog
    r = await fetchOnce({ webDir: WEB_DIR })
  } catch (e) {
    console.error(`[${new Date().toLocaleString('zh-CN')}] 抓取失败: ${e.message}`)
    return
  }
  console.log(
    `[${new Date().toLocaleString('zh-CN')}] [${r.source}] version ${r.version} · 买入 ${r.analysis.stats.buy} / 卖出 ${r.analysis.stats.sell} / 关注 ${r.analysis.stats.watch}` +
      (r.changed ? '' : '（内容未变，仅核对信号）')
  )

  // 去抖 state 无论如何逐轮记录（静默期也推进冷却/切换确认）——否则静默跑
  // ≥6h 后恢复通知时，全部现存信号冷却到期会一次性爆发；仅发送受 --no-notify 控制
  const { buys, sells } = judgeSignals(state, r.analysis.items)
  if (!NO_NOTIFY) await sendNotifications(buys, sells, notify)
  await saveState(state)
}

console.log(`子弹行情监控启动：每 ${INTERVAL_MIN} 分钟抓取一次（Ctrl+C 退出）`)
await runCycle()
if (!ONCE) {
  // 链式调度（与 live.mjs fastLoop/slowLoop 同构）：await 本轮完成后再 setTimeout
  // 下一轮，结构上保证 runCycle 不会重叠并发——setInterval fire-and-forget 时慢轮次
  // （moligod 3 次重试 + kkrb 兜底，最坏 ~40s）可与下一轮交错写 market.json、
  // 交错读写共享去抖 state。间隔语义：本轮完成后起算（与 live.mjs 一致）。
  const schedule = () => setTimeout(async () => { await runCycle(); schedule() }, INTERVAL_MIN * 60 * 1000)
  schedule()
}
