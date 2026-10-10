<script setup>
// FxCanvas.vue — WebGPU 特效画布（工程师A，定稿方案中该文件位于 src/components/fx/，
// 为严守「A 独占 src/views/maps/**」的归属边界改放此处，仅地图侧两个消费方引用）。
// mode="hero"：挂载即按 legacy 门链结算 root data-fx（reduced→库→unsupported→on/fallback），
//              IntersectionObserver 可见性泵；mode="lb"：html.locked 驱动惰性首建 +
//              防重入 + 双向 pause/resume 同步（复刻 legacy L1047-1067，含二次打开 resume 分支）。
import { ref, onMounted, onBeforeUnmount } from 'vue'
import { loadShadersLib, build, fx, HERO_PRESET, LB_PRESET, coarsePointer } from './fxLib'

const props = defineProps({
  mode: { type: String, default: 'hero' }, // 'hero' | 'lb'
  canvasId: { type: String, required: true },
})

const canvasRef = ref(null)
let sh = null
let building = false
let vis = true
let io = null
let mo = null
const root = document.documentElement

function pump() {
  if (sh) { (vis && !document.hidden) ? sh.resume() : sh.pause() }
}
function syncLb() {
  if (sh) { (root.classList.contains('locked') && !document.hidden) ? sh.resume() : sh.pause() }
}
function onVis() {
  if (props.mode === 'hero') pump()
  else syncLb()
}

onMounted(() => {
  const canvas = canvasRef.value

  /* §7.1 visibilitychange 修复：注册提至 mode 分流之前（hero 分支 return 之前可达），
     hero/lb 两个实例共享；此前它位于 onMounted 末尾，hero 路径提前 return 永远注册不到，
     pump() 内的 document.hidden 判断只在 IO 事件里被间接触发。
     reduced 早退实例也会注册，但 sh 恒为 null、onVis 为 no-op，卸载时照常移除。 */
  document.addEventListener('visibilitychange', onVis)

  if (props.mode === 'hero') {
    if (window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches) { fx('reduced'); return }
    /* §7.1 coarse pointer：手机 GPU 开销大头在逐像素 Fog detail，不在粒子数——
       粒子降 160、Fog detail 15→10 / speed 0.4→0.3 */
    if (coarsePointer()) {
      HERO_PRESET.components[1].props.count = 160
      HERO_PRESET.components[0].props.detail = 10
      HERO_PRESET.components[0].props.speed = 0.3
    }
    if ('IntersectionObserver' in window) {
      io = new IntersectionObserver((ens) => { vis = ens[0].isIntersecting; pump() }, { threshold: 0 })
      io.observe(canvas.parentElement || canvas)
    }
    loadShadersLib()
      .then((lib) => {
        if (!lib.isWebGPUSupported()) { fx('unsupported'); return }
        if (!canvas) { fx('fallback'); return }
        return build(lib, canvas, HERO_PRESET, true).then((r) => {
          sh = r.sh
          if (r.sh) fx('on')
          else fx(r.why === 'unsupported' ? 'unsupported' : 'fallback')
          pump()
        })
      })
      .catch(() => { fx('fallback') })
    return
  }

  /* mode === 'lb'：reduced 不建（legacy 初始化在 reduced 分支提前 return，lb 永不挂载） */
  if (window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches) return
  const onLockedChange = () => {
    const open = root.classList.contains('locked')
    if (open && !sh && !building) {
      building = true
      loadShadersLib()
        .then((lib) => build(lib, canvas, LB_PRESET, false))
        .then((r) => { sh = r.sh; building = false; syncLb() /* 完成时按当前 locked 决定 pause/resume */ })
        .catch(() => { building = false /* 库加载失败：root fallback 由 hero 实例结算，lb 保持未挂载 */ })
    } else {
      syncLb() /* lbSh 已建成时再次 open 走此分支 resume；build 飞行中重复 open 为 no-op；
                  缺此行 = 二次打开永久静帧（legacy R2/R3 修复点，必须保留） */
    }
  }
  mo = new MutationObserver(onLockedChange)
  mo.observe(root, { attributes: true, attributeFilter: ['class'] })
  /* Vue 懒挂载差异：canvas 与观察器随灯箱首次 open 才就绪，此时 locked 可能已被置位——
     legacy 里两者是静态 DOM、先于任何点击存在，故无需此采样；不补首次采样 = 首开不挂载 */
  if (root.classList.contains('locked')) onLockedChange()
})

onBeforeUnmount(() => {
  if (io) { io.disconnect(); io = null }
  if (mo) { mo.disconnect(); mo = null }
  document.removeEventListener('visibilitychange', onVis)
  if (sh) { try { sh.pause() } catch (e) { /* noop */ } sh = null }
})
</script>

<template>
  <canvas
    :id="canvasId"
    ref="canvasRef"
    class="fx-canvas"
    :class="mode === 'hero' ? 'fx-hero' : 'fx-lb'"
    aria-hidden="true"
  ></canvas>
</template>

<style scoped>
/* legacy CSS L263 追加块中 #fxHero / #fxLb 两条规则（id 换 class，元素 id 保留原值） */
.fx-canvas { display: block; }
.fx-canvas.fx-hero {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  z-index: 0;
  pointer-events: none;
  opacity: 0.8;
}
.fx-canvas.fx-lb {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  pointer-events: none;
  opacity: 0.5;
}
@media (prefers-reduced-motion: reduce) {
  .fx-canvas.fx-hero,
  .fx-canvas.fx-lb { display: none; }
}
</style>
