// useViewer.js — 页内地图查看器（工程师A）
// 自 legacy/index.html L504-753 原样移植（拖拽平移 / 以光标为中心缩放 / 双击与双tap放大 /
// 捏合 / 键盘 +/-/0/方向键 / 1-7x / hotspots 点选 / info card 定位 / 变体切换），
// 仅把 DOM 工厂改为 Vue refs + reactive 状态，交互数学与阈值逐行对应，不重写。
import { reactive } from 'vue'

/** 标注类型中文名与颜色（legacy L630 常量；色值走 base.css 的 --hs-* 语义变量，
 *  内联 style 会以 var() 写入，随之令牌统一变更） */
export const HS_TYPES = { spawn: '出生', extract: '撤离', boss: 'Boss', loot: '物资' }
export const HS_TCOL = { spawn: 'var(--hs-spawn)', extract: 'var(--hs-extract)', boss: 'var(--hs-boss)', loot: 'var(--hs-loot)' }

/**
 * @param {object} opts
 * @param {object}   opts.map    地图视图模型（mapIndex.js 元素，含 fig/hs/loot/guide）
 * @param {import('vue').Ref} opts.vp     .fig-vp 视口元素
 * @param {import('vue').Ref} opts.frame  .fig-frame 元素（键盘焦点宿主）
 * @param {import('vue').Ref} opts.plane  .fig-plane 变换平面
 * @param {import('vue').Ref} opts.img    底图 img
 * @param {import('vue').Ref} opts.card   info card 根元素（.hs-card）
 * @param {(idx: number) => void} opts.onFull 全屏按钮回调（打开 Lightbox）
 */
export function createViewer({ map, vp, frame, plane, img, card, onFull }) {
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches

  /* 模板需要的响应式状态：当前变体、激活标注索引、信息卡定位 */
  const state = reactive({ cur: 0, active: -1, cardLeft: 0, cardTop: 0 })

  /* ---- viewer state（legacy L507-510 同名同义） ---- */
  let s = 1, tx = 0, ty = 0, pw = 1, ph = 1, fw = 1, fh = 1
  const MIN = 1, MAX = 7

  function measure() {
    const r = vp.value.getBoundingClientRect()
    fw = r.width || 1; fh = r.height || 1
    pw = plane.value.offsetWidth || 1; ph = plane.value.offsetHeight || 1
  }
  function clampT() {
    const minX = Math.min(0, fw - pw * s), maxX = Math.max(0, fw - pw * s)
    const minY = Math.min(0, fh - ph * s), maxY = Math.max(0, fh - ph * s)
    tx = Math.min(maxX, Math.max(minX, tx))
    ty = Math.min(maxY, Math.max(minY, ty))
  }
  function apply(anim) {
    const el = plane.value
    el.style.transition = (anim && !reduced) ? 'transform .3s cubic-bezier(.22,.61,.36,1)' : 'none'
    el.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + s + ')'
    el.style.setProperty('--inv', Math.max(0.45, 1 / s).toFixed(3))
    positionCard()
  }
  function zoomAbs(cx, cy, ns, anim) {
    ns = Math.min(MAX, Math.max(MIN, ns))
    if (ns === s) return
    const px = (cx - tx) / s, py = (cy - ty) / s
    s = ns; tx = cx - px * s; ty = cy - py * s
    if (s <= MIN + 0.001) { s = MIN; tx = 0; ty = 0 }
    clampT(); apply(anim)
  }
  function reset(anim) { s = 1; tx = 0; ty = 0; apply(anim) }
  function inVpPoint(e) { const r = vp.value.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top } }
  function nextLevel(cx, cy) {
    if (s < 1.05) zoomAbs(cx, cy, 2, true)
    else if (s * 1.6 > MAX) reset(true)
    else zoomAbs(cx, cy, s * 1.6, true)
  }

  /* ---- pointers: drag / pinch / tap（legacy L546-614） ---- */
  const ptrs = new Map()
  let pinch = null, moved = 0, downOn = null, lastTap = 0, tapPos = null, lastTapZoom = 0

  function onPointerDown(e) {
    if (e.target.closest('.hs-card') || e.target.closest('.fig-ctrl') || e.target.closest('.hs-chips')) return
    try { vp.value.setPointerCapture(e.pointerId) } catch (err) { /* noop */ }
    ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY })
    moved = 0; downOn = e.target
    if (ptrs.size === 1) vp.value.classList.add('dragging')
    if (ptrs.size === 2) {
      const pts = []
      ptrs.forEach((p) => pts.push(p))
      pinch = { d: Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y) || 1, s }
    }
    e.preventDefault()
  }
  function onPointerMove(e) {
    if (!ptrs.has(e.pointerId)) return
    const p = ptrs.get(e.pointerId)
    const dx = e.clientX - p.x, dy = e.clientY - p.y
    p.x = e.clientX; p.y = e.clientY
    moved += Math.abs(dx) + Math.abs(dy)
    if (ptrs.size === 1 && s >= 1) {
      tx += dx; ty += dy; clampT(); apply(false)
    } else if (ptrs.size === 2 && pinch) {
      const pts = []; ptrs.forEach((q) => pts.push(q))
      const d = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y) || 1
      const mid = inVpPoint(e)
      mid.x = (pts[0].x + pts[1].x) / 2 - vp.value.getBoundingClientRect().left
      mid.y = (pts[0].y + pts[1].y) / 2 - vp.value.getBoundingClientRect().top
      zoomAbs(mid.x, mid.y, pinch.s * d / pinch.d, false)
    }
  }
  function ptrEnd(e) {
    if (!ptrs.has(e.pointerId)) return
    ptrs.delete(e.pointerId)
    if (ptrs.size < 2) pinch = null
    if (ptrs.size === 0) {
      vp.value.classList.remove('dragging')
      if (moved < 8) {
        const hsBtn = downOn && downOn.closest ? downOn.closest('.hs') : null
        if (hsBtn) openCard(+hsBtn.dataset.i)
        /* tap 命中标注只开卡、不进 tap-pair 记账：消除「连点开卡+画面跳 2x」叠加 */
        else {
          closeCard()
          const now = Date.now()
          const pt = inVpPoint(e)
          if (now - lastTap < 350 && tapPos && Math.hypot(pt.x - tapPos.x, pt.y - tapPos.y) < 40) {
            nextLevel(pt.x, pt.y); lastTap = 0; lastTapZoom = now
          } else { lastTap = now; tapPos = pt }
        }
      }
      downOn = null
    }
  }
  function onWheel(e) {
    e.preventDefault()
    const pt = inVpPoint(e)
    zoomAbs(pt.x, pt.y, s * Math.exp(-e.deltaY * 0.0016), false)
  }
  function onDblClick(e) {
    if (e.target.closest('.hs-card') || e.target.closest('.fig-ctrl') || e.target.closest('.hs-chips')) return
    if (e.target.closest('.hs')) return /* 双击标注＝开卡动作，跳过放大（与 tap 路径同口径） */
    if (Date.now() - lastTapZoom < 500) return /* tap-pair 刚已放大过一次，原生 dblclick 去重 */
    const pt = inVpPoint(e)
    nextLevel(pt.x, pt.y)
  }

  /* ---- keyboard（legacy L616-631，frame 宿主） ---- */
  function onKey(e) {
    const k = e.key
    if (k === '+' || k === '=') { zoomAbs(fw / 2, fh / 2, s * 1.35, true); e.preventDefault() }
    else if (k === '-') { zoomAbs(fw / 2, fh / 2, s / 1.35, true); e.preventDefault() }
    else if (k === '0') { reset(true); e.preventDefault() }
    else if (k === 'Escape' && state.active >= 0) { closeCard() }
    else if (k.indexOf('Arrow') === 0 && s > 1.02) {
      if (k === 'ArrowLeft') tx += 60
      if (k === 'ArrowRight') tx -= 60
      if (k === 'ArrowUp') ty += 60
      if (k === 'ArrowDown') ty -= 60
      clampT(); apply(true); e.preventDefault()
    }
  }

  /* ---- ctrl buttons（legacy L633-640；full 走 onFull 回调开灯箱） ---- */
  function zoomIn() { zoomAbs(fw / 2, fh / 2, s * 1.45, true) }
  function zoomOut() { zoomAbs(fw / 2, fh / 2, s / 1.45, true) }

  function onResize() { measure(); clampT(); apply(false) }

  /* ---- info card（legacy L667-715） ---- */
  function openCard(i) {
    state.active = i
    state.cardLeft = 0; state.cardTop = 0
    positionCard()
  }
  function positionCard() {
    if (state.active < 0 || !card.value) return
    const sp = map.hs[state.active]
    const x = tx + s * sp.x * pw, y = ty + s * sp.y * ph
    const w = card.value.offsetWidth, h = card.value.offsetHeight
    let cx = x + 14
    if (cx + w > fw - 8) cx = x - w - 14
    cx = Math.min(fw - w - 8, Math.max(8, cx))
    const cy = Math.min(fh - h - 8, Math.max(8, y - h / 2))
    state.cardLeft = cx; state.cardTop = cy
  }
  function closeCard() { state.active = -1 }
  /** 图层开关关闭某类型时，若激活卡正是该类型则收起（legacy chips L659-663 行为） */
  function closeCardIfType(t) {
    if (state.active >= 0 && map.hs[state.active].type === t) closeCard()
  }

  /* ---- variants（legacy L734-751；src/alt/cap/图层可见性由模板按 cur 计算） ---- */
  function setVariant(i) {
    state.cur = i
    closeCard()
    reset(false)
  }
  /** img @load：静态 w/h 缺失时才兜底写 frame 宽高比（常规路径由模板 :style 预置，
      此处直写会与 Vue 样式绑定互踩），重测量逻辑保留（legacy L745-751） */
  function onImgLoad() {
    const el = img.value
    if (el && el.naturalWidth) {
      const f = map.fig[state.cur]
      if (!f.w || !f.h) frame.value.style.aspectRatio = el.naturalWidth + ' / ' + el.naturalHeight
      measure(); clampT(); apply(false)
    }
  }

  /* ---- 事件绑定（Vue onMounted 调 attach，onBeforeUnmount 调 detach） ---- */
  function attach() {
    const v = vp.value
    v.addEventListener('pointerdown', onPointerDown)
    v.addEventListener('pointermove', onPointerMove)
    v.addEventListener('pointerup', ptrEnd)
    v.addEventListener('pointercancel', ptrEnd)
    v.addEventListener('wheel', onWheel, { passive: false })
    v.addEventListener('dblclick', onDblClick)
    window.addEventListener('resize', onResize)
  }
  function detach() {
    const v = vp.value
    if (v) {
      v.removeEventListener('pointerdown', onPointerDown)
      v.removeEventListener('pointermove', onPointerMove)
      v.removeEventListener('pointerup', ptrEnd)
      v.removeEventListener('pointercancel', ptrEnd)
      v.removeEventListener('wheel', onWheel)
      v.removeEventListener('dblclick', onDblClick)
    }
    window.removeEventListener('resize', onResize)
  }

  return {
    state, TYPES: HS_TYPES, TCOL: HS_TCOL,
    attach, detach,
    setVariant, onImgLoad, onKey,
    zoomIn, zoomOut,
    resetView: () => reset(true),
    openCard, closeCard, closeCardIfType, positionCard,
  }
}
