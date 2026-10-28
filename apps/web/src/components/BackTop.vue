<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'

/* 显隐两条互斥路径（前沿思路「滚动驱动动效」的落地，@supports 渐进增强）：
   ① 支持 scroll() 时间线的浏览器：按钮常驻 DOM，显隐全由 CSS 滚动位置驱动
      （见样式区 @supports 块），滚动/回滚时淡入淡出随位置连续擦洗、零 JS 监听；
   ② 不支持的环境（老 Safari 等）：JS 被动 scroll 监听 + v-if 挂载，与原有行为
      完全一致——回退到功能完整的现状而非消失/常显。
   判据只在初始化读一次，两路径不会同时生效 */
const cssScroll =
  typeof CSS !== 'undefined' && CSS.supports('animation-timeline', 'scroll()')

// ① 路径下恒 true（元素常驻，CSS 负责藏）；② 路径下由滚动位置驱动挂载
const show = ref(cssScroll)

const SHOW_AT = 480 // 与 CSS animation-range 起点（480px）同一语义阈值

function onScroll() {
  show.value = window.scrollY > SHOW_AT
}

function toTop() {
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches
  window.scrollTo({ top: 0, behavior: reduced ? 'auto' : 'smooth' })
}

onMounted(() => {
  if (cssScroll) return // CSS 时间线已接管显隐，不再挂 JS 监听
  window.addEventListener('scroll', onScroll, { passive: true })
  onScroll()
})
onBeforeUnmount(() => {
  window.removeEventListener('scroll', onScroll)
})
</script>

<template>
  <transition name="totop">
    <button v-if="show" class="to-top" aria-label="返回顶部" @click="toTop">
      <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
        <path
          d="M3 10l5-5 5 5"
          fill="none"
          stroke="currentColor"
          stroke-width="1.6"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
    </button>
  </transition>
</template>

<style scoped>
.to-top {
  position: fixed;
  /* 悬浮位走间距阶梯 --sp-5（24px）：原 22/26 是阶梯外 ad-hoc 值（base.css:95 禁），
     各挪 2px 肉眼不可辨 */
  right: var(--sp-5);
  bottom: var(--sp-5);
  z-index: var(--z-backtop);
  width: 38px;
  height: 38px;
  display: flex;
  align-items: center;
  justify-content: center;
  border: 1px solid var(--line);
  border-radius: var(--radius);
  background: var(--panel-solid);
  color: var(--dim);
  box-shadow: var(--shadow-sm);
  cursor: pointer;
  /* 缓动统一 --ease（MOTION.md §1-2 唯一缓动家族）；原列表里的 background 项删去——
     hover/active 态都不改背景（恒 --panel-solid），是从未触发的死声明 */
  transition: color var(--t-med) var(--ease), border-color var(--t-med) var(--ease),
    transform var(--t-fast) var(--ease);
}
/* 触达热区外扩 6px（38 → 50px，过 HIG 44pt 下限）：视觉尺寸不变，
   窄屏拇指按压不再要求精准点中；::before 不设背景，纯命中区 */
.to-top::before {
  content: "";
  position: absolute;
  inset: -6px;
}
.to-top:hover {
  color: var(--tx);
  border-color: var(--line-hover);
}
/* 按下态：hover 反馈保持 + 尺寸微缩（全站按钮按压语汇 scale(.98)） */
.to-top:active {
  color: var(--tx);
  border-color: var(--line-hover);
  transform: scale(.98);
}
.totop-enter-active,
.totop-leave-active { transition: opacity var(--t-med) var(--ease), transform var(--t-med) var(--ease); }
.totop-enter-from,
.totop-leave-to {
  opacity: 0;
  transform: translateY(8px);
}

/* ① 路径：scroll() 滚动时间线驱动显隐（根滚动条位置直接映射动画进度，随滚动
   连续擦洗、可逆）。阈值语义与 JS 路径一致：≤480px 进度 0（fill both 反向填充
   0% 帧 = 不可见），480→544px 淡入，之后恒显。keyframes 刻意不含 transform：
   动画填充态在层叠中盖过普通声明，若驱动 transform 会永久压掉 :active 的
   scale(.98) 按压反馈（RM/交互红线）；visibility 参与 = 阈值下按钮不可点、
   也不进 Tab 序，与 v-if 卸载的可达性口径一致 */
@supports (animation-timeline: scroll()) {
  .to-top {
    animation: totop-scrub linear both;
    animation-timeline: scroll();
    animation-range: 480px 544px;
  }
  /* RM：范围收成阈值处的硬切换 = 瞬现瞬隐，无滚动渐变（MOTION.md 原则 5 降级口径） */
  @media (prefers-reduced-motion: reduce) {
    .to-top { animation-range: 479.5px 480.5px; }
  }
}
@keyframes totop-scrub {
  from { opacity: 0; visibility: hidden; }
  to { opacity: 1; visibility: visible; }
}
@media (prefers-reduced-motion: reduce) {
  .to-top, .totop-enter-active, .totop-leave-active { transition: none; }
}
</style>
