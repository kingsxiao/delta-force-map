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

/* 背景特效 v3：用户反馈旧 Fog+FloatingParticles「太丑」——灰雾呆板、300 个静态小圆点无生气。
   换库内两件更高级的组件（同一 2.56MB 库，无新增依赖）：
   - Aurora：极光帘做氛围底。三色压进站点暗青蓝域（帘脚深青 #0f3d4a / 亮核唯一主色
     --accent #2dd4bf / 射线尖钢蓝 #1c5d8f），intensity 45（默认 80）退成夜空微光不抢文案，
     speed 5→2.5 慢漂，帘层 4→3 省一档 compileTime 分支。
   - ParticleFlow：真·不可压流体场驱动的尘埃（替代 FloatingParticles 的匀速漂浮）。shape
     comet 柔光彗星形；静息色青 #8fd8cf、加速色暖金 #ffd98e——鼠标划过（库监听 window
     mousemove，canvas pointer-events:none 不影响）犁出尾流，尘埃卷入涡旋并短暂闪暖光。
     count 6000→4000 桌面兼顾 GPU，swirl 30+momentum .65 让涡旋久转，ambient .2 保证无鼠标
     时画面也在呼吸（lbAlive 逐帧像素断言同样依赖这点）。 */
export const HERO_PRESET = { components: [
  { type: 'Aurora', id: 'fx-aurora', props: { colorA: '#0f3d4a', colorB: '#2dd4bf', colorC: '#1c5d8f', intensity: 45, speed: 2.5, curtainCount: 3, waviness: 60, rayDensity: 22, height: 130, seed: 7 } },
  { type: 'ParticleFlow', id: 'fx-dust', props: { shape: 'comet', colorA: '#8fd8cf', colorB: '#ffd98e', count: 4000, size: 1.1, trails: 0.2, speed: 0.8, force: 1.2, swirl: 30, momentum: 0.65, ambient: 0.2 } },
] }

/* 设计规范 v2.2 §7.2 曾删 Fog 只留 FilmGrain（strength 0.28→0.2）——实测（2026-10-10，
   真浏览器同参对拍）FilmGrain 单组件即使 animated:true，toDataURL 逐帧比对也逐像素静止
   （近纯色、PNG 高度可压），verify-effects.mjs 的 lbAlive 像素断言必挂；Fog 单组件同条件下
   逐帧变化。故恢复 legacy L1019 的近黑双色 Fog 作为唯一动画源（斑驳感≈0，仅提供逐帧变化），
   FilmGrain 维持 v2.2 的 strength 0.2。 */
export const LB_PRESET = { components: [
  { type: 'Fog', id: 'fx-lbfog', props: { colorA: '#05070a', colorB: '#141a21', speed: 0.35, turbulence: 0.8, detail: 10, blending: 0.5, mouseInfluence: 0 } },
  { type: 'FilmGrain', id: 'fx-grain', props: { strength: 0.2, bias: 2.5, animated: true } },
] }

export function coarsePointer() {
  return typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches
}
