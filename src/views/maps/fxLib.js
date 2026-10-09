// fxLib.js — WebGPU 特效库加载器 + 预设 + 构建状态机（工程师A）
// 复刻 legacy index.html L997-1075 初始化 IIFE 的核心逻辑：
//   reduced → 库缺失 → unsupported → build 成功 on / onError 纠正 fallback。
// 加载机制说明：src/vendor/shaders.iife.js 是经典 IIFE（`var ShadersLib = (...)()`），
// 无任何 export——若按 ESM `import()`，顶层 var 是模块私有，拿不到库对象（window.ShadersLib
// 永远不会被写入，降级分支必然失真）；实测 `?url` 对 src 下 .js 会被 Vite 静默丢弃 import
// （运行时 ReferenceError → 永远 fallback）。因此用 `new URL(..., import.meta.url)` 取
// 资源地址（dev 解析为源路径、build 重写为哈希资产）后动态注入 <script> 经典脚本：
// 与 legacy 同一执行语义（window.ShadersLib 就位）、同样懒加载（库不进主包、仅地图页
// 首次挂载时拉取）、onerror 即 reject → 调用方置 data-fx='fallback'（仍在
// verify-effects.mjs TERMINAL_FX 终态集合内，不白屏）。

const libUrl = new URL('../../vendor/shaders.iife.js', import.meta.url).href

let libPromise = null

export function loadShadersLib() {
  if (typeof window !== 'undefined' && window.ShadersLib && typeof window.ShadersLib.createShader === 'function') {
    return Promise.resolve(window.ShadersLib)
  }
  if (!libPromise) {
    libPromise = new Promise((resolve, reject) => {
      const el = document.createElement('script')
      el.src = libUrl
      el.async = true
      el.onload = () => {
        if (window.ShadersLib && typeof window.ShadersLib.createShader === 'function') resolve(window.ShadersLib)
        else { libPromise = null; reject(new Error('shaders.iife.js loaded but window.ShadersLib unavailable')) }
      }
      el.onerror = () => { libPromise = null; el.remove(); reject(new Error('shaders.iife.js failed to load')) }
      document.head.appendChild(el)
    })
  }
  return libPromise
}

/** root data-fx 单写（仅 hero 路径调用） */
export function fx(s) {
  try { document.documentElement.setAttribute('data-fx', s) } catch (e) { /* noop */ }
}

export function markOff(canvas) {
  try { canvas.style.display = 'none'; canvas.setAttribute('data-fx', 'off') } catch (e) { /* noop */ }
}

/** legacy build()（L1029-1042）原样：resolve null / 失败原因均不得误标 on */
export function build(lib, canvas, preset, isHero) {
  return lib.getWebGPUSupport().then((sup) => {
    if (!sup || !sup.supported) return { sh: null, why: 'unsupported' /* 交调用方结算 */ }
    return lib.createShader(canvas, preset, {
      disableTelemetry: true,
      onError: () => { markOff(canvas); if (isHero) fx('fallback') /* 终态纠正，唯一后期 root 写入 */ },
    }).then((sh) => {
      /* 加固：库若 resolve null（不 reject 也不触发 onError 的理论路径），不得误标 data-fx='on' */
      if (!sh || sh.getFailureReason()) {
        markOff(canvas)
        return { sh: null, why: sh ? 'failed:' + sh.getFailureReason() : 'null-resolved' }
      }
      canvas.setAttribute('data-fx', 'on')
      return { sh, why: null }
    })
  }).catch(() => { markOff(canvas); return { sh: null, why: 'error' } })
}

export const HERO_PRESET = { components: [
  { type: 'Fog', id: 'fx-fog', props: { colorA: '#1c2127', colorB: '#39424d', speed: 0.6, turbulence: 1.2, detail: 15, blending: 0.3, mouseInfluence: 0 } },
  { type: 'FloatingParticles', id: 'fx-dust', props: { particleColor: '#2dd4bf', count: 600, particleSize: 1.4, speed: 0.22, angle: 90, speedVariance: 0.3, angleVariance: 30, randomness: 0.25, twinkle: 0.6, cursorStrength: 0 } },
] }

export const LB_PRESET = { components: [
  { type: 'Fog', id: 'fx-lbfog', props: { colorA: '#05070a', colorB: '#141a21', speed: 0.35, turbulence: 0.8, detail: 10, blending: 0.5, mouseInfluence: 0 } },
  { type: 'FilmGrain', id: 'fx-grain', props: { strength: 0.28, bias: 2.5, animated: true } },
] }

export function coarsePointer() {
  return typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches
}
