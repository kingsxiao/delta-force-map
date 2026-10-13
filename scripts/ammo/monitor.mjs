/* ============================================================
   monitor.mjs — 子弹行情实时监控主程序
   ------------------------------------------------------------
   循环：默认每 30 分钟抓取一次（上游数据约每小时更新，version 未变则跳过）；
   出现新的买入/卖出信号时发 macOS 系统通知，通知内容具体到：
     · 哪种子弹
     · 多少价格可以买入（当前价）
     · 什么时候卖出（目标挂单价 + 到手价，以及"贴近7天高位就出"的判定）
     · 能赚多少（每发利润 + 收益率，已扣交易税）
   去重：state 记录每子弹上次通知的信号/价格/时间；同信号 6 小时冷却，
         信号切换（如 BUY→SELL）立即通知，冷却期内价格再跌 5% 也重新提示。
   用法：node scripts/ammo/monitor.mjs [--interval 分钟=30] [--once] [--no-notify]
   ============================================================ */
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { fetchOnce } from './fetch-once.mjs'
import { notify } from './notify.mjs'
import { fmtPrice, fmtPct } from './analyze.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const STATE_PATH = path.join(ROOT, 'data', 'ammo', 'monitor-state.json')
const COOLDOWN_MS = 6 * 60 * 60 * 1000
const REDROP_PCT = 0.05 // 冷却期内价格再跌 5% 重新提示

// ---- CLI 参数 ----
const argv = process.argv.slice(2)
const flag = (name) => argv.includes(`--${name}`)
const opt = (name, dflt) => {
  const i = argv.indexOf(`--${name}`)
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? Number(argv[i + 1]) : dflt
}
const INTERVAL_MIN = opt('interval', 30)
const ONCE = flag('once')
const NO_NOTIFY = flag('no-notify')

async function loadState() {
  try {
    return JSON.parse(await readFile(STATE_PATH, 'utf8'))
  } catch {
    return { items: {} }
  }
}

async function saveState(state) {
  await mkdir(path.dirname(STATE_PATH), { recursive: true })
  await writeFile(STATE_PATH, JSON.stringify(state))
}

/** 买入通知正文：哪种子弹 / 多少价格买 / 什么时候卖 / 能赚多少 */
function buyLine(i) {
  const high = `7天高点到手${fmtPrice(i.netHigh)}`
  return `${i.name} 买入≤${fmtPrice(i.current)} → 挂卖${fmtPrice(i.targetSell)}(到手${fmtPrice(i.netSell)}) 预赚${fmtPrice(i.profitPerRound)}/发(${fmtPct(i.profitPct)})，${high}`
}

function sellLine(i) {
  return `${i.name} 现价${fmtPrice(i.current)}，处7天${Math.round(i.rank * 100)}%高位，建议立即挂卖`
}

/** 判断某子弹某信号是否值得通知（冷却 + 信号切换 + 深跌重报） */
function shouldNotify(state, item, signal) {
  const prev = state.items[item.name]
  const now = Date.now()
  if (!prev) return true
  if (prev.signal !== signal) return true
  if (now - prev.at >= COOLDOWN_MS) return true
  if (signal === 'BUY' && prev.price && item.current <= prev.price * (1 - REDROP_PCT)) return true
  return false
}

async function runCycle(state) {
  let r
  try {
    r = await fetchOnce()
  } catch (e) {
    console.error(`[${new Date().toLocaleString('zh-CN')}] 抓取失败: ${e.message}`)
    return
  }
  if (!r.changed) {
    // version 未变也要跑信号判断：首次启动、冷却到期、信号切换都需要补发通知；
    // version 未变时信号集合基本不变，冷却逻辑会挡住重复通知。
    console.log(`[${new Date().toLocaleString('zh-CN')}] version ${r.version} 未变化，仅核对信号`)
  } else {
    console.log(
      `[${new Date().toLocaleString('zh-CN')}] version ${r.version} · 买入 ${r.analysis.stats.buy} / 卖出 ${r.analysis.stats.sell} / 关注 ${r.analysis.stats.watch}`
    )
  }
  const { analysis } = r

  const buys = analysis.signals.buy.filter((i) => shouldNotify(state, i, 'BUY'))
  const sells = analysis.signals.sell.filter((i) => shouldNotify(state, i, 'SELL'))

  if (buys.length && !NO_NOTIFY) {
    const top = buys.slice(0, 3) // 通知正文有限，最多报 3 条，其余进页面
    const body = top.map((i) => `🎯 ${buyLine(i)}`).join('\n')
    await notify({
      title: `三角洲子弹买入信号 ×${buys.length}`,
      body: buys.length > top.length ? body + `\n…还有${buys.length - top.length}种见 #/ammo 页` : body,
      sound: 'Glass',
    })
  }
  if (sells.length && !NO_NOTIFY) {
    const top = sells.slice(0, 3)
    const body = top.map((i) => `📈 ${sellLine(i)}`).join('\n')
    await notify({
      title: `三角洲子弹卖出信号 ×${sells.length}`,
      body: sells.length > top.length ? body + `\n…还有${sells.length - top.length}种见 #/ammo 页` : body,
      sound: 'Hero',
    })
  }
  for (const i of buys) state.items[i.name] = { signal: 'BUY', price: i.current, at: Date.now() }
  for (const i of sells) state.items[i.name] = { signal: 'SELL', price: i.current, at: Date.now() }
  await saveState(state)
}

const state = await loadState()
console.log(`子弹行情监控启动：每 ${INTERVAL_MIN} 分钟抓取一次（Ctrl+C 退出）`)
await runCycle(state)
if (!ONCE) {
  setInterval(() => runCycle(state), INTERVAL_MIN * 60 * 1000)
}
