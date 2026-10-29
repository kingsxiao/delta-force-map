/* ============================================================
   etaLine.js — 「预计卖出」脚注文案（全表展开行 / 详情页共用）
   ------------------------------------------------------------
   买入/关注：历史到达历时（中位/最快）+ 日内高位时段；卖出：已在挂卖区，
   只给「今天几点出」的日内高位建议。统计口径在 @shared/js/sellEta.js
   predictSellEta（近 7 天小时曲线的完整上涨段 + 日内同小时均价），
   这里只做中文文案拼装；数据不足返回 null，调用方不渲染该行。
   ============================================================ */
import { fmt } from '../../utils/format.js'
import { predictSellEta, fmtHours, fmtPeak } from '@shared/js/sellEta.js'

export function etaLine(i) {
  const e = predictSellEta(i)
  if (!e) return null
  const peak = e.peakStart != null ? fmtPeak(e.peakStart, e.peakEnd) : null
  if (e.atTarget) {
    return peak
      ? `现价已处挂卖区，日内高位通常在 ${peak}，建议在该时段分批挂卖。`
      : '现价已处挂卖区，建议尽快挂卖。'
  }
  // 历时展示门槛：至少 2 次完整上涨样本（单样本中位没有置信度）
  if (e.medianH == null || e.episodes < 2) return null
  const clock = e.etaLabel ? `（${e.etaLabel} 前后）` : ''
  const base =
    `按近 7 天 ${e.episodes} 次同类上涨，从现价涨到 ${fmt(i.targetSell)}（近 3 天 75 分位）` +
    `中位约 ${fmtHours(e.medianH)}、最快 ${fmtHours(e.fastestH)}${clock}`
  return peak ? `${base}；该弹种日内高位通常在 ${peak}。` : `${base}。`
}
