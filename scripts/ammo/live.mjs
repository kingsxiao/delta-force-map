/* ============================================================
   live.mjs — 本地子弹行情 live 服务（node:http 零依赖，吸收 monitor 职责）
   ------------------------------------------------------------
   与 npm run dev 同跑时，页面端到端延迟 = 源分钟粒度 + 60s 快轮询 + SSE ≤5s。
   · fast loop：每 60s（±5s 抖动，对齐 catalog ttl_seconds=60）fetchOnce
     ({mode:'fast'})——每轮只打 1 次 catalog，曲线全部吃模块缓存（≈59 次/小时）
   · slow loop：每 30min fetchOnce({mode:'auto'})——补抓过期（≥30min TTL）/
     缺失的曲线；计时在本轮完成后重启，稳态下轮曲线必已过期，等效每 ≈31min
     全量刷 67 条（+1 catalog ≈132 次/小时；两环合计 ≈190 次/小时）
   · 启动：从现有 public/ammo/market.json 预热曲线缓存（重启不丢曲线），
     冷启动一轮按缓存状态选模式（auto：预热命中只打 1 次 catalog；覆盖率
     低/曲线过期则自动补齐，等效 full），再进 fast loop
   · SSE（http://127.0.0.1:8787/events，仅绑回环地址，ACAO:*）：
     连接即发命名事件 event:hello（{version,source,generatedAt}），每次落盘
     广播 event:market（轻量 ping，页面收到后自拉 market.json——复用既有
     数据路径，SSE 只做「该刷新了」的信号）；每 25s 发注释心跳防代理断连
   · /health：{source, lastSuccessAt, consecutiveFailures, ...}
   · 兜底节奏：fetchOnce 内部 moligod→kkrb 自动回落；live 按实际服务源调
     节奏（kkrb 时降 10min，每 3 轮探活一次 moligod 切回）；两源全挂时
     指数退避（1min 起、×2、cap 10min），成功即复位
   · 通知：复用 notify-policy（streak 去抖），与 monitor.mjs 共用 state 文件
   · dist 联动：fetchOnce 检测 dist/ammo 存在时同步写（--no-dist 关闭），
     vite preview 下页面同样拿到新数据
   用法：node scripts/ammo/live.mjs [--port 8787] [--no-notify] [--no-dist]
   注意：live / monitor / 手动 ammo:fetch 同为写盘者，同时只跑一个。
   ============================================================ */
import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import http from 'node:http'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { fetchOnce, writeJsonAtomic } from './fetch-once.mjs'
import { primeCurveCache } from './moligod-client.mjs'
import { judgeSignals, sendNotifications, emptyState } from './notify-policy.mjs'
import { notify } from './notify.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const DEFAULT_STATE_PATH = path.join(ROOT, 'data', 'ammo', 'monitor-state.json')
const KKRBCADENCE_MS = 10 * 60 * 1000 // 兜底源为小时档数据，10min 轮询足够
const PROBE_EVERY = 3 // 每 3 轮 kkrb 服务，探活一次 moligod
const log = (msg) => console.log(`[${new Date().toLocaleString('zh-CN')}] ${msg}`)

async function loadState(statePath) {
  try {
    return JSON.parse(await readFile(statePath, 'utf8'))
  } catch {
    return emptyState()
  }
}

/**
 * 创建 live 服务（不 listen；selftest 用 port 0 自取临时端口）。
 * @returns {{server:http.Server, triggerCycle:Function, status:object, close:Function}}
 */
export function createLiveServer({
  noNotify = false,
  noDist = false,
  rootDir = ROOT,
  statePath = DEFAULT_STATE_PATH,
  fastMs = 60 * 1000,
  slowMs = 30 * 60 * 1000,
} = {}) {
  const clients = new Set()
  const status = {
    source: null,
    version: null,
    generatedAt: null,
    lastSuccessAt: null,
    consecutiveFailures: 0,
    cycles: 0,
  }
  let servedByKkrbRounds = 0
  let forceProbe = false
  let failBackoffMs = 60 * 1000
  let fastTimer = null
  let slowTimer = null
  let hbTimer = null
  let closing = false
  let state = emptyState()

  function broadcast(event, payload) {
    for (const res of clients) {
      try {
        res.write(`event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`)
      } catch {
        clients.delete(res)
      }
    }
  }

  async function cycle(mode) {
    const opts = { mode, fallback: true, syncDist: !noDist, rootDir }
    if (forceProbe) Object.assign(opts, { source: 'moligod', fallback: false }) // 探活：不许回落
    try {
      const r = await fetchOnce(opts)
      status.consecutiveFailures = 0
      failBackoffMs = 60 * 1000
      status.source = r.source
      status.version = r.version
      status.generatedAt = r.analysis.generatedAt
      status.lastSuccessAt = new Date().toISOString()
      status.cycles++
      if (forceProbe) log(`moligod 探活成功，切回分钟级节奏`)
      forceProbe = false
      broadcast('market', { version: r.version, source: r.source, generatedAt: r.analysis.generatedAt })
      log(
        `[${r.source}] version ${r.version} · 买入 ${r.analysis.stats.buy} / 卖出 ${r.analysis.stats.sell} / 关注 ${r.analysis.stats.watch}` +
          (r.changed ? '' : '（内容未变，心跳）')
      )
      // 去抖 state 无论如何逐轮记录（静默期也推进冷却/切换确认）——否则静默跑
      // ≥6h 后恢复通知时，全部现存信号冷却到期会一次性爆发；仅发送受 --no-notify 控制
      const { buys, sells } = judgeSignals(state, r.analysis.items)
      if (!noNotify) await sendNotifications(buys, sells, notify)
      await saveState()
    } catch (e) {
      status.consecutiveFailures++
      if (forceProbe) {
        forceProbe = false
        log(`moligod 探活仍失败，维持 kkrb 兜底节奏：${e.message}`)
      } else {
        console.error(`[${new Date().toLocaleString('zh-CN')}] 抓取失败（退避 ${Math.round(failBackoffMs / 1000)}s）：${e.message}`)
      }
    }
  }

  /** fast 节奏：moligod 正常 60s±5s；kkrb 兜底 10min（每 3 轮探活）；失败指数退避 */
  function nextFastDelay() {
    if (status.consecutiveFailures > 0) return Math.min(failBackoffMs, 10 * 60 * 1000)
    if (status.source === 'kkrb') {
      servedByKkrbRounds++
      if (servedByKkrbRounds % PROBE_EVERY === 0) forceProbe = true
      return KKRBCADENCE_MS
    }
    return fastMs + (Math.random() * 10000 - 5000) // ±5s 抖动
  }

  async function fastLoop() {
    if (closing) return
    await cycle('fast')
    if (closing) return
    const delay = nextFastDelay()
    if (status.consecutiveFailures > 0) failBackoffMs = Math.min(failBackoffMs * 2, 10 * 60 * 1000)
    fastTimer = setTimeout(fastLoop, delay)
  }

  async function slowLoop() {
    if (closing) return
    await cycle('auto') // 只补过期/缺失曲线；曲线失败沿旧数据，不写坏
    if (closing) return
    slowTimer = setTimeout(slowLoop, slowMs)
  }

  async function saveState() {
    try {
      // 原子写（与 monitor.mjs 共用本文件），裸 writeFile 可能留下半截 state
      await writeJsonAtomic(statePath, JSON.stringify(state))
    } catch {
      /* 状态写失败不影响行情链路 */
    }
  }

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host || '127.0.0.1'}`)
    if (url.pathname === '/events') {
      res.writeHead(200, {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
        'Access-Control-Allow-Origin': '*',
      })
      // 连接即发 hello：携带当前盘上快照的元信息（页面据此标记实时通道已连接）
      res.write(`event: hello\ndata: ${JSON.stringify({
        version: status.version,
        source: status.source,
        generatedAt: status.generatedAt,
      })}\n\n`)
      clients.add(res)
      req.on('close', () => clients.delete(res))
      return
    }
    if (url.pathname === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*' })
      res.end(JSON.stringify({ ok: true, ...status }))
      return
    }
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end('not found')
  })

  /** 启动序列：读盘初始化状态与 hello 元信息 → 预热曲线 → full 冷启动 → 双循环 */
  async function start() {
    const marketPath = path.join(rootDir, 'public', 'ammo', 'market.json')
    if (existsSync(marketPath)) {
      try {
        const prev = JSON.parse(await readFile(marketPath, 'utf8'))
        status.version = prev.version
        status.source = prev.source || null
        status.generatedAt = prev.generatedAt
        primeCurveCache(prev.items) // 重启不丢曲线；kkrb 旧快照名对不上的由 full 冷启动补
      } catch {
        /* 损坏快照忽略，冷启动重建 */
      }
    }
    state = await loadState(statePath)
    // 冷启动按缓存状态选模式（auto）：预热命中（market.json 为 moligod 快照且
    // 名字对得上）时只打 1 次 catalog；预热覆盖率低（kkrb 旧快照名对不上 / 曲线
    // 已过期 30min）时自动补齐缺失曲线，等效 full——不会把过期缓存当新数据，
    // 也不会产出全「数据不足」的快照
    await cycle('auto')
    fastTimer = setTimeout(fastLoop, nextFastDelay())
    slowTimer = setTimeout(slowLoop, slowMs)
    hbTimer = setInterval(() => {
      for (const res of clients) {
        try {
          res.write(': ping\n\n') // SSE 注释心跳，防中间代理掐空闲连接
        } catch {
          clients.delete(res)
        }
      }
    }, 25 * 1000)
  }

  async function close() {
    closing = true
    clearTimeout(fastTimer)
    clearTimeout(slowTimer)
    clearInterval(hbTimer)
    for (const res of clients) {
      try {
        res.end()
      } catch {}
    }
    clients.clear()
    await new Promise((resolve) => server.close(resolve))
  }

  return { server, triggerCycle: cycle, status, start, close }
}

// ---- CLI 直跑 ----
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2)
  const port = (() => {
    const i = argv.indexOf('--port')
    return i >= 0 && argv[i + 1] ? Number(argv[i + 1]) : 8787
  })()
  const live = createLiveServer({
    noNotify: argv.includes('--no-notify'),
    noDist: argv.includes('--no-dist'),
  })
  live.server.listen(port, '127.0.0.1', () => {
    log(`live 服务已启动：SSE http://127.0.0.1:${port}/events · health /health（Ctrl+C 退出）`)
  })
  await live.start()
  process.on('SIGINT', () => {
    log('收到 SIGINT，关闭 live 服务')
    live.close().then(() => process.exit(0))
  })
}
