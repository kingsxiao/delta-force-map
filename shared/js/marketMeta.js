/* ============================================================
   marketMeta.js — 子弹行情页的纯函数元信息（组件与离线自测共用）
   ------------------------------------------------------------
   版本双格式：主源 moligod 为 12 位分钟档（YYYYMMDDHHmm），兜底 kkrb 为
   10 位小时档（YYYYMMDDHH）——页面按长度分流显示，不自造分钟。
   时效阈值按 source 分档：分钟级源的新鲜度承诺 tighter，小时级源沿用
   原阈值。实时通道端点在 liveChannelUrl：本地 vite 工具链端口（dev
   5173–5199 / preview 4173）连独立 live 服务（8787），其余 http(s)——含
   localhost 上的 server.mjs 部署——连同源 /events——页面先探测 /health
   再连，探测不到按环境分流（gate 规则也在这里，供 selftest 断言）。
   ============================================================ */

/** 数据版本号 → 展示串：12 位 "YYYY-MM-DD HH:mm"，10 位 "YYYY-MM-DD HH:00"；
    不足 10 位的非法短输入原样返回，不产出畸形串（与 iOS MarketMeta.swift 同防御） */
export function formatVersionLabel(v) {
  if (!v) return '—'
  if (v.length < 10) return v
  if (v.length >= 12) {
    return `${v.slice(0, 4)}-${v.slice(4, 6)}-${v.slice(6, 8)} ${v.slice(8, 10)}:${v.slice(10, 12)}`
  }
  return `${v.slice(0, 4)}-${v.slice(4, 6)}-${v.slice(6, 8)} ${v.slice(8, 10)}:00`
}

/**
 * 数据时效阈值（分钟）：moligod 分钟级——live 点 10min 变灰、30min 出过期
 * 提示；kkrb 小时级兜底——沿用原 60min / 360min。moligod-craft（特勤处
 * 制造）同为分钟级源，同档。kkrb-radar+moligod（雷达双源）——90min 变灰 /
 * 240min 过期提示，与 web 雷达页口径对齐（monitor 默认 30min 一轮、榜单约
 * 每小时滚动；此前 iOS 经本函数落入 else 兜底得到 kkrb 的 60/360，两端不一致）。
 */
export function staleness(source) {
  if (source === 'kkrb-radar+moligod') return { staleDotMin: 90, staleTipMin: 240 } // 雷达双源口径（与 iOS MarketMeta.swift 同分支）
  return source === 'moligod' || source === 'moligod-craft'
    ? { staleDotMin: 10, staleTipMin: 30 }
    : { staleDotMin: 60, staleTipMin: 360 }
}

/** 页头/METHOD 的更新粒度文案（按 market.json 顶层 source 动态；不对外提及具体站点） */
export function sourceLabel(source) {
  if (source === 'moligod' || source === 'moligod-craft') return '分钟级'
  if (source === 'kkrb') return '小时级'
  if (source === 'kkrb-radar+moligod') return '双源交叉' // 雷达页双源口径（与 iOS MarketMeta.swift 同分支）
  return '未知粒度'
}

export function methodDataLine(source) {
  return source === 'moligod'
    ? '交易行口径，分钟级更新；趋势为近 7 天每小时价格。'
    : '交易行口径，约每小时更新一次；趋势为近 7 天每小时均价。'
}

/** 实时通道端点判定（本地 8787 / 同源 /events / file 不可用）——实现在
 *  共享模块 shared/js/liveChannel.js（子弹页 / 雷达页 / 后端自测共用），此处再导出 */
export { isLocalHttpHost, liveChannelUrl } from './liveChannel.js'

/** 官方弹药图标 → CDN 缩略图：playerhub 原图最大 1.2MB（整套 7.6MB），
 *  经腾讯云 imageMogr2 按宽缩到展示尺寸（实测 96x ≈ 17KB，74 倍压缩）；
 *  已带查询串的 URL 原样返回，避免重复拼接 */
export function picThumb(pic, w = 96) {
  if (!pic) return ''
  return pic.includes('?') ? pic : `${pic}?imageMogr2/thumbnail/${w}x`
}

/** 数据年龄可读化：<60min 用分钟、<24h 用小时、更长用天（4320min → 「3 天」，
 *  不输出原始分钟数） */
export function fmtAge(ageMin) {
  if (!Number.isFinite(ageMin)) return '—'
  if (ageMin < 60) return `${Math.max(1, Math.round(ageMin))} 分钟`
  if (ageMin < 1440) return `${Math.round(ageMin / 60)} 小时`
  return `${Math.round(ageMin / 1440)} 天`
}

/** 过期提示文案：分钟级源如实注明「当前为历史快照」边界 */
export function staleTipText(source, ageMin) {
  const age = fmtAge(ageMin)
  if (source === 'moligod') {
    return `数据已 ${age} 未更新（当前为历史快照），价格可能已变化，可点『刷新数据』重试`
  }
  return `数据已 ${age} 未更新，价格可能已变化，可点『刷新数据』重试`
}

/**
 * 赛季阶段判定（Playbook「版本与赛季窗口」的倒计时数据源，纯函数）：
 * 赛季窗口套利的口径来自 Playbook 03 静态经验——更新前 3–7 天囤货、
 * 开更后 3 天内出货（全服补弹需求暴增）、赛季末物价波动。阶段：
 *   fresh  开更出货窗（赛季开始 ≤3 天，tone=sell）
 *   hoard  囤货窗（距赛季结束 3–7 天，tone=buy）
 *   late   赛季末（距结束 ≤3 天，tone=warn：物价波动大，按信号操作）
 *   mid    常规期（tone=dim，仅给倒计时）
 * @param {{name:string, start:string, end:string}} season 快照顶层 season（ISO 起止）
 * @param {number} [now] epoch ms，默认当下
 * @returns {{phase:'fresh'|'hoard'|'late'|'mid', label:string, tone:'buy'|'sell'|'warn'|'dim',
 *            daysLeft:number, daysFromStart:number}|null} 无有效赛季 / 起止倒挂 → null
 */
export function seasonPhase(season, now = Date.now()) {
  if (!season || typeof season !== 'object') return null
  const start = Date.parse(season.start)
  const end = Date.parse(season.end)
  if (!Number.isFinite(start) || !Number.isFinite(end) || start >= end) return null
  const DAY = 86400000
  const daysLeft = (end - now) / DAY
  const daysFromStart = (now - start) / DAY
  if (daysFromStart < 0) return { phase: 'mid', label: '赛季未开始', tone: 'dim', daysLeft, daysFromStart }
  if (daysFromStart <= 3) {
    return { phase: 'fresh', label: '开更出货窗（新赛季 +3 天内，补弹需求高峰）', tone: 'sell', daysLeft, daysFromStart }
  }
  if (daysLeft <= 0) return { phase: 'late', label: '赛季已到点（待新赛季数据刷新）', tone: 'warn', daysLeft, daysFromStart }
  if (daysLeft <= 3) {
    return { phase: 'late', label: '赛季末（T−3 内，物价波动大）', tone: 'warn', daysLeft, daysFromStart }
  }
  if (daysLeft <= 7) {
    return { phase: 'hoard', label: '囤货窗（T−7~T−3：新赛季前囤热门口径）', tone: 'buy', daysLeft, daysFromStart }
  }
  return { phase: 'mid', label: '常规期', tone: 'dim', daysLeft, daysFromStart }
}
