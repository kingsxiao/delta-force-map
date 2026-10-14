/* ============================================================
   sellEta.js — 预计卖出时间（纯函数，组件 / 系统通知 / 离线自测共用）
   ------------------------------------------------------------
   两种口径，全部只吃 market.json 条目自带的 7 天小时级 curve：
     A. 历史到达历时：curve 里所有「从 ≤ 现价的低位档首次涨到 ≥ 挂卖价
        （P75）」的完整上涨段，取中位 / 最快历时（小时）——回答
        「从现在这个价位到能卖，历史上通常要几小时」。
     B. 日内节律：按小时聚合 7 天同小时均价，找连续 3 小时最高的窗口
        （允许跨午夜）——回答「这个弹种通常几点最贵」。
   时间键双格式：moligod 12 位分钟档（YYYYMMDDHHmm）/ kkrb 10 位小时档
   （YYYYMMDDHH），同 marketMeta 约定。
   ETA 时钟锚点取 max(曲线末点, now)：数据过期时从当下起算，页面的数据
   年龄提示仍如实标注边界。历史统计不代表未来——展示层必须带这句。
   ============================================================ */

/** 时间键 → 小时（0-23）；'202610131400' 与 '2026101314' 通用 */
function hourOfKey(key) {
  const h = Number(String(key).slice(8, 10))
  return Number.isInteger(h) && h >= 0 && h <= 23 ? h : null
}

/** 时间键 → Date（按数据墙钟解析；moligod/kkrb 均为北京时间口径） */
function keyToDate(key) {
  const s = String(key)
  const mi = s.length >= 12 ? Number(s.slice(10, 12)) : 0
  return new Date(Number(s.slice(0, 4)), Number(s.slice(4, 6)) - 1, Number(s.slice(6, 8)), Number(s.slice(8, 10)), mi)
}

const pad2 = (n) => String(n).padStart(2, '0')
const startOfDay = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate())

/**
 * 日内节律：7 天同小时均价 → 连续 3 小时最高的窗口（允许跨午夜回绕）。
 * @param {Array} curve [[key, price], ...]
 * @returns {{startHour:number, endHour:number, liftPct:number}|null}
 *   endHour 为开区间（如 19–22）；liftPct = 高位窗口均值相对全天最低小时均值的涨幅
 */
export function hourlyProfile(curve) {
  if (!Array.isArray(curve) || curve.length < 24) return null
  const sum = new Array(24).fill(0)
  const cnt = new Array(24).fill(0)
  for (const pt of curve) {
    const h = hourOfKey(pt[0])
    const p = pt[1]
    if (h != null && Number.isFinite(p)) { sum[h] += p; cnt[h]++ }
  }
  const avg = sum.map((s, h) => (cnt[h] ? s / cnt[h] : null))
  let startHour = -1
  let best = -Infinity
  for (let h = 0; h < 24; h++) {
    const vals = [0, 1, 2].map((o) => avg[(h + o) % 24])
    if (vals.some((v) => v == null)) continue
    const m = (vals[0] + vals[1] + vals[2]) / 3
    if (m > best) { best = m; startHour = h }
  }
  if (startHour < 0) return null
  const valid = avg.filter((v) => v != null)
  const low = Math.min(...valid)
  return {
    startHour,
    endHour: (startHour + 3) % 24,
    liftPct: low > 0 ? (best - low) / low : null,
  }
}

/**
 * 历史完整上涨段：价格从 ≤ from 出发、首次到达 ≥ to 的历时（曲线步数≈小时）。
 * 7 天窗口边缘被截断的段不计；返回升序数组（小时）。
 */
export function reachEpisodes(curve, from, to) {
  const eps = []
  let i = 0
  while (i < curve.length) {
    if (curve[i][1] <= from) {
      let j = i
      while (j < curve.length && curve[j][1] < to) j++
      if (j < curve.length && j > i) eps.push(j - i)
      i = Math.max(j, i + 1)
    } else {
      i++
    }
  }
  return eps.sort((a, b) => a - b)
}

/** 升序数组的中位数 */
function median(sorted) {
  const n = sorted.length
  const mid = n >> 1
  return n % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

/** 时刻 → 友好标签：与 base 同日「今日 HH:00」、次日「明日 HH:00」、更远「M-D HH:00」 */
function friendlyClock(hit, base) {
  // 估计值精确到小时即可：分钟四舍五入到整点，避免「21:14 前后」的假精度
  const t = new Date(Math.round(hit.getTime() / 3600000) * 3600000)
  const hm = `${pad2(t.getHours())}:00`
  const dayDiff = Math.round((startOfDay(t).getTime() - startOfDay(base).getTime()) / 86400000)
  if (dayDiff === 0) return `今日 ${hm}`
  if (dayDiff === 1) return `明日 ${hm}`
  return `${t.getMonth() + 1}-${pad2(t.getDate())} ${hm}`
}

/**
 * 预计卖出时间。吃 market.json 条目（curve / current / targetSell）。
 * @param {object} item 条目
 * @param {number} [now=Date.now()] 可注入时钟（自测用）
 * @returns {null|{
 *   atTarget: boolean, medianH: number|null, fastestH: number|null, episodes: number,
 *   peakStart: number|null, peakEnd: number|null, liftPct: number|null,
 *   trend: 'up'|'down'|'flat', etaLabel: string|null
 * }} 曲线不足 24 点返回 null；现价/目标价缺失时退化为只给日内节律
 *   （medianH=null）。atTarget = 现价已达挂卖价（只给日内高位建议，不给
 *   历时）；etaLabel 形如「今日 21:00」/「明日 08:00」/「10-16 09:00」
 */
export function predictSellEta(item, now = Date.now()) {
  const curve = Array.isArray(item && item.curve) ? item.curve : null
  if (!curve || curve.length < 24) return null
  const current = item.current
  const target = item.targetSell
  // 历时输入不全（缺现价/目标价）：不硬造 ETA，仍返回日内节律
  const hasInputs = Number.isFinite(current) && Number.isFinite(target) && target > 0

  const profile = hourlyProfile(curve)
  const atTarget = hasInputs ? current >= target : false
  const eps = atTarget || !hasInputs ? [] : reachEpisodes(curve, current, target)
  const med = eps.length ? median(eps) : null

  const tail = curve.slice(-6).map((pt) => pt[1]).filter(Number.isFinite)
  const drift = tail.length >= 2 ? tail[tail.length - 1] - tail[0] : 0

  let etaLabel = null
  if (med != null) {
    const anchorRaw = keyToDate(curve[curve.length - 1][0])
    const anchor = Number.isFinite(now) && now > anchorRaw.getTime() ? new Date(now) : anchorRaw
    etaLabel = friendlyClock(new Date(anchor.getTime() + med * 3600000), anchor)
  }

  return {
    atTarget,
    medianH: med,
    fastestH: eps.length ? eps[0] : null,
    episodes: eps.length,
    peakStart: profile ? profile.startHour : null,
    peakEnd: profile ? profile.endHour : null,
    liftPct: profile ? profile.liftPct : null,
    trend: drift > 0 ? 'up' : drift < 0 ? 'down' : 'flat',
    etaLabel,
  }
}

/** 历时可读化：5 → 「5 小时」、2.5 → 「2.5 小时」、72 → 「3 天」 */
export function fmtHours(h) {
  if (!Number.isFinite(h) || h <= 0) return '—'
  const r = Math.round(h * 2) / 2
  if (r < 48) return `${Number.isInteger(r) ? r : r.toFixed(1)} 小时`
  return `${(r / 24).toFixed(1).replace(/\.0$/, '')} 天`
}

/** 日内时段可读化：19/22 → 「19–22 点」；跨午夜 23/2 → 「23–次日 2 点」 */
export function fmtPeak(start, end) {
  if (!Number.isInteger(start) || !Number.isInteger(end)) return null
  const e = end === 0 ? 24 : end
  return e <= start ? `${start}–次日 ${end} 点` : `${start}–${e} 点`
}
