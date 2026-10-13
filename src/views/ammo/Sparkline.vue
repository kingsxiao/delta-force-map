<script setup>
/* Sparkline — 7 天价格迷你走势（SVG polyline，无依赖）
   curve: [["202610061100", 755], ...]（时间升序） */
import { computed } from 'vue'

const props = defineProps({
  curve: { type: Array, default: () => [] },
  width: { type: Number, default: 120 },
  height: { type: Number, default: 30 },
  current: { type: Number, default: null },
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
</script>

<template>
  <svg
    v-if="geo"
    :width="width" :height="height" :viewBox="`0 0 ${width} ${height}`"
    class="spark" role="img" aria-label="近7天价格走势"
  >
    <polygon :points="geo.area" class="spark-fill" />
    <polyline :points="geo.line" class="spark-line" fill="none" />
    <circle :cx="geo.last[0]" :cy="geo.last[1]" r="2" class="spark-dot" />
  </svg>
  <span v-else class="spark-empty">—</span>
</template>

<style scoped>
/* 默认走 --accent；可被使用方局部覆盖（如信号卡内降为 --dim 中性纹理） */
.spark-line { stroke: var(--spark-line, var(--accent)); stroke-width: 1.4; }
.spark-fill { fill: var(--spark-fill, var(--accent)); opacity: .1; }
.spark-dot { fill: var(--accent); }
.spark-empty { color: var(--faint); }
</style>
