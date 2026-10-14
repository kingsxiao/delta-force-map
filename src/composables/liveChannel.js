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
