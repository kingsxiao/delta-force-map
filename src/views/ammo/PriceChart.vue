<script setup>
/* PriceChart — 展开行内的 7 天价格大图：折线 + P25/P75 分位虚线 + 当前点
   curve: [["202610061100", 755], ...]（时间升序）
   分位标注挂在各自线的左端（x=PAD.l+4、start 对齐），与右缘「现在」标注错位；
   纵向经 pickY 防撞：避让三条 Y 轴刻度基线、两条 X 轴时间标签基线与已落位的另一条分位标注 */
import { computed } from 'vue'

const props = defineProps({
  curve: { type: Array, default: () => [] },
  p25: { type: Number, default: null },
  p75: { type: Number, default: null },
  current: { type: Number, default: null },
})

const W = 680
const H = 200
const PAD = { l: 46, r: 14, t: 12, b: 26 }

const geo = computed(() => {
  const pts = props.curve.filter(([, v]) => Number.isFinite(v) && v > 0)
  if (pts.length < 2) return null
  const vals = pts.map(([, v]) => v)
  const extras = [props.p25, props.p75].filter((v) => Number.isFinite(v))
  const min = Math.min(...vals, ...extras)
  const max = Math.max(...vals, ...extras)
  const span = (max - min) || 1
  const iw = W - PAD.l - PAD.r
  const ih = H - PAD.t - PAD.b
  const x = (i) => PAD.l + (i / (pts.length - 1)) * iw
  const y = (v) => PAD.t + ih - ((v - min) / span) * ih
  const line = pts.map(([, v], i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)} ${y(v).toFixed(1)}`).join(' ')
  const lastIdx = pts.length - 1
  // 首尾时间标签（YYYYMMDDHHmm → MM-DD HH:00）
  const fmtTs = (ts) => `${ts.slice(4, 6)}-${ts.slice(6, 8)} ${ts.slice(8, 10)}时`

  // 分位标注防撞取 y：三级回退（线上方 → 线下方 → 再抬高 8px），距避让基线均需 ≥11px
  const XL_Y = H - 8 // 两条 X 轴时间标签基线
  const mid = (max + min) / 2
  const base3 = [y(max) + 4, y(mid) + 4, y(min) + 4] // 三条 Y 轴刻度基线
  const pickY = (v, avoid) => {
    const baselines = [...base3, XL_Y, ...avoid]
    const clear = (yy) => baselines.every((b) => Math.abs(yy - b) >= 11)
    const c1 = y(v) - 5
    if (clear(c1)) return c1
    const c2 = y(v) + 11
    if (clear(c2) && c2 <= H - PAD.b) return c2 // 不得进入 X 轴标签区
    return Math.max(y(v) - 13, PAD.t + 8)
  }
  // 先落 P75，其结果计入避让集后再算 P25，两条标注互不相撞
  const avoid = []
  let q75y = null
  let q25y = null
  if (Number.isFinite(props.p75)) {
    q75y = pickY(props.p75, avoid)
    avoid.push(q75y)
  }
  if (Number.isFinite(props.p25)) q25y = pickY(props.p25, avoid)
  // 两条分位线重合（扁平曲线实测 p25==p75）时两条标注会落到同一 y：把 P25 上/下移 11px 错开
  if (q75y != null && q25y != null && Math.abs(q75y - q25y) < 11) {
    const alt = [q75y - 11, q75y + 11].find(
      (yy) => yy >= PAD.t + 8 && [...base3, XL_Y].every((b) => Math.abs(yy - b) >= 11)
    )
    if (alt != null) q25y = alt
  }

  return {
    line, min, max, y, x, ih, iw, q75y, q25y,
    dot: { cx: x(lastIdx), cy: y(pts[lastIdx][1]), r: 3.5 },
    area: `${line} L${x(lastIdx).toFixed(1)} ${PAD.t + ih} L${PAD.l} ${PAD.t + ih} Z`,
    labels: { first: fmtTs(pts[0][0]), last: fmtTs(pts[lastIdx][0]) },
    firstX: PAD.l, lastX: W - PAD.r,
  }
})
</script>

<template>
  <div v-if="geo" class="pchart">
    <svg :viewBox="`0 0 ${W} ${H}`" class="pc-svg" role="img" aria-label="近7天每小时价格">
      <!-- Y 轴刻度：max / mid / min -->
      <text :x="PAD.l - 6" :y="geo.y(geo.max) + 4" class="pc-tick" text-anchor="end">{{ Math.round(geo.max) }}</text>
      <text :x="PAD.l - 6" :y="geo.y((geo.max + geo.min) / 2) + 4" class="pc-tick" text-anchor="end">{{ Math.round((geo.max + geo.min) / 2) }}</text>
      <text :x="PAD.l - 6" :y="geo.y(geo.min) + 4" class="pc-tick" text-anchor="end">{{ Math.round(geo.min) }}</text>

      <!-- 分位线：P75 卖出参考（上）、P25 买入参考（下）；标注挂线左端，与右缘「现在」错位 -->
      <line v-if="p75" :x1="PAD.l" :y1="geo.y(p75)" :x2="W - PAD.r" :y2="geo.y(p75)" class="pc-quant q75" />
      <text v-if="p75" :x="PAD.l + 4" :y="geo.q75y" class="pc-qtxt q75t" text-anchor="start">P75 卖出参考 {{ Math.round(p75) }}</text>
      <line v-if="p25" :x1="PAD.l" :y1="geo.y(p25)" :x2="W - PAD.r" :y2="geo.y(p25)" class="pc-quant q25" />
      <text v-if="p25" :x="PAD.l + 4" :y="geo.q25y" class="pc-qtxt q25t" text-anchor="start">P25 买入参考 {{ Math.round(p25) }}</text>

      <path :d="geo.area" class="pc-area" />
      <path :d="geo.line" class="pc-line" fill="none" />
      <circle v-bind="geo.dot" class="pc-dot" />
      <text :x="geo.dot.cx - 6" :y="geo.dot.cy - 10" class="pc-curtxt" text-anchor="end">现在 {{ Math.round(current ?? 0) }}</text>

      <text :x="geo.firstX" :y="H - 8" class="pc-tick">{{ geo.labels.first }}</text>
      <text :x="geo.lastX" :y="H - 8" class="pc-tick" text-anchor="end">{{ geo.labels.last }}</text>
    </svg>
  </div>
  <p v-else class="pc-empty">历史数据不足</p>
</template>

<style scoped>
.pchart { width: 100%; }
.pc-svg { display: block; width: 100%; height: auto; }
.pc-line { stroke: var(--accent); stroke-width: 1.8; }
.pc-area { fill: var(--accent); opacity: .08; }
.pc-dot { fill: var(--tx-strong); }
.pc-curtxt { font-family: var(--mono); font-size: 11px; fill: var(--tx-strong); }
.pc-tick { font-family: var(--mono); font-size: 10px; fill: var(--faint); }
.pc-quant { stroke-dasharray: 5 4; stroke-width: 1; }
.q75 { stroke: var(--danger, #f87171); }
.q75t { fill: var(--danger, #f87171); }
.q25 { stroke: var(--ok, #34d399); }
.q25t { fill: var(--ok, #34d399); }
.pc-qtxt { font-family: var(--mono); font-size: 10px; }
.pc-empty { color: var(--faint); font-size: var(--fs-sm); }
</style>
