/* ============================================================
   analyze.mjs — 子弹行情买卖点分析（纯函数，脚本与前端共用口径）
   ------------------------------------------------------------
   策略：7 天小时级价格曲线的分位数回归（均值回归思路）
     · rank = 当前价在近 7 天曲线中的分位（0~1，越低越便宜）
     · 买入 BUY  ：rank ≤ 0.25（贴近 7 天低位）
     · 关注 WATCH：rank ≤ 0.35（接近低位，可挂限价）
     · 卖出 SELL ：rank ≥ 0.80（贴近 7 天高位，持仓者该出货）
     · 其余 WAIT ：观望
   利润口径（用户要的"能赚多少"）：
     · 税率按上游 AfterTax/Price 实测反推（约 15%，逐弹计算）
     · 目标挂单价 = 7 天 P75（可达成性高）；到手价 = 挂单价 × (1−税率)
     · 每发利润 = 到手价 − 当前买入价；收益率 = 利润 / 当前价
     · 买入信号要求利润 > 0 且收益率 ≥ 8%（税覆盖不掉的不报）
   ============================================================ */

/** 升序数组的线性插值分位（p ∈ [0,1]） */
function quantile(sorted, p) {
  if (!sorted.length) return null
  const pos = (sorted.length - 1) * p
  const lo = Math.floor(pos)
  const hi = Math.ceil(pos)
  if (lo === hi) return sorted[lo]
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo)
}

/** 当前价在历史序列中的分位（0=最低 1=最高） */
function percentileRank(values, current) {
  if (!values.length) return null
  let below = 0
  for (const v of values) if (v <= current) below++
  return below / values.length
}

/**
 * 分析单种子弹。
 * @param raw getAmmoPLData 的一个 item
 * @returns 分析结果对象（signal 为 WAIT 且 rank 为 null 表示数据不足）
 */
export function analyzeItem(raw) {
  const name = raw.itemName
  // priceCurve: {"202610061100": 755, ...} → 按时间键升序的 [ts, price]
  const curveEntries = Object.entries(raw.priceCurve || {})
    .map(([ts, p]) => [ts, Number(p)])
    .filter(([, p]) => Number.isFinite(p) && p > 0)
    .sort(([a], [b]) => (a < b ? -1 : 1))

  const prices = curveEntries.map(([, p]) => p)
  const current = Number.isFinite(Number(raw.currectPrice)) && raw.currectPrice > 0
    ? Number(raw.currectPrice)
    : (prices[prices.length - 1] ?? null)

  // 税率：本周最高价的税前/税后一对反推；缺数据时退回 15%（常见档）
  let taxRate = 0.15
  const wk = Number(raw.thisWeekHighestPrice)
  const wkAfter = Number(raw.thisWeekHighestPriceAfterTax)
  if (wk > 0 && wkAfter > 0) {
    const t = 1 - wkAfter / wk
    if (t > 0 && t < 0.5) taxRate = t
  }

  const base = {
    name,
    grade: raw.grade ?? null,
    pic: raw.pic || null,
    current,
    taxRate,
    curve: curveEntries, // [["202610061100", 755], ...] 前端直接画线
  }
  if (!current || prices.length < 24) return { ...base, rank: null, signal: 'WAIT', reason: '数据不足' }

  const sorted = [...prices].sort((a, b) => a - b)
  const p10 = quantile(sorted, 0.1)
  const p25 = quantile(sorted, 0.25)
  const p50 = quantile(sorted, 0.5)
  const p75 = quantile(sorted, 0.75)
  const p90 = quantile(sorted, 0.9)
  const rank = percentileRank(prices, current)
  const weekHigh = sorted[sorted.length - 1]
  const weekLow = sorted[0]

  // 目标卖出：P75（常规）与 7 天最高（乐观）；到手按税率折算
  const targetSell = p75
  const netSell = targetSell * (1 - taxRate)
  const netHigh = weekHigh * (1 - taxRate)
  const profitPerRound = netSell - current
  const profitPct = current > 0 ? profitPerRound / current : 0

  let signal = 'WAIT'
  if (rank >= 0.8) signal = 'SELL'
  else if (rank <= 0.25 && profitPerRound > 0 && profitPct >= 0.08) signal = 'BUY'
  else if (rank <= 0.35) signal = 'WATCH'

  return {
    ...base,
    rank,
    p10, p25, p50, p75, p90,
    weekHigh, weekLow,
    targetSell,
    netSell,      // P75 到手
    netHigh,      // 7 天最高到手（乐观目标）
    profitPerRound,
    profitPct,
    signal,
  }
}

/** 信号中文说明（通知与页面共用文案口径） */
export const SIGNAL_META = {
  BUY: { label: '买入', tone: 'good', hint: '贴近7天低位，税后仍有利润空间' },
  WATCH: { label: '关注', tone: 'warn', hint: '接近低位，可挂限价单等待' },
  SELL: { label: '卖出', tone: 'hot', hint: '贴近7天高位，持仓建议出货' },
  WAIT: { label: '观望', tone: 'dim', hint: '价格处于中位区间，不动手' },
}

/**
 * 分析整个市场快照。
 * @returns {{version:string, fetchedAt:string, generatedAt:string, items:Array,
 *            signals:{buy:Array, sell:Array, watch:Array}, stats:object}}
 */
export function analyzeMarket(snapshot) {
  const items = (snapshot.data || []).map(analyzeItem)
  const by = (s) =>
    items
      .filter((i) => i.signal === s)
      .sort((a, b) => (b.profitPct || 0) - (a.profitPct || 0))
  return {
    version: snapshot.version,
    fetchedAt: snapshot.fetchedAt,
    generatedAt: new Date().toISOString(),
    items,
    signals: { buy: by('BUY'), sell: by('SELL'), watch: by('WATCH') },
    stats: {
      total: items.length,
      buy: by('BUY').length,
      sell: by('SELL').length,
      watch: by('WATCH').length,
    },
  }
}

/** 价格格式化：整数（哈夫币/发） */
export const fmtPrice = (n) =>
  Number.isFinite(n) ? Math.round(n).toLocaleString('zh-CN') : '—'
/** 收益率格式化：+27.6% */
export const fmtPct = (n) =>
  Number.isFinite(n) ? `${n >= 0 ? '+' : ''}${(n * 100).toFixed(1)}%` : '—'
