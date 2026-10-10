// useReveal.js — 入场渐显（工程师A）
// 移植 legacy L840-854 setupReveal：IntersectionObserver 进入视口加 .in（阈值 0.05，
// rootMargin 底部 -4%），reduced-motion 或无 IO 时直接全量显示。
// §7.3：容器级 .reveal-group 与普通 .reveal 同被观察——子项不挂 .reveal，
// 筛选/切图重建的子项在容器已 .in 前提下自动播放入场，无 observe 死角。
import { onBeforeUnmount } from 'vue'

export function useReveal() {
  let ro = null

  function observeRoot(root) {
    if (!root) return
    const els = root.querySelectorAll('.reveal:not(.in), .reveal-group:not(.in)')
    if (!els.length) return
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    if ('IntersectionObserver' in window && !reduced) {
      if (!ro) {
        ro = new IntersectionObserver((entries) => {
          entries.forEach((en) => {
            if (en.isIntersecting) { en.target.classList.add('in'); ro.unobserve(en.target) }
          })
        }, { threshold: 0.05, rootMargin: '0px 0px -4% 0px' })
      }
      els.forEach((n) => ro.observe(n))
    } else {
      els.forEach((n) => n.classList.add('in'))
    }
  }

  function disconnect() {
    if (ro) { ro.disconnect(); ro = null }
  }

  onBeforeUnmount(disconnect)

  return { observeRoot, disconnect }
}
