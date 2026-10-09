<script setup>
// MapViewer.vue — 页内交互查看器容器（工程师A）：legacy makeFigure（L437-503）+
// 查看器（L504-753）的 Vue 版。拖拽/捏合/滚轮/双击/tap-pair 全部在 useViewer 内原样移植，
// 本组件只负责模板结构、变体 tabs、图层开关 chips 与信息卡装配。
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { createViewer, HS_TYPES, HS_TCOL } from '../../composables/useViewer'
import HotspotLayer from './HotspotLayer.vue'
import InfoCard from './InfoCard.vue'

const props = defineProps({
  map: { type: Object, required: true },
})
const emit = defineEmits(['full'])

const frameRef = ref(null)
const vpRef = ref(null)
const planeRef = ref(null)
const imgRef = ref(null)
const cardRef = ref(null)

const hidden = reactive({ spawn: false, extract: false, boss: false, loot: false })

const viewer = createViewer({
  map: props.map,
  vp: vpRef,
  frame: frameRef,
  plane: planeRef,
  img: imgRef,
  card: cardRef,
  onFull: (idx) => emit('full', idx),
})

const figSrc = computed(() => props.map.fig[viewer.state.cur].src)
const figAlt = computed(() => props.map.map + ' · ' + props.map.fig[viewer.state.cur].label)
const hsVisible = computed(() => !!props.map.fig[viewer.state.cur].hs && props.map.hs && props.map.hs.length > 0)
const activeSpot = computed(() => (viewer.state.active >= 0 ? props.map.hs[viewer.state.active] : null))

/** chips：legacy L648-661——只出现计数>0 的类型，顺序与 TYPES 键序一致 */
const chipList = computed(() => {
  const counts = {}
  props.map.hs.forEach((sp) => { counts[sp.type] = (counts[sp.type] || 0) + 1 })
  return Object.keys(HS_TYPES)
    .filter((t) => counts[t])
    .map((t) => ({ type: t, label: HS_TYPES[t], color: HS_TCOL[t], count: counts[t] }))
})

function toggleType(t) {
  hidden[t] = !hidden[t]
  if (hidden[t]) viewer.closeCardIfType(t)
}

function onCardExpand() {
  nextTick(() => viewer.positionCard())
}

/* InfoCard 是组件：函数 ref 收到的是实例，解包其 $el；不能在模板内联箭头里写
   $setup.cardRef.value（setupState 经 proxyRefs 解包，内联赋值会 set 到 null 上） */
function setCardEl(el) {
  cardRef.value = el && el.$el ? el.$el : el
}

/* 打开信息卡时等 DOM 挂载完再定位（legacy 同步填充后直接 positionCard，Vue 需等 flush） */
watch(
  () => viewer.state.active,
  (v) => { if (v >= 0) nextTick(() => viewer.positionCard()) },
)

onMounted(() => viewer.attach())
onBeforeUnmount(() => viewer.detach())
</script>

<template>
  <figure class="map-fig reveal">
    <div
      ref="frameRef"
      class="fig-frame"
      tabindex="0"
      :aria-label="map.map + ' 交互地图：方向键或 +/-/0 缩放平移，点击标注查看详情'"
      @keydown="viewer.onKey"
    >
      <div ref="vpRef" class="fig-vp">
        <div ref="planeRef" class="fig-plane">
          <img
            ref="imgRef"
            :src="figSrc"
            :alt="figAlt"
            decoding="async"
            draggable="false"
            @load="viewer.onImgLoad"
          >
          <HotspotLayer v-if="hsVisible" :hs="map.hs" :active="viewer.state.active" :hidden="hidden" />
        </div>

        <InfoCard
          :ref="setCardEl"
          :key="viewer.state.active"
          v-show="viewer.state.active >= 0"
          :spot="activeSpot"
          :map="map"
          :style="{ left: viewer.state.cardLeft + 'px', top: viewer.state.cardTop + 'px' }"
          @close="viewer.closeCard()"
          @expand="onCardExpand"
        />

        <div v-show="hsVisible" class="hs-chips">
          <button
            v-for="c in chipList"
            :key="c.type"
            type="button"
            class="hs-chip"
            :class="{ off: hidden[c.type] }"
            :data-t="c.type"
            :aria-pressed="String(!hidden[c.type])"
            @click="toggleType(c.type)"
          >
            <i class="dot" :style="{ background: c.color }"></i>
            <span>{{ c.label }} {{ c.count }}</span>
          </button>
        </div>

        <div class="fig-ctrl">
          <button type="button" data-act="in" aria-label="放大" title="放大" @click="viewer.zoomIn()">＋</button>
          <button type="button" data-act="out" aria-label="缩小" title="缩小" @click="viewer.zoomOut()">－</button>
          <button type="button" data-act="reset" aria-label="复位 (0)" title="复位 (0)" @click="viewer.resetView()">⟲</button>
          <button type="button" data-act="full" aria-label="全屏查看" title="全屏查看" @click="$emit('full', viewer.state.cur)">⤢</button>
        </div>

        <span class="fig-hint">拖拽平移 · 滚轮缩放 · 双击放大 · 点标注看详情</span>
      </div>
    </div>

    <figcaption class="fig-bar">
      <div class="fig-tabs">
        <button
          v-for="(f, i) in map.fig"
          :key="i"
          type="button"
          class="fig-tab"
          :class="{ on: i === viewer.state.cur }"
          @click="viewer.setVariant(i)"
        >
          {{ f.label }}
        </button>
      </div>
      <div class="fig-cap">{{ map.fig[viewer.state.cur].cap }}</div>
    </figcaption>
  </figure>
</template>

<style scoped>
/* legacy CSS L80-134（figure / in-page viewer），取值令牌化 */
.map-fig { margin: 0 0 26px; }
.fig-frame {
  position: relative;
  border-radius: var(--radius-lg);
  overflow: hidden;
  border: 1px solid var(--line);
  background: var(--deep);
  transition: border-color var(--t-med), box-shadow var(--t-med);
}
.fig-frame:hover { border-color: var(--line-hover); box-shadow: var(--shadow-md); }
.fig-frame:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.fig-vp { position: absolute; inset: 0; overflow: hidden; cursor: grab; touch-action: none; }
.fig-vp.dragging { cursor: grabbing; }
.fig-plane { position: absolute; top: 0; left: 0; width: 100%; transform-origin: 0 0; will-change: transform; }
.fig-plane > img {
  display: block;
  width: 100%;
  height: auto;
  pointer-events: none;
  user-select: none;
  -webkit-user-select: none;
}
.fig-ctrl {
  position: absolute;
  right: 10px;
  bottom: 10px;
  display: flex;
  flex-direction: column;
  gap: 6px;
  z-index: 4;
  pointer-events: none;
}
.fig-ctrl button {
  pointer-events: auto;
  width: 30px;
  height: 30px;
  border-radius: var(--radius);
  border: 1px solid rgba(255, 255, 255, 0.14);
  background: var(--scrim);
  backdrop-filter: blur(6px);
  -webkit-backdrop-filter: blur(6px);
  color: var(--tx);
  font-size: var(--fs-md);
  line-height: 1;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: color var(--t-fast), border-color var(--t-fast);
  padding: 0;
}
.fig-ctrl button:hover { color: var(--accent); border-color: var(--accent-dim); }
.hs-chips {
  position: absolute;
  left: 10px;
  top: 10px;
  z-index: 4;
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  max-width: calc(100% - 56px);
  pointer-events: none;
}
.hs-chip {
  pointer-events: auto;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: var(--fs-2xs);
  color: var(--tx);
  padding: 4px 10px;
  border-radius: var(--radius-pill);
  border: 1px solid rgba(255, 255, 255, 0.13);
  background: var(--scrim);
  backdrop-filter: blur(6px);
  -webkit-backdrop-filter: blur(6px);
  cursor: pointer;
  transition: opacity var(--t-med);
  white-space: nowrap;
}
.hs-chip .dot { width: 8px; height: 8px; flex: none; }
.hs-chip[data-t='spawn'] .dot { border-radius: 50%; }
.hs-chip[data-t='extract'] .dot { border-radius: 2px; }
.hs-chip[data-t='loot'] .dot { border-radius: 2px; transform: rotate(45deg) scale(0.9); }
.hs-chip[data-t='boss'] .dot { border-radius: 50%; box-shadow: 0 0 0 2px color-mix(in srgb, var(--hs-boss) 35%, transparent); }
.hs-chip.off { opacity: 0.42; }
.hs-chip.off span { color: var(--faint); }
.fig-hint {
  position: absolute;
  left: 10px;
  bottom: 10px;
  font-size: var(--fs-2xs);
  font-family: var(--mono);
  letter-spacing: .05em;
  color: rgba(233, 238, 242, 0.85);
  background: rgba(7, 9, 11, 0.66);
  backdrop-filter: blur(4px);
  -webkit-backdrop-filter: blur(4px);
  padding: 4px 10px;
  border-radius: var(--radius-sm);
  pointer-events: none;
  opacity: 0;
  transition: opacity var(--t-med);
}
.fig-frame:hover .fig-hint,
.fig-frame:focus-visible .fig-hint,
.fig-frame:focus-within .fig-hint { opacity: 1; }
@media (hover: none) { .fig-hint { opacity: 1; } }
.fig-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 14px;
  margin-top: var(--sp-3);
  flex-wrap: wrap;
}
.fig-tabs {
  display: inline-flex;
  gap: 2px;
  background: var(--bg2);
  border: 1px solid var(--line2);
  border-radius: var(--radius);
  padding: 3px;
}
.fig-tab {
  border: 0;
  background: none;
  color: var(--dim);
  font-size: var(--fs-xs);
  padding: 5px 13px;
  border-radius: var(--radius-sm);
  cursor: pointer;
  transition: color var(--t-med), background var(--t-med);
  white-space: nowrap;
}
.fig-tab:hover { color: var(--tx); }
.fig-tab.on { background: var(--card2); color: var(--accent); }
.fig-cap { font-size: var(--fs-xs); color: var(--faint); line-height: 1.6; min-width: 0; }
</style>
