/* ============================================================
   liveChannel.js — 实时通道（SSE）端点判定（子弹页 / 雷达页 / 制造页共用）
   ------------------------------------------------------------
   本地 vite 工具链端口（dev 5173–5199 / preview 4173，含冲突顺延）→ 独立
   live 服务 http://127.0.0.1:8787/events（npm run ammo:live，vite 与
   live 服务分进程，跨端口靠 ACAO:*）；其余 http(s)——**包括 localhost
   上的 server.mjs 自托管部署**（serve 默认 8080 / 自定义端口，同源
   /events 与 /health 本就可用）——一律同源 /events（无 CORS /
   mixed-content）；file:// 等无 origin 场景返回 null。判定必须带端口：
   只看 protocol+hostname 会把 localhost:8789 这类部署形态误判成本地
   dev，永远探测 8787 既拿不到同源 SSE 又在控制台刷连接拒绝。
   marketMeta.js 从这里再导出（子弹页与离线自测的既有入口不变）。
   ============================================================ */

/** 独立 live 服务端点（dev 形态直连与部署形态的兜底探测共用一处定义） */
const LOCAL_LIVE_EVENTS = 'http://127.0.0.1:8787/events'

/** 本地 vite 工具链端口：dev 默认 5173、preview 默认 4173。dev 端口被占时
    vite 会自动顺延且无上限（项目未设 strictPort，vite 7 的 EADDRINUSE 处理
    就是 ++port 重听），按段 5173–5199 识别——留出约 27 个并发 dev 实例的
    余量；再往后的顺延端口按部署形态走同源，由 createLiveChannel 探测期的
    8787 兜底接住。只有这些端口上的页面没有同源 /events（vite 只托管页面
    本身），才需要跨端口连 8787；localhost 其余端口按自托管部署走同源。 */
function isLocalDevPort(port) {
  const n = Number(port)
  return port === '4173' || (n >= 5173 && n <= 5199)
}

/** 取有效端口：优先 location.port，缺失时从 origin 解析（自测桩只给 origin） */
function portOf(loc) {
  if (loc.port) return loc.port
  try { return new URL(loc.origin).port || '' } catch { return '' }
}

/** URL 字符串 → location 形状（{protocol, hostname, ...}；解析失败给空对象，按非本机处理） */
function parseUrl(u) {
  try { return new URL(u) } catch { return {} }
}

/** 本机 http 形态（只看协议 + 主机名，不限端口）：isLocalHttpHost 的判定
    基础，也是 createLiveChannel 兜底探测的适用圈——公网页面不去探访客的
    127.0.0.1（对它无意义，还形似端口扫描） */
function isLocalHost({ protocol, hostname } = {}) {
  return (
    protocol === 'http:' &&
    (hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '[::1]' || hostname === '::1')
  )
}

/** 判定是否本地 vite 开发环境（页面与本地 live 服务分进程的形态：本机 + vite 工具链端口） */
export function isLocalHttpHost(loc = {}) {
  return isLocalHost(loc) && isLocalDevPort(portOf(loc))
}

/** 实时通道（SSE）端点；本环境没有可用通道时返回 null */
export function liveChannelUrl(loc = {}) {
  if (isLocalHttpHost(loc)) return LOCAL_LIVE_EVENTS
  const { protocol, origin } = loc
  if ((protocol === 'http:' || protocol === 'https:') && origin && origin !== 'null') {
    return `${origin}/events`
  }
  return null
}

/* ---------- SSE 带退避重连助手（子弹页 / 雷达页 / 制造页共用） ----------
   纯 JS 无框架依赖：状态与事件经回调上抛，页面用自己的响应式承接，
   Node 后端 / iOS 只用上面的端点判定时，本段代码不会执行任何浏览器 API。
   生命周期：start() → 探测 /health（4s 超时）→ 连 /events → hello 即 on；
   连上后断开（error）不再永久放弃，改带退避重探 /health（30s 起步、
   翻倍封顶 2min），服务端部署重启 / 闪断后自动回到实时推送。
   /health 按「应答 application/json」判定真伪：vite dev / preview 的 SPA
   回退会给未知路径回 200 html，只看状态码会把「health 200 → /events
   404」的空转当健康。传入端点探不到真 /health 时，本机 http 页面再兜底
   探一次独立 live 服务 8787——vite 端口顺延出识别段（或 --port 自定义）
   被按部署形态处理时，靠它找回分进程的 live 服务；每轮探测都从传入端点
   重新起，后起的同源部署（server.mjs 起在同端口）下一轮自然回归同源。
   首探失败按环境分流：本地判 down 并重试（人可能稍后开 live）；非本地
   且从未连上过判 off 不再重试（纯静态托管没有服务端，不打无效流量）——
   连上过之后再断则一律 down + 重探：那是部署重启，不是环境不适用。 */

/**
 * 建一条受控实时通道。
 * @param {object} opts
 * @param {string}   opts.url            SSE 端点（liveChannelUrl 的返回值）
 * @param {string[]} [opts.events]       需要透传给 onEvent 的具名事件（market / radar / craft）
 * @param {() => boolean} [opts.isLocal] 本地开发判定（首探失败时 down 可恢复 / off 不重试）
 * @param {(s: string) => void} opts.onState   connecting | on | down | off
 * @param {(t: string, d?: string) => void} opts.onEvent  事件名 + 原始 data（hello 含版本 JSON）
 * @returns {{ start(): void, stop(): void }}
 */
export function createLiveChannel({
  url,
  events = [],
  isLocal = () => false,
  onState = () => {},
  onEvent = () => {},
  firstRetryMs = 30 * 1000,
  maxRetryMs = 2 * 60 * 1000,
  healthTimeoutMs = 4000,
} = {}) {
  let es = null
  let retryTimer = null
  let retryMs = firstRetryMs
  let everOn = false // 连上过：之后的断开一律按「部署重启」重探，不再判环境不适用
  let stopped = true
  let probeCtl = null
  let activeUrl = url // 本轮探测选中的 /events 端点（传入端点优先，可切 8787 兜底）

  const setState = (s) => { if (!stopped) onState(s) }

  function scheduleRetry() {
    if (stopped || retryTimer) return
    const delay = retryMs
    retryMs = Math.min(retryMs * 2, maxRetryMs)
    retryTimer = setTimeout(() => { retryTimer = null; probe() }, delay)
  }

  /** 真 /health 一律 application/json（live.mjs 独立跑与 server.mjs 同源
      部署是同一处理器）；vite 的 SPA 回退会给未知路径回 200 html，只看
      r.ok 会把「/health 200 → /events 404」的空转当健康 */
  const isLiveHealthResponse = (r) =>
    r.ok && (r.headers.get('content-type') || '').includes('application/json')

  async function probe() {
    if (stopped) return
    setState('connecting')
    probeCtl = new AbortController()
    const timer = setTimeout(() => probeCtl.abort(), healthTimeoutMs)
    // 候选端点：传入端点优先（部署形态即同源）；本机 http 页面补一个独立
    // live 服务兜底，依次探 /health，第一个应答真 health 的作为本轮端点。
    const candidates = [url]
    if (url !== LOCAL_LIVE_EVENTS && isLocalHost(parseUrl(url))) candidates.push(LOCAL_LIVE_EVENTS)
    activeUrl = null
    for (const c of candidates) {
      try {
        const r = await fetch(String(c).replace(/\/events$/, '/health'), { signal: probeCtl.signal })
        if (isLiveHealthResponse(r)) { activeUrl = c; break }
      } catch { /* 探测失败或已中止：换下一个候选 */ }
    }
    clearTimeout(timer)
    if (stopped) return
    if (activeUrl) {
      retryMs = firstRetryMs // 服务端应答了，退避复位
      open()
      return
    }
    if (!everOn && !isLocal()) { setState('off'); return }
    setState('down')
    scheduleRetry()
  }

  function open() {
    if (stopped) return
    es = new EventSource(activeUrl)
    es.addEventListener('hello', (e) => {
      everOn = true
      setState('on')
      onEvent('hello', e.data)
    })
    for (const t of events) {
      es.addEventListener(t, (e) => onEvent(t, e.data))
    }
    es.addEventListener('error', () => {
      // 明确放弃 EventSource 自带的无限盲连，改走受控 /health 重探
      try { es && es.close() } catch { /* 已关闭 */ }
      es = null
      setState('down')
      scheduleRetry()
    })
  }

  return {
    start() {
      if (!stopped || !url) return
      stopped = false
      probe()
    },
    stop() {
      stopped = true
      if (retryTimer) { clearTimeout(retryTimer); retryTimer = null }
      if (probeCtl) { try { probeCtl.abort() } catch { /* 已结束 */ } probeCtl = null }
      if (es) { try { es.close() } catch { /* 已关闭 */ } es = null }
    },
  }
}
