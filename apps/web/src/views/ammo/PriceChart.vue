<script setup>
/* PriceChart — 展开行内的 7 天价格大图：折线 + P25/P75 分位虚线 + 当前点
   curve: [["202610061100", 755], ...]（时间升序）
   分位标注挂在各自线的左端（x=PAD.l+4、start 对齐），与右缘「现在」标注错位；
   纵向经 pickY 防撞：避让三条 Y 轴刻度基线、两条 X 轴时间标签基线与已落位的另一条分位标注 */
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'

const props = defineProps({
  curve: { type: Array, default: () => [] },
  p25: { type: Number, default: null },
  p75: { type: Number, default: null },
  current: { type: Number, default: null },
})

const H = 200
const PAD = { l: 46, r: 14, t: 12, b: 26 }

/* ---------- 绘图基准宽自适应（子弹/雷达双页共用，props 不变） ----------
   固定 680 基准等比缩放时，<680px 容器下刻度/标注文字会等比缩到 ~6px 难读。
   按容器实际宽选基准：≥680 用 680 基准（更宽容器仍由样式 max-width:900px
   封顶放大）；窄容器用容器实际宽（下限 400 兜底超窄屏）——viewBox 宽 ≈
   渲染宽，缩放比恒 ≈1，文字保持像素级大小稳定。容器宽经 ResizeObserver 跟踪。 */
const W_BASE = 680
const W_MIN = 400
const hostRef = ref(null)
const boxW = ref(0)
let ro = null
onMounted(() => {
  const el = hostRef.value
  if (!el) return // curve 不足 2 点时只渲染空态 <p>，无需探测（双页曲线静态，空态不回翻）
  boxW.value = el.clientWidth
  ro = new ResizeObserver((entries) => {
    for (const e of entries) boxW.value = e.contentRect.width
  })
  ro.observe(el)
})
onBeforeUnmount(() => { if (ro) ro.disconnect() })
const W = computed(() => Math.round(Math.min(Math.max(boxW.value || W_BASE, W_MIN), W_BASE)))

const geo = computed(() => {
  const pts = props.curve.filter(([, v]) => Number.isFinite(v) && v > 0)
  if (pts.length < 2) return null
  const w = W.value
  const vals = pts.map(([, v]) => v)
  const extras = [props.p25, props.p75].filter((v) => Number.isFinite(v))
  const min = Math.min(...vals, ...extras)
  const max = Math.max(...vals, ...extras)
  const span = (max - min) || 1
  const iw = w - PAD.l - PAD.r
  const ih = H - PAD.t - PAD.b
  const x = (i) => PAD.l + (i / (pts.length - 1)) * iw
  const y = (v) => PAD.t + ih - ((v - min) / span) * ih
  const line = pts.map(([, v], i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)} ${y(v).toFixed(1)}`).join(' ')
  const lastIdx = pts.length - 1
  // 「现在」标注基线：默认在末点上方 10px；现价贴近 7 天高点时上方会顶出画布
  // （fs-2xs 11px 字 ascent≈9，基线 <10 即裁切），翻到末点下方 16px
  const lastY = y(pts[lastIdx][1])
  const curLabelY = lastY - 10 < 10 ? lastY + 16 : lastY - 10
  // 「现在」标注水平防撞：末点恒在绘图区最右端，与展开面板右上角绝对定位的
  // 「收起」按钮带（top:10 right:10，雷达页直接压图、子弹页虽有 td 顶部
  // padding 让位仍同域）重叠。标注 x 超过绘图区 70% 宽即翻转到数据点左侧
  // 渲染：右对齐、右缘退到点左方 60 视图单位（≈按钮带宽 + 边距），整体让出
  // 右上角按钮区；y 仍走上面的纵向防撞
  const curFlip = x(lastIdx) > PAD.l + iw * 0.7
  const cur = {
    x: curFlip ? x(lastIdx) - 60 : x(lastIdx) + 8,
    y: curLabelY,
    anchor: curFlip ? 'end' : 'start',
  }
  // 首尾时间标签（YYYYMMDDHHmm → MM-DD HH:mm；kkrb 小时档键分钟位为 00，显示不变）
  const fmtTs = (ts) => `${ts.slice(4, 6)}-${ts.slice(6, 8)} ${ts.slice(8, 10)}:${ts.slice(10, 12) || '00'}`

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
    line, min, max, y, x, ih, iw, q75y, q25y, cur,
    dot: { cx: x(lastIdx), cy: lastY, r: 3.5 },
    area: `${line} L${x(lastIdx).toFixed(1)} ${PAD.t + ih} L${PAD.l} ${PAD.t + ih} Z`,
    labels: { first: fmtTs(pts[0][0]), last: fmtTs(pts[lastIdx][0]) },
    firstX: PAD.l, lastX: w - PAD.r,
  }
})
</script>

<template>
  <div v-if="geo" ref="hostRef" class="pchart">
    <svg :viewBox="`0 0 ${W} ${H}`" class="pc-svg" role="img" :aria-label="current != null ? '近7天每小时价格，现价 ' + Math.round(current) : '近7天每小时价格'">
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
      <text :x="geo.cur.x" :y="geo.cur.y" class="pc-curtxt" :text-anchor="geo.cur.anchor">现在 {{ Math.round(current ?? 0) }}</text>

      <text :x="geo.firstX" :y="H - 8" class="pc-tick">{{ geo.labels.first }}</text>
      <text :x="geo.lastX" :y="H - 8" class="pc-tick" text-anchor="end">{{ geo.labels.last }}</text>
    </svg>
  </div>
  <p v-else class="pc-empty">历史数据不足</p>
</template>

<style scoped>
.pchart { width: 100%; }
/* ≥680 容器：680 基准 viewBox 随容器等比放大，全宽展开行（~1160px）下刻度字会
   渲染到 ~17px、超过正文基准，与下方脚注字号倒挂；封顶 900px（≈1.32x）让图内
   文字回到 12~14px 字阶族。<680 容器：脚本按容器实际宽收窄 viewBox 基准
   （ResizeObserver，下限 400），缩放比恒 ≈1，小屏刻度/标注不再等比缩小难读 */
.pc-svg { display: block; width: 100%; max-width: 900px; height: auto; }
.pc-line { stroke: var(--accent); stroke-width: 1.8; }
.pc-area { fill: var(--accent); opacity: .08; }
.pc-dot { fill: var(--tx-strong); }
.pc-curtxt { font-family: var(--mono); font-size: var(--fs-2xs); fill: var(--tx-strong); }
.pc-tick { font-family: var(--mono); font-size: var(--fs-micro); fill: var(--faint); }
.pc-quant { stroke-dasharray: 5 4; stroke-width: 1; }
.q75 { stroke: var(--danger); }
.q75t { fill: var(--danger); }
.q25 { stroke: var(--ok); }
.q25t { fill: var(--ok); }
.pc-qtxt { font-family: var(--mono); font-size: var(--fs-micro); }
.pc-empty { color: var(--faint); font-size: var(--fs-sm); }
</style>
