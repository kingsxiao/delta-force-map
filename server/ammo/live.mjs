/* ============================================================
   live.mjs — 本地子弹行情 live 服务（node:http 零依赖，吸收 monitor 职责）
   ------------------------------------------------------------
   与 npm run dev 同跑时，页面端到端延迟 = 源分钟粒度 + 60s 快轮询 + SSE ≤5s。
   · fast loop：每 60s（±5s 抖动，对齐 catalog ttl_seconds=60）fetchOnce
     ({mode:'fast'})——每轮只打 1 次 catalog，曲线全部吃模块缓存（≈59 次/小时）
   · slow loop：每 30min fetchOnce({mode:'auto'})——补抓过期（≥30min TTL）/
     缺失的曲线；计时在本轮完成后重启，稳态下轮曲线必已过期，等效每 ≈31min
     全量刷 67 条（+1 catalog ≈132 次/小时；两环合计 ≈190 次/小时）
   · 启动：从现有 apps/web/public/ammo/market.json 预热曲线缓存（重启不丢
     曲线），冷启动一轮按缓存状态选模式（auto：预热命中只打 1 次 catalog；
     覆盖率低/曲线过期则自动补齐，等效 full），再进 fast loop
   · SSE（http://127.0.0.1:8787/events，仅绑回环地址，ACAO:*）：
     连接即发命名事件 event:hello（{version,source,generatedAt}），每次落盘
     广播 event:market（轻量 ping，页面收到后自拉 market.json——复用既有
     数据路径，SSE 只做「该刷新了」的信号）；每 25s 发注释心跳防代理断连
   · /health：{source, lastSuccessAt, consecutiveFailures, ...}
   · 兜底节奏：fetchOnce 内部 moligod→kkrb 自动回落；live 按实际服务源调
     节奏（kkrb 时降 10min，每 3 轮探活一次 moligod 切回）；两源全挂时
     指数退避（1min 起、×2、cap 10min），成功即复位
   · 通知：复用 notify-policy（streak 去抖），与 monitor.mjs 共用 state 文件
   · dist 联动：fetchOnce 检测 apps/web/dist/ammo 存在时同步写（--no-dist
     关闭），vite preview 下页面同样拿到新数据
   用法：node server/ammo/live.mjs [--port 8787] [--no-notify] [--no-dist]
   注意：live / monitor / 手动 ammo:fetch 同为写盘者，同时只跑一个。
   ============================================================ */
import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import http from 'node:http'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { fetchOnce, writeJsonAtomic } from './fetch-once.mjs'
import { primeCurveCache } from './moligod-client.mjs'
import { judgeSignals, sendNotifications, emptyState } from '../../shared/js/notify-policy.js'
import { notify } from './notify.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
/** 网页端目录（多端 monorepo；rootDir 留作 data/ 状态与留档的仓库根） */
const WEB_DIR = path.join(ROOT, 'apps', 'web')
const DEFAULT_STATE_PATH = path.join(ROOT, 'data', 'ammo', 'monitor-state.json')
const KKRBCADENCE_MS = 10 * 60 * 1000 // 兜底源为小时档数据，10min 轮询足够
const PROBE_EVERY = 3 // 每 3 轮 kkrb 服务，探活一次 moligod
/** SSE 连接上限：/events 无鉴权且 ACAO:*，任意第三方网页可让访客浏览器批量开
 *  EventSource——全局 + 单 IP 双上限防 FD/内存耗尽单进程（超限 503，页面自动
 *  退回轮询兜底） */
const MAX_SSE_CLIENTS = 100
const MAX_SSE_PER_IP = 15
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
 * @param {{noNotify?:boolean, noDist?:boolean, rootDir?:string, webDir?:string,
 *          statePath?:string, fastMs?:number, slowMs?:number,
 *          trustProxyHops?:number}} opts
 *   rootDir 仓库根（state 默认挂 data/ammo）；webDir 网页端目录（public/dist
 *   写入与预热读取，默认 = rootDir，selftest 注入临时目录即原行为）；
 *   trustProxyHops 反代信任跳数（/events 单 IP 计数从右数第 N 跳，
 *   单层 nginx = 1 = 末段；多级反代由 server.mjs --trust-proxy=N 传入）
 * @returns {{server:http.Server, triggerCycle:Function, status:object, close:Function}}
 */
export function createLiveServer({
  noNotify = false,
  noDist = false,
  rootDir = ROOT,
  webDir = rootDir,
  statePath = DEFAULT_STATE_PATH,
  fastMs = 60 * 1000,
  slowMs = 30 * 60 * 1000,
  trustProxyHops = 1,
} = {}) {
  const clients = new Set()
  /** 单 IP 并发 SSE 计数（key 口径见 /events handler） */
  const ipCounts = new Map()
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

  /** SSE 单连接写：write 返回 false（写缓冲已满 = 慢读客户端）即掐断该连接。
   *  广播/心跳对每个连接无脑 res.write、不管返回值的话，恶意慢读会让数据在
   *  Node 写缓冲无限堆积直至 OOM；掐断后浏览器 EventSource 自动重连（超限
   *  则收到 503 退回轮询） */
  function sseWrite(res, chunk) {
    try {
      if (!res.write(chunk)) {
        clients.delete(res)
        res.destroy()
        return false
      }
      return true
    } catch {
      clients.delete(res)
      // 与 write 返回 false 分支同口径：显式掐断。write 同步抛通常意味着流已
      // 坏，不 destroy 的话半坏连接要等 TCP 层超时才回收（req close 不触发，
      // ipCounts 也不递减）
      try {
        res.destroy()
      } catch {}
      return false
    }
  }

  function broadcast(event, payload) {
    const frame = `event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`
    for (const res of clients) sseWrite(res, frame)
  }

  async function cycle(mode) {
    const opts = { mode, fallback: true, syncDist: !noDist, rootDir, webDir }
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
    let url
    try {
      url = new URL(req.url, `http://${req.headers.host || '127.0.0.1'}`)
    } catch {
      // 畸形 Host 头（如 'a b'）会让 new URL 同步抛 ERR_INVALID_URL；Node
      // http 不捕获 request listener 的同步异常，CLI 直跑形态会打死进程
      res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end('bad request')
      return
    }
    if (url.pathname === '/events') {
      // 单 IP 计数口径：nginx 反代形态下所有直连地址都是回环，仅对回环连接
      // 采信 XFF 从右数第 trustProxyHops 跳（$proxy_add_x_forwarded_for 追加
      // 的真实对端；单层反代 = 1 = 末段，多级链由 server.mjs --trust-proxy=N
      // 传入跳数，否则末段恒为上级代理 IP，全站共享单 IP 上限）；外部地址
      // 一律按 socket 地址计——外部伪造 XFF 无从入口（非回环不吃 XFF）
      const raw = req.socket?.remoteAddress || 'unknown'
      const loopback = raw === '127.0.0.1' || raw === '::1' || raw === '::ffff:127.0.0.1'
      const parts = String(req.headers['x-forwarded-for'] || '')
        .split(',').map((s) => s.trim()).filter(Boolean)
      // 跳数多于 XFF 段数 = 链路与配置不符，退回 socket 地址（同 api.mjs clientIp）
      const ipKey = loopback && parts.length >= trustProxyHops ? parts[parts.length - trustProxyHops] : raw
      if (clients.size >= MAX_SSE_CLIENTS || (ipCounts.get(ipKey) || 0) >= MAX_SSE_PER_IP) {
        res.writeHead(503, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' })
        res.end('too many sse connections')
        return
      }
      res.writeHead(200, {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
        'Access-Control-Allow-Origin': '*',
        // nginx 反代部署（阿里云等）防 SSE 被代理缓冲掐成慢轮询
        'X-Accel-Buffering': 'no',
      })
      clients.add(res)
      ipCounts.set(ipKey, (ipCounts.get(ipKey) || 0) + 1)
      req.on('close', () => {
        clients.delete(res)
        const n = (ipCounts.get(ipKey) || 1) - 1
        if (n <= 0) ipCounts.delete(ipKey)
        else ipCounts.set(ipKey, n)
      })
      // 连接即发 hello：携带当前盘上快照的元信息（页面据此标记实时通道已连接）
      sseWrite(res, `event: hello\ndata: ${JSON.stringify({
        version: status.version,
        source: status.source,
        generatedAt: status.generatedAt,
      })}\n\n`)
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
    const marketPath = path.join(webDir, 'public', 'ammo', 'market.json')
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
      for (const res of clients) sseWrite(res, ': ping\n\n') // SSE 注释心跳，防中间代理掐空闲连接
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
    ipCounts.clear()
    await new Promise((resolve) => server.close(resolve))
  }

  return { server, triggerCycle: cycle, status, start, close, broadcast }
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
    webDir: WEB_DIR,
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
