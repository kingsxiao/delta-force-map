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
  eager: { type: Boolean, default: false }, // 首图 eager（LCP + smoke 门依赖 ≥1 张 complete），其余 lazy 按需
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

const curFig = computed(() => props.map.fig[viewer.state.cur])
const figSrc = computed(() => curFig.value.src)
const figAlt = computed(() => props.map.map + ' · ' + curFig.value.label)
const hsVisible = computed(() => !!curFig.value.hs && props.map.hs && props.map.hs.length > 0)

/* 固有宽高（FIG_META 实测静态值）→ frame 预置 aspect-ratio：加载前高度即定，
   拦截图片时不再 2px 塌陷、滚动途中不再下沉跳变；缺 w/h 的图返回 undefined，由 onImgLoad 兜底 */
const figRatio = computed(() => {
  const { w, h } = curFig.value
  return w && h ? w + ' / ' + h : undefined
})
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
      :style="figRatio ? { aspectRatio: figRatio } : undefined"
      :aria-label="map.map + ' 交互地图：方向键或 +/-/0 缩放平移，点击标注查看详情'"
      @keydown="viewer.onKey"
    >
      <div ref="vpRef" class="fig-vp">
        <div ref="planeRef" class="fig-plane">
          <!-- width/height 为固有尺寸元信息（显示尺寸仍由 CSS width:100%/height:auto 接管），
               浏览器据此在加载前预算 img 盒高，与 frame 的静态 aspect-ratio 双保险 -->
          <img
            ref="imgRef"
            :src="figSrc"
            :alt="figAlt"
            :width="curFig.w"
            :height="curFig.h"
            :loading="eager ? 'eager' : 'lazy'"
            decoding="async"
            draggable="false"
            @load="viewer.onImgLoad"
          >
          <HotspotLayer v-if="hsVisible" :hs="map.hs" :active="viewer.state.active" :hidden="hidden" @open="viewer.openCard" />
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

        <div class="fig-ctrl">
          <!-- §5.3：控制字符换 inline SVG（16×16 / stroke 1.6 / currentColor）；
               button 元素、data-act、title/aria 与 click 行为不动（契约 3 依赖 data-act="full"） -->
          <button type="button" data-act="in" aria-label="放大" title="放大" @click="viewer.zoomIn()">
            <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
              <path d="M3 8h10M8 3v10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
            </svg>
          </button>
          <button type="button" data-act="out" aria-label="缩小" title="缩小" @click="viewer.zoomOut()">
            <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
              <path d="M3 8h10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
            </svg>
          </button>
          <button type="button" data-act="reset" aria-label="复位" title="复位" @click="viewer.resetView()">
            <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
              <path d="M13.66 10a6 6 0 1 1-1.41-6.24L15.33 6.67" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" />
              <path d="M15.33 2.67v4h-4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" />
            </svg>
          </button>
          <button type="button" data-act="full" aria-label="放大查看" title="放大查看" @click="$emit('full', viewer.state.cur)">
            <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
              <path d="M6 2H2v4M10 2h4v4M6 14H2v-4M10 14h4v-4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" />
            </svg>
          </button>
        </div>

        <span class="fig-hint">拖拽平移 · 滚轮 / 双指缩放 · 双击放大 · 点标注看详情</span>
      </div>

      <!-- 图层 chips 直挂 .fig-frame（vp 的 touch-action:none 沿祖先链封禁原生滚动，
           留在 vp 内触屏横滚滚不动）；绝对定位锚点随之为 frame，视觉位置不变 -->
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
  box-shadow: var(--edge-light);
  transition: border-color var(--t-med) var(--ease), box-shadow var(--t-med) var(--ease);
}
.fig-frame:hover { border-color: var(--line-hover); box-shadow: var(--edge-hover); }
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
  border: 1px solid var(--glass-line);
  background: var(--scrim);
  backdrop-filter: blur(var(--panel-blur));
  -webkit-backdrop-filter: blur(var(--panel-blur));
  color: var(--tx);
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
  padding: 0;
}
.fig-ctrl button svg { display: block; }
/* 图框内玻璃按钮：hover/按下 图标提亮到 --accent + 描边 --accent-dim（叠卫星图仍可辨） */
.fig-ctrl button:hover,
.fig-ctrl button:active { color: var(--accent); border-color: var(--accent-dim); }
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
  border: 1px solid var(--glass-line);
  background: var(--scrim);
  backdrop-filter: blur(var(--panel-blur));
  -webkit-backdrop-filter: blur(var(--panel-blur));
  cursor: pointer;
  transition: opacity var(--t-med) var(--ease), border-color var(--t-fast) var(--ease);
  white-space: nowrap;
}
.hs-chip .dot { width: 8px; height: 8px; flex: none; }
.hs-chip[data-t='spawn'] .dot { border-radius: 50%; }
.hs-chip[data-t='extract'] .dot { border-radius: 2px; }
.hs-chip[data-t='loot'] .dot { border-radius: 2px; transform: rotate(45deg) scale(0.9); }
.hs-chip[data-t='boss'] .dot { border-radius: 50%; box-shadow: 0 0 0 2px color-mix(in srgb, var(--hs-boss) 35%, transparent); }
.hs-chip.off { opacity: 0.42; }
.hs-chip.off span { color: var(--faint); }
/* 触屏窄屏：chips 改单行横滚（wrap 两行 390px 实测吃掉约 19% 图框面积）；
   pan-x 放行原生横向滑动（frame 层无 touch-action 封禁），滚动条隐藏与 .pills 同款 */
@media (max-width: 680px) {
  .hs-chips { flex-wrap: nowrap; overflow-x: auto; touch-action: pan-x; scrollbar-width: none; }
  .hs-chips::-webkit-scrollbar { display: none; }
}
/* 图层开关（aria-pressed）：hover/按下（含关态）opacity .8 + 边提亮；
   置于 .off 之后（同特异性靠源码序），保证关态 hover 也能回亮到 .8 */
.hs-chip:hover,
.hs-chip:active { opacity: 0.8; border-color: var(--line-hover); }
.fig-hint {
  position: absolute;
  left: 10px;
  bottom: 10px;
  font-size: var(--fs-2xs);
  font-family: var(--mono);
  letter-spacing: .05em;
  color: var(--tx);
  background: var(--scrim);
  border: 1px solid var(--glass-line);
  backdrop-filter: blur(var(--panel-blur));
  -webkit-backdrop-filter: blur(var(--panel-blur));
  padding: 4px 10px;
  border-radius: var(--radius-sm);
  pointer-events: none;
  opacity: 0;
  transition: opacity var(--t-med) var(--ease);
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
  transition: color var(--t-med) var(--ease), background var(--t-med) var(--ease);
  white-space: nowrap;
}
/* 分段控件（单选）：hover/按下 底 --lift 字 --tx；选中 底 --card2 字 --accent（两件同改） */
.fig-tab:hover,
.fig-tab:active { color: var(--tx); background: var(--lift); }
.fig-tab.on { background: var(--card2); color: var(--accent); }
.fig-cap { font-size: var(--fs-xs); color: var(--faint); line-height: 1.6; min-width: 0; }

@media (prefers-reduced-motion: reduce) {
  .fig-frame, .fig-ctrl button, .hs-chip, .fig-hint, .fig-tab { transition: none; }
}
</style>
