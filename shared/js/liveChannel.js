/* ============================================================
   liveChannel.js — 实时通道（SSE）端点判定（子弹页 / 雷达页共用）
   ------------------------------------------------------------
   本地 http 开发 → 独立 live 服务 http://127.0.0.1:8787/events
   （npm run ammo:live，vite 5173 与 live 服务分进程，跨端口靠 ACAO:*）；
   其余 http(s) → 同源 /events（scripts/server.mjs 部署形态，同源无
   CORS / mixed-content）；file:// 等无 origin 场景返回 null。
   marketMeta.js 从这里再导出（子弹页与离线自测的既有入口不变）。
   ============================================================ */

/** 判定是否本地 http 开发环境（vite dev 页面与本地 live 服务分进程的形态） */
export function isLocalHttpHost({ protocol, hostname } = {}) {
  return (
    protocol === 'http:' &&
    (hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '[::1]' || hostname === '::1')
  )
}

/** 实时通道（SSE）端点；本环境没有可用通道时返回 null */
export function liveChannelUrl(loc = {}) {
  if (isLocalHttpHost(loc)) return 'http://127.0.0.1:8787/events'
  const { protocol, origin } = loc
  if ((protocol === 'http:' || protocol === 'https:') && origin && origin !== 'null') {
    return `${origin}/events`
  }
  return null
}

/* ---------- SSE 带退避重连助手（子弹页 / 雷达页共用） ----------
   纯 JS 无框架依赖：状态与事件经回调上抛，页面用自己的响应式承接，
   Node 后端 / iOS 只用上面的端点判定时，本段代码不会执行任何浏览器 API。
   生命周期：start() → 探测 /health（4s 超时）→ 连 /events → hello 即 on；
   连上后断开（error）不再永久放弃，改带退避重探 /health（30s 起步、
   翻倍封顶 2min），服务端部署重启 / 闪断后自动回到实时推送。
   首探失败按环境分流：本地判 down 并重试（人可能稍后开 live）；非本地
   且从未连上过判 off 不再重试（纯静态托管没有服务端，不打无效流量）——
   连上过之后再断则一律 down + 重探：那是部署重启，不是环境不适用。 */

/**
 * 建一条受控实时通道。
 * @param {object} opts
 * @param {string}   opts.url            SSE 端点（liveChannelUrl 的返回值）
 * @param {string[]} [opts.events]       需要透传给 onEvent 的具名事件（market / radar）
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

  const setState = (s) => { if (!stopped) onState(s) }

  function scheduleRetry() {
    if (stopped || retryTimer) return
    const delay = retryMs
    retryMs = Math.min(retryMs * 2, maxRetryMs)
    retryTimer = setTimeout(() => { retryTimer = null; probe() }, delay)
  }

  function probe() {
    if (stopped) return
    setState('connecting')
    probeCtl = new AbortController()
    const timer = setTimeout(() => probeCtl.abort(), healthTimeoutMs)
    fetch(String(url).replace(/\/events$/, '/health'), { signal: probeCtl.signal })
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`)
        clearTimeout(timer)
        retryMs = firstRetryMs // 服务端应答了，退避复位
        open()
      })
      .catch(() => {
        clearTimeout(timer)
        if (stopped) return
        if (!everOn && !isLocal()) { setState('off'); return }
        setState('down')
        scheduleRetry()
      })
  }

  function open() {
    if (stopped) return
    es = new EventSource(url)
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
