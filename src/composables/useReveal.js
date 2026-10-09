// useReveal.js — 入场渐显（工程师A）
// 移植 legacy L840-854 setupReveal：IntersectionObserver 进入视口加 .in（阈值 0.05，
// rootMargin 底部 -4%），reduced-motion 或无 IO 时直接全量显示；rescan() 供
// /tactics 切换地图后对新渲染的 .reveal 元素重新观察。
import { onBeforeUnmount } from 'vue'

export function useReveal() {
  let ro = null

  function observeRoot(root) {
    if (!root) return
    const els = root.querySelectorAll('.reveal:not(.in)')
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
