<script setup>
/* Sparkline — 7 天价格迷你走势（SVG polyline，无依赖）
   curve: [["202610061100", 755], ...]（时间升序） */
import { computed, nextTick, onMounted, ref, watch } from 'vue'

const props = defineProps({
  curve: { type: Array, default: () => [] },
  width: { type: Number, default: 120 },
  height: { type: Number, default: 30 },
  current: { type: Number, default: null },
  // 末点圆语境色（如行内信号色）；默认不传走 --accent 现状（雷达页等调用点兼容）
  endColor: { type: String, default: '' },
})

const geo = computed(() => {
  const pts = props.curve.filter(([, v]) => Number.isFinite(v) && v > 0)
  if (pts.length < 2) return null
  const vals = pts.map(([, v]) => v)
  const min = Math.min(...vals)
  const max = Math.max(...vals)
  const span = max - min || 1
  const { width: w, height: h } = props
  const xy = pts.map(([, v], i) => {
    const x = (i / (pts.length - 1)) * (w - 2) + 1
    const y = h - 2 - ((v - min) / span) * (h - 4)
    return [x, y]
  })
  const line = xy.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(' ')
  // 当前点（最后一个点）
  const last = xy[xy.length - 1]
  const area = `${line} ${w - 1},${h} 1,${h}`
  return { line, area, last, min, max }
})

/* ---------- 进场描画（页面级入场档 --t-page） ----------
   路径总长用 getTotalLength 实测而非 pathLength="1" 归一化：polyline 的
   pathLength 在旧 WebKit 不生效，dasharray:1 会把线切成可见虚线——回退不完整；
   JS 实测在所有支持 SVG 的引擎可用。drawn 置真前 dashoffset=总长（线全隐藏），
   置真后过渡到 0 即描画；curve 轮询换血后重测长度，保证 dasharray 恒 ≥ 路径总长
   （否则尾部会按 dash 周期露虚线）。RM 下不初始化隐藏态，直接全现。 */
const lineRef = ref(null)
const lineLen = ref(0)
const drawn = ref(false)
const rmMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches
function measure() {
  if (!lineRef.value) return
  lineLen.value = lineRef.value.getTotalLength()
}
onMounted(() => {
  measure() // mounted 与首次绘制同一任务，首帧即带 dasharray，不会闪完整线
  if (rmMotion()) { drawn.value = true; return }
  // 双 rAF：先让「起点 = 全隐藏」落屏一帧，再放行过渡（同帧改值会被合并跳过）
  requestAnimationFrame(() => requestAnimationFrame(() => { drawn.value = true }))
})
watch(
  () => props.curve,
  async () => {
    await nextTick() // points 属性更新进 DOM 后再量
    measure()
  },
)
</script>

<template>
  <svg
    v-if="geo"
    :width="width" :height="height" :viewBox="`0 0 ${width} ${height}`"
    class="spark" role="img" aria-label="近7天价格走势"
  >
    <polygon :points="geo.area" class="spark-fill" />
    <polyline
      ref="lineRef" :points="geo.line" class="spark-line" fill="none"
      :style="{ strokeDasharray: lineLen || 'none', strokeDashoffset: drawn ? 0 : lineLen }"
    />
    <circle :cx="geo.last[0]" :cy="geo.last[1]" r="2" class="spark-dot" :style="endColor ? { fill: endColor } : null" />
  </svg>
  <span v-else class="spark-empty">—</span>
</template>

<style scoped>
/* 默认走 --accent；可被使用方局部覆盖（如信号卡内整组降为 --dim 中性纹理）。
   末点圆另有 endColor prop 供语境着色（inline style 优先于类默认填充） */
/* 进场三段：线描画（dashoffset 过渡，420ms 入场档）→ 面随线成形淡入 → 末点收笔
   后落位。面/点静态规则保持终值、动画只声明 from——animation:none（RM 兜底）
   时直接以终值呈现，回退即现状。dashoffset 不触发布局（同 grid-rows 折叠技法
   的低代价非 transform 例外），档位与降级仍守 MOTION.md 红线 */
.spark-line {
  stroke: var(--spark-line, var(--accent)); stroke-width: 1.4;
  transition: stroke-dashoffset var(--t-page) var(--ease);
}
.spark-fill {
  fill: var(--spark-fill, var(--accent)); opacity: .1;
  animation: spark-face var(--t-med) var(--ease) 120ms both;
}
.spark-dot {
  fill: var(--spark-dot, var(--accent));
  animation: spark-dot-in var(--t-med) var(--ease) 300ms both;
}
@keyframes spark-face { from { opacity: 0 } }
@keyframes spark-dot-in { from { opacity: 0 } }
.spark-empty { color: var(--faint); }

@media (prefers-reduced-motion: reduce) {
  /* 线的隐藏起点由 script 的 RM 分支跳过（drawn 直接置真），这里再关过渡双保险；
     面/点动画停用后按静态终值呈现 */
  .spark-line { transition: none; }
  .spark-fill, .spark-dot { animation: none; }
}
</style>
