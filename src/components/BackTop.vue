<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'

// 返回顶部按钮：滚动超过一屏后出现（沿袭 legacy #toTop 语义）
const show = ref(false)

function onScroll() {
  show.value = window.scrollY > 480
}

function toTop() {
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches
  window.scrollTo({ top: 0, behavior: reduced ? 'auto' : 'smooth' })
}

onMounted(() => {
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
  right: 22px;
  bottom: 26px;
  z-index: var(--z-backtop);
  width: 38px;
  height: 38px;
  display: flex;
  align-items: center;
  justify-content: center;
  border: 1px solid var(--line);
  border-radius: var(--radius);
  background: var(--card2);
  color: var(--dim);
  cursor: pointer;
  transition: color .18s, border-color .18s, background .18s;
}
.to-top:hover {
  color: var(--accent);
  border-color: var(--accent-dim);
}
.totop-enter-active,
.totop-leave-active { transition: opacity .2s, transform .2s; }
.totop-enter-from,
.totop-leave-to {
  opacity: 0;
  transform: translateY(8px);
}
@media (prefers-reduced-motion: reduce) {
  .to-top, .totop-enter-active, .totop-leave-active { transition: none; }
}
</style>
