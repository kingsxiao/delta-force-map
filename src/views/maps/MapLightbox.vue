<script setup>
// MapLightbox.vue — 全屏灯箱（工程师A）：legacy L855-987 Lightbox 的 Vue 版，Teleport 全局单例。
// 硬契约（scripts/verify-effects.mjs 依赖，勿改）：
//   - 打开时 documentElement 加 locked 类、关闭时移除（legacy open L912 / close L929 的加删）；
//   - id 原名保留：lb / lbBackdrop / lbStage / lbImg / lbTitle / lbPct / lbIn / lbOut / lbFit / lbClose / lbTabs；
//   - #fxLb 特效画布置于 lbBackdrop 内，由 FxCanvas(mode="lb") 随 locked 惰性挂载。
// 交互不缩水：滚轮以光标为中心缩放(1-8x)、拖拽平移、双击 1x/2.5x、+/-/0/方向键/ESC、变体 tabs。
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import FxCanvas from './FxCanvas.vue'

const props = defineProps({
  open: { type: Boolean, default: false },
  map: { type: Object, default: null },
  startIdx: { type: Number, default: 0 },
})
const emit = defineEmits(['close'])

const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches

const stageRef = ref(null)
const imgRef = ref(null)
const closeRef = ref(null)

const visible = ref(false) // 控 [hidden]（延迟 220ms 落位，保退出过渡）
const shown = ref(false) // 控 .show 透明度过渡
const idx = ref(0)
const pct = ref('100%')
const grabbing = ref(false)

/* imperative viewer state（legacy L857-859 同名同义） */
let scale = 1, tx = 0, ty = 0, baseW = 1, baseH = 1
let openState = false, dragging = false, lastX = 0, lastY = 0, moved = 0
let hideTimer = null

const titleText = computed(() => (props.map ? props.map.map + ' · ' + props.map.fig[idx.value].label : ''))

function clampPan() {
  const maxX = Math.max(0, (baseW * scale - stageRef.value.clientWidth) / 2)
  const maxY = Math.max(0, (baseH * scale - stageRef.value.clientHeight) / 2)
  tx = Math.min(maxX, Math.max(-maxX, tx))
  ty = Math.min(maxY, Math.max(-maxY, ty))
}
function apply(anim) {
  const img = imgRef.value
  img.classList.toggle('noanim', !anim)
  clampPan()
  img.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')'
  pct.value = Math.round(scale * 100) + '%'
}
function zoomAt(cx, cy, factor, anim) {
  const ns = Math.min(8, Math.max(1, scale * factor))
  if (ns === scale) return
  const qx = (cx - tx) / scale, qy = (cy - ty) / scale
  scale = ns
  tx = cx - qx * scale; ty = cy - qy * scale
  if (scale === 1) { tx = 0; ty = 0 }
  apply(anim)
}
function stagePoint(e) {
  const r = stageRef.value.getBoundingClientRect()
  return { x: e.clientX - r.left - r.width / 2, y: e.clientY - r.top - r.height / 2 }
}
function measure() {
  baseW = imgRef.value.offsetWidth || 1
  baseH = imgRef.value.offsetHeight || 1
}

function setVariant(i, keepZoom) {
  idx.value = i
  if (!keepZoom) { scale = 1; tx = 0; ty = 0 }
  /* src 绑定在下一次 flush 落地；已缓存的图直接测量（legacy img.complete 分支） */
  nextTick(() => {
    const el = imgRef.value
    if (el && el.complete && el.naturalWidth) { measure(); apply(false) }
  })
}

function switchVariant(i) {
  scale = 1; tx = 0; ty = 0
  setVariant(i, false)
}

function onImgLoad() {
  if (!openState) return
  measure(); apply(false)
}

/* ---- open / close（locked 类的加删是 verify 硬判据） ---- */
watch(
  () => props.open,
  (v) => (v ? doOpen() : doClose()),
  { flush: 'post' },
)

function doOpen() {
  openState = true
  idx.value = props.startIdx || 0
  visible.value = true
  document.documentElement.classList.add('locked')
  requestAnimationFrame(() => { shown.value = true })
  scale = 1; tx = 0; ty = 0
  setVariant(idx.value, false)
  /* open animation: start slightly small, then ease to 1（legacy L917-923） */
  if (!reduced) {
    const img = imgRef.value
    img.classList.add('noanim')
    img.style.transform = 'translate(0px,0px) scale(.955)'
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (openState && scale === 1) apply(true)
    }))
  }
  nextTick(() => { if (closeRef.value) closeRef.value.focus() })
}
function doClose() {
  openState = false
  shown.value = false
  document.documentElement.classList.remove('locked')
  clearTimeout(hideTimer)
  hideTimer = setTimeout(() => { visible.value = false }, reduced ? 0 : 220)
}
function requestClose() {
  emit('close')
}

/* ---- 指针 / 滚轮 / 双击（legacy L931-975） ---- */
function onWheel(e) {
  if (!openState) return
  e.preventDefault()
  const p = stagePoint(e)
  zoomAt(p.x, p.y, Math.exp(-e.deltaY * 0.0016), false)
}
function onDown(e) {
  if (!openState) return
  dragging = true; moved = 0; lastX = e.clientX; lastY = e.clientY
  try { imgRef.value.setPointerCapture(e.pointerId) } catch (err) { /* noop */ }
  grabbing.value = true
}
function onMove(e) {
  if (!dragging) return
  const dx = e.clientX - lastX, dy = e.clientY - lastY
  moved += Math.abs(dx) + Math.abs(dy)
  lastX = e.clientX; lastY = e.clientY
  tx += dx; ty += dy
  apply(false)
}
function onUp() {
  dragging = false
  grabbing.value = false
}
function onDbl(e) {
  const p = stagePoint(e)
  if (scale > 1.15) { scale = 1; tx = 0; ty = 0; apply(true) }
  else zoomAt(p.x, p.y, 2.5 / scale, true)
}
function zoomInCenter() { zoomAt(0, 0, 1.45, true) }
function zoomOutCenter() { zoomAt(0, 0, 1 / 1.45, true) }
function fit() { scale = 1; tx = 0; ty = 0; apply(true) }

function onKey(e) {
  if (!openState) return
  if (e.key === 'Escape') requestClose()
  else if (e.key === '+' || e.key === '=') zoomAt(0, 0, 1.45, true)
  else if (e.key === '-') zoomAt(0, 0, 1 / 1.45, true)
  else if (e.key === '0') { scale = 1; tx = 0; ty = 0; apply(true) }
  else if (e.key.startsWith('Arrow') && scale > 1) {
    const step = 60
    if (e.key === 'ArrowLeft') tx += step
    if (e.key === 'ArrowRight') tx -= step
    if (e.key === 'ArrowUp') ty += step
    if (e.key === 'ArrowDown') ty -= step
    apply(true)
    e.preventDefault()
  }
}
function onResize() {
  if (openState) { measure(); apply(false) }
}

onMounted(() => {
  document.addEventListener('keydown', onKey)
  window.addEventListener('resize', onResize)
})
onBeforeUnmount(() => {
  document.removeEventListener('keydown', onKey)
  window.removeEventListener('resize', onResize)
  if (openState) document.documentElement.classList.remove('locked')
  clearTimeout(hideTimer)
})
</script>

<template>
  <Teleport to="body">
    <div
      v-if="map"
      id="lb"
      class="lb"
      :class="{ show: shown }"
      :hidden="!visible"
      role="dialog"
      aria-modal="true"
      aria-label="放大查看"
    >
      <div id="lbBackdrop" class="lb-backdrop" @click="requestClose">
        <FxCanvas mode="lb" canvas-id="fxLb" />
      </div>

      <figure id="lbStage" ref="stageRef" class="lb-stage">
        <img
          id="lbImg"
          ref="imgRef"
          class="lb-img"
          :class="{ grabbing }"
          :src="map.fig[idx].src"
          :alt="titleText"
          draggable="false"
          @load="onImgLoad"
          @pointerdown="onDown"
          @pointermove="onMove"
          @pointerup="onUp"
          @pointercancel="onUp"
          @dblclick="onDbl"
        >
      </figure>

      <header class="lb-top">
        <div id="lbTitle" class="lb-title">{{ titleText }}</div>
        <!-- §5.6 工具条合并：一个容器统一 backdrop 采样（--scrim + blur(--panel-blur)），
             按钮本体与 id（lbOut/lbIn/lbFit/lbClose）不动；字符图标换 SVG（§5.3） -->
        <div class="lb-tools">
          <button id="lbOut" class="lb-btn" aria-label="缩小" @click="zoomOutCenter">
            <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
              <path d="M3 8h10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
            </svg>
          </button>
          <span id="lbPct" class="lb-pct">{{ pct }}</span>
          <button id="lbIn" class="lb-btn" aria-label="放大" @click="zoomInCenter">
            <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
              <path d="M3 8h10M8 3v10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
            </svg>
          </button>
          <button id="lbFit" class="lb-btn lb-btn-fit" aria-label="复位" @click="fit">复位</button>
          <button id="lbClose" ref="closeRef" class="lb-btn" aria-label="关闭 (ESC)" @click="requestClose">
            <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
              <path d="M3.5 3.5l9 9M12.5 3.5l-9 9" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
            </svg>
          </button>
        </div>
      </header>

      <div id="lbTabs" class="lb-tabs">
        <button
          v-for="(f, i) in map.fig"
          :key="i"
          type="button"
          class="lb-tab"
          :class="{ on: i === idx }"
          @click="switchVariant(i)"
        >
          {{ f.label }}
        </button>
      </div>

      <p class="lb-hint">滚轮缩放 · 拖拽平移 · 双击 1x/2.5x · ESC 关闭</p>
    </div>
  </Teleport>
</template>

<style scoped>
/* legacy CSS L230-252（lightbox），取值令牌化 */
.lb { position: fixed; inset: 0; z-index: var(--z-lightbox); opacity: 0; transition: opacity var(--t-slow) ease; }
.lb.show { opacity: 1; }
.lb[hidden] { display: none; }
.lb-backdrop { position: absolute; inset: 0; background: rgba(4, 6, 8, 0.94); }
.lb-stage {
  position: absolute;
  inset: 0;
  margin: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
  pointer-events: none;
}
.lb-img {
  pointer-events: auto;
  max-width: 94vw;
  max-height: 86vh;
  width: auto;
  height: auto;
  cursor: grab;
  will-change: transform;
  transition: transform 0.3s var(--ease);
  border-radius: var(--radius-sm);
  box-shadow: 0 10px 70px rgba(0, 0, 0, 0.55);
}
.lb-img.noanim { transition: none; }
.lb-img.grabbing { cursor: grabbing; }
.lb-top {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 14px;
  padding: 14px 18px;
  pointer-events: none;
}
.lb-title { font-size: var(--fs-sm); color: var(--dim); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
/* §5.6 工具条容器：一次 backdrop 采样（--scrim + 唯一 blur 值 --panel-blur）+ --shadow-sm */
.lb-tools {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  pointer-events: auto;
  flex: none;
  padding: 4px;
  border: 1px solid var(--line);
  border-radius: var(--radius-pill);
  background: var(--scrim);
  backdrop-filter: blur(var(--panel-blur));
  -webkit-backdrop-filter: blur(var(--panel-blur));
  box-shadow: var(--shadow-sm);
}
.lb-btn {
  width: 32px;
  height: 32px;
  border: 0;
  border-radius: var(--radius);
  background: none;
  color: var(--dim);
  font-size: var(--fs-2xs);
  line-height: 1;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: color var(--t-med), background var(--t-med);
  padding: 0;
}
.lb-btn svg { display: block; }
.lb-btn:hover { color: var(--tx); background: var(--lift); }
.lb-btn-fit { width: auto; padding: 0 10px; letter-spacing: .06em; }
.lb-pct { font-family: var(--mono); font-size: var(--fs-2xs); color: var(--faint); min-width: 46px; text-align: center; }
.lb-tabs {
  position: absolute;
  bottom: 20px;
  left: 50%;
  transform: translateX(-50%);
  display: flex;
  gap: 3px;
  background: var(--scrim);
  backdrop-filter: blur(var(--panel-blur));
  -webkit-backdrop-filter: blur(var(--panel-blur));
  border: 1px solid var(--line);
  border-radius: var(--radius-pill);
  box-shadow: var(--shadow-sm);
  padding: 4px;
  max-width: 92vw;
  overflow-x: auto;
  scrollbar-width: none;
}
.lb-tabs::-webkit-scrollbar { display: none; }
.lb-tab {
  flex: none;
  border: 0;
  background: none;
  color: var(--dim);
  font-size: var(--fs-xs);
  padding: 6px 15px;
  border-radius: var(--radius-pill);
  cursor: pointer;
  transition: color var(--t-med), background var(--t-med);
  white-space: nowrap;
}
.lb-tab:hover { color: var(--tx); }
.lb-tab.on { background: var(--accent-bg); color: var(--accent); }
.lb-hint {
  position: absolute;
  bottom: 22px;
  left: 20px;
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  color: var(--faint);
  pointer-events: none;
}
@media (max-width: 680px) {
  .lb-hint { display: none; }
  .lb-title { font-size: var(--fs-xs); }
}
@media (prefers-reduced-motion: reduce) {
  .lb { transition: none; }
  .lb-img { transition: none; }
}
</style>
