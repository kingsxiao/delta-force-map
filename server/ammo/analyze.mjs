/* ============================================================
   analyze.mjs — 子弹行情买卖点分析（纯函数，脚本与前端共用口径）
   ------------------------------------------------------------
   策略 v2（2026-10-26 回测定稿，方法与数据见 server/ammo/backtest.mjs）：
   21 天真实小时曲线 walk-forward 回测，旧口径（rank≤0.25 对 7 天 P75
   挂卖、无趋势过滤）284 笔 / 31% 胜率 / 单笔均 −6.6%——慢性阴跌里
   「贴 7 天低位」恒真而 7 天 P75 是跌前体制的幻影目标，信号专挑接飞刀。
   税负数学决定纪律：15% 税下止损 −5% 价差即净亏 −19.3%，止盈必须
   吃到 ≥ +17.6% 价差才回本——亏一笔要两笔赢单填，入场质量是全部。
   新口径（14 笔 / 79% 胜率 / 单笔均 +9.6%，严选参数 10 笔 / 90%）：
     买入 BUY（全部满足，缺一降级 WATCH）：
       · rank ≤ 0.20（现价处 7 天曲线下 1/5，较旧 0.25 更深一档）
       · 目标挂卖价 = 近 72h P75（体制内目标）：税后净利 ≥ 10%
       · 曲线 ≥ 48 点（≥2 天样本；不足 24 点仍是「数据不足」）
       · 现价 ≥ 7 天低点 × 1.03（离底 ≥3%，不接还贴着地的刀）
       · 7 天低点距今 ≥ 12h（近 12h 无新低 = 止跌确认）
       · 近 48h 回归斜率 ≥ +0.02%/h（体制不向下）
       · 止损位 stopLoss = max(7天低点×0.97, 现价×0.95)（破位即离场，
         单笔风险上限 5% 价差）；建议最长持有 168h（7 天）
     卖出 SELL：rank ≥ 0.80 且 近 48h 斜率 ≤ 0.05%/h
       （强势上行不催卖：加守则后信号后 24h 平均 −0.77% vs 不加 −0.53%）
     关注 WATCH：rank ≤ 0.35（接近低位但未满足 BUY 全部门槛）
   税率按上游 AfterTax/Price 实测反推（约 15%，逐弹计算）。
   注意：历史统计不代表未来；生产曲线窗口 7 天，全部特征在窗口内可算。
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

/** 近 n 小时最小二乘斜率（%/h，相对区间均值归一；样本 <2 返回 0） */
export function slopePctPerH(prices, n) {
  const s = prices.slice(-n)
  if (s.length < 2) return 0
  const mean = s.reduce((a, b) => a + b, 0) / s.length
  if (!(mean > 0)) return 0
  let sx = 0, sy = 0, sxx = 0, sxy = 0
  for (let i = 0; i < s.length; i++) { sx += i; sy += s[i]; sxx += i * i; sxy += i * s[i] }
  const k = s.length
  return ((k * sxy - sx * sy) / (k * sxx - sx * sx) / mean) * 100
}

/** 信号门槛（回测定稿；调参先跑 server/ammo/backtest.mjs --grid） */
export const RULES = {
  BUY_RANK_MAX: 0.20,      // 现价分位门槛（7 天窗口）
  BUY_MIN_NET_PCT: 0.10,   // 对 72h P75 目标的税后净收益率下限
  BUY_MIN_POINTS: 48,      // 买入需要的最少曲线点数（2 天）
  BUY_BOUNCE_OFF_LOW: 0.03, // 现价须高于 7 天低点 3%（离底确认）
  BUY_LOW_AGE_H: 12,       // 7 天低点须距今 ≥12h（止跌确认）
  BUY_SLOPE_MIN: 0.02,     // 近 48h 斜率下限（%/h）
  SELL_RANK_MIN: 0.80,     // 卖出分位门槛
  SELL_SLOPE_MAX: 0.05,    // 斜率高于此值视为强势上行，不催卖（%/h）
  SELL_GUARD: true,        // 卖出动量守则开关
  WATCH_RANK_MAX: 0.35,
  TARGET_WINDOW_H: 72,     // 目标价体制窗口（小时）
  STOP_LOW_PCT: 0.03,      // 止损：跌破 7 天低点 3%
  STOP_MAX_RISK: 0.05,     // 止损：单笔价差风险上限 5%
  MAX_HOLD_H: 168,         // 建议最长持有（小时）
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

  // 体制窗口：近 72h（点数不足时退整窗）；目标挂卖 = 体制内 P75
  const localPrices = prices.length >= RULES.TARGET_WINDOW_H
    ? prices.slice(-RULES.TARGET_WINDOW_H)
    : prices
  const p75Local = quantile([...localPrices].sort((a, b) => a - b), 0.75)

  // 趋势与止跌特征（全部只用截至当前的数据）
  const slope48 = slopePctPerH(prices, 48)
  const lowAgeH = prices.length - 1 - prices.lastIndexOf(weekLow)
  const bounceOffLow = current / weekLow - 1

  // 目标卖出与到手；利润口径：目标 = 近 72h P75（回测胜出配置）
  const targetSell = p75Local
  const netSell = targetSell * (1 - taxRate)
  const netHigh = weekHigh * (1 - taxRate)
  const profitPerRound = netSell - current
  const profitPct = current > 0 ? profitPerRound / current : 0
  // 止损：破 7 天低点 3% 即结构破位；同时单笔价差风险封顶 5%
  const stopLoss = Math.max(weekLow * (1 - RULES.STOP_LOW_PCT), current * (1 - RULES.STOP_MAX_RISK))

  let signal = 'WAIT'
  if (rank >= RULES.SELL_RANK_MIN && !(RULES.SELL_GUARD && slope48 > RULES.SELL_SLOPE_MAX)) signal = 'SELL'
  else if (rank <= RULES.BUY_RANK_MAX) {
    const buyOK =
      profitPct >= RULES.BUY_MIN_NET_PCT &&
      prices.length >= RULES.BUY_MIN_POINTS &&
      bounceOffLow >= RULES.BUY_BOUNCE_OFF_LOW &&
      lowAgeH >= RULES.BUY_LOW_AGE_H &&
      slope48 >= RULES.BUY_SLOPE_MIN
    if (buyOK) signal = 'BUY'
  }
  if (signal === 'WAIT' && rank <= RULES.WATCH_RANK_MAX) signal = 'WATCH'

  return {
    ...base,
    rank,
    p10, p25, p50, p75, p90,
    p75Local,
    weekHigh, weekLow,
    slope48,
    lowAgeH,
    bounceOffLow,
    targetSell,
    netSell,      // 72h P75 到手
    netHigh,      // 7 天最高到手（乐观目标）
    profitPerRound,
    profitPct,
    stopLoss,
    maxHoldH: RULES.MAX_HOLD_H,
    signal,
  }
}

/** 信号中文说明（通知与页面共用文案口径） */
export const SIGNAL_META = {
  BUY: { label: '买入', tone: 'good', hint: '低位企稳且趋势走平向上，挂卖近3天P75税后仍有≥10%利润' },
  WATCH: { label: '关注', tone: 'warn', hint: '接近低位但未同时满足止跌/趋势/利差门槛，先挂限价观察' },
  SELL: { label: '卖出', tone: 'hot', hint: '贴近7天高位且动能转弱，持仓建议挂卖离场' },
  WAIT: { label: '观望', tone: 'dim', hint: '价格处于中位区间或仍在下行，不动手' },
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
