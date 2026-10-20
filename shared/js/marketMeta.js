/* ============================================================
   marketMeta.js — 子弹行情页的纯函数元信息（组件与离线自测共用）
   ------------------------------------------------------------
   版本双格式：主源 moligod 为 12 位分钟档（YYYYMMDDHHmm），兜底 kkrb 为
   10 位小时档（YYYYMMDDHH）——页面按长度分流显示，不自造分钟。
   时效阈值按 source 分档：分钟级源的新鲜度承诺 tighter，小时级源沿用
   原阈值。实时通道端点在 liveChannelUrl：本地 http 开发连独立 live 服务
   （8787），其余 http(s) 连同源 /events（server.mjs 部署）——页面先探测
   /health 再连，探测不到按环境分流（gate 规则也在这里，供 selftest 断言）。
   ============================================================ */

/** 数据版本号 → 展示串：12 位 "YYYY-MM-DD HH:mm"，10 位 "YYYY-MM-DD HH:00" */
export function formatVersionLabel(v) {
  if (!v) return '—'
  if (v.length >= 12) {
    return `${v.slice(0, 4)}-${v.slice(4, 6)}-${v.slice(6, 8)} ${v.slice(8, 10)}:${v.slice(10, 12)}`
  }
  return `${v.slice(0, 4)}-${v.slice(4, 6)}-${v.slice(6, 8)} ${v.slice(8, 10)}:00`
}

/**
 * 数据时效阈值（分钟）：moligod 分钟级——live 点 10min 变灰、30min 出过期
 * 提示；kkrb 小时级兜底——沿用原 60min / 360min。
 */
export function staleness(source) {
  return source === 'moligod'
    ? { staleDotMin: 10, staleTipMin: 30 }
    : { staleDotMin: 60, staleTipMin: 360 }
}

/** 页头/METHOD 的来源文案（按 market.json 顶层 source 动态） */
export function sourceLabel(source) {
  return source === 'moligod'
    ? '三角洲攻略站 moligod（分钟级）'
    : source === 'kkrb'
      ? 'KK三角洲一图流 kkrb.net（约每小时，兜底）'
      : '未知来源'
}

export function methodDataLine(source) {
  return source === 'moligod'
    ? '三角洲攻略站 moligod.com 交易行口径，分钟级更新；趋势为近 7 天每小时价格。'
    : 'KK三角洲一图流（kkrb.net）交易行口径，约每小时更新一次；趋势为近 7 天每小时均价。'
}

/** 实时通道端点判定（本地 8787 / 同源 /events / file 不可用）——实现在
 *  共享模块 src/composables/liveChannel.js（子弹页 / 雷达页共用），此处再导出 */
export { isLocalHttpHost, liveChannelUrl } from '../../composables/liveChannel.js'

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

/** 过期提示文案：分钟级源如实注明「静态快照，不开 live 不自动更新」 */
export function staleTipText(source, ageMin) {
  const age = fmtAge(ageMin)
  if (source === 'moligod') {
    return `数据已 ${age} 未更新（静态快照，未运行 live 服务时不会自动更新），价格可能已变化，可点『刷新数据』重试`
  }
  return `数据已 ${age} 未更新，价格可能已变化，可点『刷新数据』重试`
}
