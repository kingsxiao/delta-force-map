/* ============================================================
   sellEta.js — 预计卖出时间（纯函数，组件 / 系统通知 / 离线自测共用）
   ------------------------------------------------------------
   两种口径，全部只吃 market.json 条目自带的 7 天小时级 curve：
     A. 历史到达历时：curve 里所有「从 ≤ 现价的低位档首次涨到 ≥ 挂卖价
        （P75）」的完整上涨段，取中位 / 最快历时（小时）——回答
        「从现在这个价位到能卖，历史上通常要几小时」。
     B. 日内节律：按小时聚合 7 天同小时均价，找连续 3 小时最高的窗口
        （允许跨午夜）——回答「这个弹种通常几点最贵」。
   另有全市场聚合口径 marketClock(items)：逐弹归一为相对自身 7 天均值的
   价格比值后跨弹按小时取中位（见函数注释）——回答「现在几点，该扫货还是
   该出货」。
   时间键双格式：moligod 12 位分钟档（YYYYMMDDHHmm）/ kkrb 10 位小时档
   （YYYYMMDDHH），同 marketMeta 约定。
   墙钟口径固定北京时间（+08:00，时间键的生成口径）：keyToDate 解析与
   friendlyClock 渲染都不走访问者本地时区——与 iOS SellEta.swift 固定
   Asia/Shanghai 同口径，海外访问者看到的「今日/明日 HH:00」与北京一致。
   ETA 时钟锚点取 max(曲线末点, now)：数据过期时从当下起算，页面的数据
   年龄提示仍如实标注边界。历史统计不代表未来——展示层必须带这句。
   ============================================================ */

/** 时间键 → 小时（0-23）；'202610131400' 与 '2026101314' 通用 */
function hourOfKey(key) {
  const h = Number(String(key).slice(8, 10))
  return Number.isInteger(h) && h >= 0 && h <= 23 ? h : null
}

/** 北京墙钟相对 UTC 的固定偏移（无夏令时，日界计算可直接整除） */
const BEIJING_OFFSET_MS = 8 * 60 * 60 * 1000

/** 时间键 → Date（按北京墙钟解析；moligod/kkrb 均为北京时间口径，不随访问者时区漂移） */
function keyToDate(key) {
  const s = String(key)
  const mi = s.length >= 12 ? Number(s.slice(10, 12)) : 0
  const wall = Date.UTC(Number(s.slice(0, 4)), Number(s.slice(4, 6)) - 1, Number(s.slice(6, 8)), Number(s.slice(8, 10)), mi)
  return new Date(wall - BEIJING_OFFSET_MS)
}

const pad2 = (n) => String(n).padStart(2, '0')
/** epoch → 该时刻北京墙钟当日 0 点的 epoch */
const beijingDayStart = (ms) => Math.floor((ms + BEIJING_OFFSET_MS) / 86400000) * 86400000 - BEIJING_OFFSET_MS

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
 * 全市场日内节律：逐弹归一 → 跨弹按小时取中位聚合（组件展示 / iOS 对拍共用）。
   单价量纲差极大（实测 67 弹 162~6140），直接平均原始价则高价弹权重近 40 倍、
   结果退化为高价弹的节律——因此每条 curve 先除以该弹自身 7 天均值化为价格比值
   （1.0 = 各弹自身均价），再按小时跨弹取中位数（抗离群），得到 24 小时相对水位。
   「此刻指针」不用设备本地时间：取参与聚合曲线中最新末点的小时（数据墙钟，
   与 iOS 固定 Asia/Shanghai 口径等价，海外设备不错位）；判读按该小时水位在
   全天 [最低, 最高] 区间的位置分三档（下 1/3 扫货 / 上 1/3 出货 / 中段观望），
   语义对照倒卖手册 WINDOWS（Playbook.vue / PlaybookView.swift）。
   纯字符串键前缀比较，全程不经 Date——不受访问者时区影响。
   历史统计不代表未来——展示层必须带这句。
 */
export function marketClock(items) {
  if (!Array.isArray(items) || !items.length) return null
  const ratios = Array.from({ length: 24 }, () => [])
  let counted = 0
  let maxPrefix = null // 最新末点的 YYYYMMDDHH 数值前缀（12 位分钟档 / 10 位小时档通用）
  let dataHour = null
  for (const item of items) {
    const curve = item && Array.isArray(item.curve) ? item.curve : null
    if (!curve || curve.length < 24) continue
    let sum = 0
    let cnt = 0
    for (const pt of curve) if (Number.isFinite(pt[1])) { sum += pt[1]; cnt++ }
    const mean = cnt > 0 ? sum / cnt : NaN
    if (!Number.isFinite(mean) || mean <= 0) continue
    for (const pt of curve) {
      const h = hourOfKey(pt[0])
      const p = pt[1]
      if (h != null && Number.isFinite(p)) ratios[h].push(p / mean)
    }
    counted++
    // 末点比较只看 YYYYMMDDHH 前缀（同为数据墙钟，分钟差不影响小时判读）
    const endKey = String(curve[curve.length - 1][0])
    if (endKey.length >= 10) {
      const pref = Number(endKey.slice(0, 10))
      if (Number.isFinite(pref) && (maxPrefix == null || pref > maxPrefix)) {
        maxPrefix = pref
        dataHour = hourOfKey(endKey)
      }
    }
  }
  if (!counted) return null
  const levels = ratios.map((list) => (list.length ? median([...list].sort((a, b) => a - b)) : null))
  const win = best3hWindow(levels)
  return {
    counted,
    levels,
    peakStart: win ? win.startHour : null,
    peakEnd: win ? win.endHour : null,
    liftPct: win ? win.liftPct : null,
    dataHour,
    verdict: clockVerdict(dataHour != null ? levels[dataHour] : null, levels),
  }
}

/** 相对水位数组上的连续 3 小时最高窗口（允许跨午夜回绕；口径同 hourlyProfile） */
function best3hWindow(levels) {
  let startHour = -1
  let best = -Infinity
  for (let h = 0; h < 24; h++) {
    const vals = [0, 1, 2].map((o) => levels[(h + o) % 24])
    if (vals.some((v) => v == null)) continue
    const m = (vals[0] + vals[1] + vals[2]) / 3
    if (m > best) { best = m; startHour = h }
  }
  if (startHour < 0) return null
  const valid = levels.filter((v) => v != null)
  const low = Math.min(...valid)
  return { startHour, endHour: (startHour + 3) % 24, liftPct: low > 0 ? (best - low) / low : null }
}

/** 此刻判读：水位落在全天区间下 1/3 扫货 / 上 1/3 出货 / 中段观望；区间平坦不给方向 */
function clockVerdict(cur, levels) {
  const valid = levels.filter((v) => v != null)
  if (!valid.length || cur == null || !Number.isFinite(cur)) return null
  const low = Math.min(...valid)
  const high = Math.max(...valid)
  if (!(high - low > 1e-9)) return 'wait'
  const pos = (cur - low) / (high - low)
  return pos <= 1 / 3 ? 'buy' : pos >= 2 / 3 ? 'sell' : 'wait'
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

/** 时刻 → 友好标签：与 base 同日「今日 HH:00」、次日「明日 HH:00」、更远「M-D HH:00」
    （北京墙钟口径：加偏移后读 getUTC* 分量，不随访问者本地时区漂移） */
function friendlyClock(hit, base) {
  // 估计值精确到小时即可：分钟四舍五入到整点，避免「21:14 前后」的假精度
  const tMs = Math.round(hit.getTime() / 3600000) * 3600000
  const t = new Date(tMs + BEIJING_OFFSET_MS)
  const hm = `${pad2(t.getUTCHours())}:00`
  const dayDiff = Math.round((beijingDayStart(tMs) - beijingDayStart(base.getTime())) / 86400000)
  if (dayDiff === 0) return `今日 ${hm}`
  if (dayDiff === 1) return `明日 ${hm}`
  return `${t.getUTCMonth() + 1}-${pad2(t.getUTCDate())} ${hm}`
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
