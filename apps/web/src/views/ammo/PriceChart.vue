<script setup>
/* PriceChart — 展开行内的 7 天价格大图：折线 + P25/P75 分位虚线 + 官方均价参考线 + 当前点
   curve: [["202610061100", 755], ...]（时间升序）
   分位标注挂在各自线的左端（x=PAD.l+4、start 对齐），与右缘「现在」标注错位；
   纵向经 pickY 防撞：避让三条 Y 轴刻度基线、两条 X 轴时间标签基线与已落位的标注 */
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'

const props = defineProps({
  curve: { type: Array, default: () => [] },
  p25: { type: Number, default: null },
  p75: { type: Number, default: null },
  current: { type: Number, default: null },
  /* 官方均价（腾讯 AMS 对账口径，旁路参照不进信号）：null = 无锚不画线 */
  official: { type: Number, default: null },
})

const H = 200
const PAD = { l: 46, r: 14, t: 12, b: 26 }

/* ---------- 绘图基准宽自适应（子弹/雷达双页共用，props 不变） ----------
   固定 680 基准等比缩放时，<680px 容器下刻度/标注文字会等比缩到 ~6px 难读。
   按容器实际宽选基准：≥680 用 680 基准（更宽容器仍由样式 max-width:900px
   封顶放大）；窄容器用容器实际宽（下限 400 兜底超窄屏）——viewBox 宽 ≈
   渲染宽，缩放比恒 ≈1，文字保持像素级大小稳定。容器宽经 ResizeObserver 跟踪。 */
const W_BASE = 680
const W_MIN = 400
const hostRef = ref(null)
const boxW = ref(0)
let ro = null
onMounted(() => {
  const el = hostRef.value
  if (!el) return // curve 不足 2 点时只渲染空态 <p>，无需探测（双页曲线静态，空态不回翻）
  boxW.value = el.clientWidth
  ro = new ResizeObserver((entries) => {
    for (const e of entries) boxW.value = e.contentRect.width
  })
  ro.observe(el)
})
onBeforeUnmount(() => { if (ro) ro.disconnect() })
const W = computed(() => Math.round(Math.min(Math.max(boxW.value || W_BASE, W_MIN), W_BASE)))

/* 首尾/查值时间标签（YYYYMMDDHHmm → MM-DD HH:mm；kkrb 小时档键分钟位为 00，显示不变）。
   提到顶层供 geo 与查值读数共用（原在 geo computed 内部，查值层也要格式化） */
const fmtTs = (ts) => `${ts.slice(4, 6)}-${ts.slice(6, 8)} ${ts.slice(8, 10)}:${ts.slice(10, 12) || '00'}`

/* 图内数字千分位：Y 轴刻度 / 分位标注 / 「现在」标注共用——原先图内裸
   Math.round 无千分位，同一价位在读数条（12,345）与图内（12345）两种写法
   并存；大数扫读靠分节，统一走读数条同款 toLocaleString */
const fmtN = (n) => Math.round(n).toLocaleString('zh-CN')

const geo = computed(() => {
  const pts = props.curve.filter(([, v]) => Number.isFinite(v) && v > 0)
  if (pts.length < 2) return null
  const w = W.value
  const vals = pts.map(([, v]) => v)
  const extras = [props.p25, props.p75, props.official].filter((v) => Number.isFinite(v))
  const min = Math.min(...vals, ...extras)
  const max = Math.max(...vals, ...extras)
  const span = (max - min) || 1
  const iw = w - PAD.l - PAD.r
  const ih = H - PAD.t - PAD.b
  const x = (i) => PAD.l + (i / (pts.length - 1)) * iw
  const y = (v) => PAD.t + ih - ((v - min) / span) * ih
  const line = pts.map(([, v], i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)} ${y(v).toFixed(1)}`).join(' ')
  const lastIdx = pts.length - 1
  // 「现在」标注基线：默认在末点上方 10px；现价贴近 7 天高点时上方会顶出画布
  // （fs-2xs 11px 字 ascent≈9，基线 <10 即裁切），翻到末点下方 16px
  const lastY = y(pts[lastIdx][1])
  const curLabelY = lastY - 10 < 10 ? lastY + 16 : lastY - 10
  // 「现在」标注水平防撞：末点恒在绘图区最右端，与展开面板右上角绝对定位的
  // 「收起」按钮带（top:10 right:10，雷达页直接压图、子弹页虽有 td 顶部
  // padding 让位仍同域）重叠。标注 x 超过绘图区 70% 宽即翻转到数据点左侧
  // 渲染：右对齐、右缘退到点左方 60 视图单位（≈按钮带宽 + 边距），整体让出
  // 右上角按钮区；y 仍走上面的纵向防撞
  const curFlip = x(lastIdx) > PAD.l + iw * 0.7
  const cur = {
    x: curFlip ? x(lastIdx) - 60 : x(lastIdx) + 8,
    y: curLabelY,
    anchor: curFlip ? 'end' : 'start',
  }
  // 分位标注防撞取 y：三级回退（线上方 → 线下方 → 再抬高 8px），距避让基线均需 ≥11px
  const XL_Y = H - 8 // 两条 X 轴时间标签基线
  const mid = (max + min) / 2
  const base3 = [y(max) + 4, y(mid) + 4, y(min) + 4] // 三条 Y 轴刻度基线
  const pickY = (v, avoid) => {
    const baselines = [...base3, XL_Y, ...avoid]
    const clear = (yy) => baselines.every((b) => Math.abs(yy - b) >= 11)
    const c1 = y(v) - 5
    if (clear(c1)) return c1
    const c2 = y(v) + 11
    if (clear(c2) && c2 <= H - PAD.b) return c2 // 不得进入 X 轴标签区
    return Math.max(y(v) - 13, PAD.t + 8)
  }
  // 依次落 P75 / P25 / 官方均价，前者的结果计入避让集后再算下一条，标注互不相撞
  const avoid = []
  let q75y = null
  let q25y = null
  let offy = null
  if (Number.isFinite(props.p75)) {
    q75y = pickY(props.p75, avoid)
    avoid.push(q75y)
  }
  if (Number.isFinite(props.p25)) {
    q25y = pickY(props.p25, avoid)
    avoid.push(q25y)
  }
  if (Number.isFinite(props.official)) offy = pickY(props.official, avoid)
  // 两条分位线重合（扁平曲线实测 p25==p75）时两条标注会落到同一 y：把 P25 上/下移 11px 错开
  if (q75y != null && q25y != null && Math.abs(q75y - q25y) < 11) {
    const alt = [q75y - 11, q75y + 11].find(
      (yy) => yy >= PAD.t + 8 && [...base3, XL_Y].every((b) => Math.abs(yy - b) >= 11)
    )
    if (alt != null) q25y = alt
  }

  return {
    line, min, max, y, x, ih, iw, q75y, q25y, offy, cur, pts,
    dot: { cx: x(lastIdx), cy: lastY, r: 3.5 },
    area: `${line} L${x(lastIdx).toFixed(1)} ${PAD.t + ih} L${PAD.l} ${PAD.t + ih} Z`,
    labels: { first: fmtTs(pts[0][0]), mid: fmtTs(pts[Math.floor(lastIdx / 2)][0]), last: fmtTs(pts[lastIdx][0]) },
    firstX: PAD.l, midX: x(Math.floor(lastIdx / 2)), lastX: w - PAD.r,
  }
})

/* ---------- 悬停/拖动查值（MOTION.md §3-G 网页十字线，P2 提前落地） ----------
   pointer 统一路径：鼠标移动即查（hover 提示），触屏按住拖动查值（pointerdown
   setPointerCapture，拖出图外也不丢）。十字线只动 opacity（动效红线），位置瞬跟
   指针不做过渡；读数固定在图上方一行——不贴指针，触屏不被手指遮挡，且条常驻
   （未激活时显示末点现价），进出不推挤布局。touch-action: pan-y 让纵向手势仍
   归页面滚动、横向拖动才查值；浏览器接管滚动时发 pointercancel 自动清除。 */
const svgRef = ref(null)
const probe = ref(null) // { x, y, ts, price } 十字线与读数的数据源
let lastX = null // 最近一次查值的指针 clientX：曲线换血 / 基准宽切换后就地重算的依据
function toProbe(evt) {
  const g = geo.value
  const svg = svgRef.value
  if (!g || !svg) return
  const rect = svg.getBoundingClientRect()
  if (!rect.width) return
  // clientX → viewBox 等比换算（max-width 封顶/容器收窄时渲染宽与 viewBox 恒同比）
  const vx = ((evt.clientX - rect.left) / rect.width) * W.value
  const n = g.pts.length
  const i = Math.min(n - 1, Math.max(0, Math.round(((vx - PAD.l) / g.iw) * (n - 1))))
  const [ts, v] = g.pts[i]
  probe.value = {
    x: g.x(i), y: g.y(v), ts: fmtTs(ts),
    price: Math.round(v).toLocaleString('zh-CN'),
  }
  lastX = evt.clientX
}
function probeDown(e) {
  // 鼠标右键/中键不启动查值：contextmenu 菜单与十字线读数是互斥的两套界面，
  // 同屏出现是怪异态（且 probe 会残留到 pointerleave）；触屏/笔 pointerdown
  // 恒主键（button 0），不受此过滤影响
  if (e.pointerType === 'mouse' && e.button !== 0) return
  svgRef.value?.setPointerCapture?.(e.pointerId)
  toProbe(e)
}
function probeUp(e) {
  // 触屏抬手即收（读数回「现在」）；鼠标点击抬起保留 hover 读数，移出图再清
  if (e.pointerType !== 'mouse') probe.value = null
}
function probeClear() { probe.value = null; lastX = null }
/* 基准宽切换（容器 resize）/曲线换血（轮询）后旧坐标失效：查值中（鼠标仍悬停在图上、
   或触屏仍按住）按最近指针位置重取最近点，十字线与读数不断流——60s 静默刷新不打断
   正在进行的查值（原先一律清空，悬停用户每分钟被「掐」一次要再动鼠标才恢复）；
   未查值时无事可做。toProbe 只读 clientX，这里以最小事件对象复用同一换算路径 */
watch([W, () => props.curve], () => {
  if (probe.value == null || lastX == null) return
  toProbe({ clientX: lastX })
})
/* 读数默认值：末点现价（与图内「现在」标注同源；无 current 时如实给占位） */
const curReadout = computed(() =>
  props.current != null && Number.isFinite(props.current)
    ? Math.round(props.current).toLocaleString('zh-CN')
    : '—')

/* 读数条左缘与 Y 轴刻度对齐要按渲染缩放比换算：Y 轴在 viewBox x=PAD.l，但 svg
   渲染宽受 max-width 封顶（.pc-svg 900px，与 W_CAP 同源手写、改动需两处同步），
   容器比 viewBox 基准宽时缩放比 >1，Y 轴实际渲染像素 = PAD.l × 缩放比。原先恒
   取 PAD.l 视图单位，宽屏展开行（渲染 900 / 基准 680 ≈ 1.32×）下读数比 Y 轴
   缩进 ~15px。boxW 未探测（首帧）时按缩放比 1 兜底，与窄屏行为一致 */
const W_CAP = 900
const readoutPad = computed(() => {
  const renderW = Math.min(boxW.value || W_BASE, W_CAP)
  return Math.round(PAD.l * (renderW / W.value))
})
</script>

<template>
  <div v-if="geo" ref="hostRef" class="pchart">
    <!-- 查值读数：固定图上方一行（触屏不被手指遮挡、进出不推挤布局）；未拖动显示
         末点现价。左对齐给两页展开面板右上角绝对定位的「收起」按钮带让路；
         左缘与 Y 轴刻度对齐（readoutPad 按渲染缩放比换算，见 script）。拖动中逐点
         变化，屏幕读者会反复播报——语义已由 svg aria-label 承担，这里 aria-hidden
         静音。.on = 查值中：整行提亮、主数字转 accent，与空闲「现在」态拉开模式层次 -->
    <p class="pc-readout" :class="{ on: probe }" :style="{ paddingLeft: readoutPad + 'px' }" aria-hidden="true">
      <template v-if="probe">{{ probe.ts }} · <b>{{ probe.price }}</b></template>
      <template v-else>现在 · <b>{{ curReadout }}</b></template>
    </p>
    <svg
      ref="svgRef" :viewBox="`0 0 ${W} ${H}`" class="pc-svg" role="img" :aria-label="current != null ? '近7天每小时价格，现价 ' + Math.round(current) : '近7天每小时价格'"
      @pointerdown="probeDown" @pointermove="toProbe" @pointerup="probeUp"
      @pointercancel="probeClear" @pointerleave="probeClear"
    >
      <!-- Y 轴刻度：max / mid / min（千分位与读数条同格式，fmtN 见 script） -->
      <text :x="PAD.l - 6" :y="geo.y(geo.max) + 4" class="pc-tick" text-anchor="end">{{ fmtN(geo.max) }}</text>
      <text :x="PAD.l - 6" :y="geo.y((geo.max + geo.min) / 2) + 4" class="pc-tick" text-anchor="end">{{ fmtN((geo.max + geo.min) / 2) }}</text>
      <text :x="PAD.l - 6" :y="geo.y(geo.min) + 4" class="pc-tick" text-anchor="end">{{ fmtN(geo.min) }}</text>

      <!-- 分位线：P75 卖出参考（上）、P25 买入参考（下）；标注挂线左端，与右缘「现在」错位。
           判定与脚本层 geo 的 Number.isFinite 同口径：0 是有效价位要画线（v-if="p75" 会把 0 当缺失） -->
      <line v-if="Number.isFinite(p75)" :x1="PAD.l" :y1="geo.y(p75)" :x2="W - PAD.r" :y2="geo.y(p75)" class="pc-quant q75" />
      <text v-if="Number.isFinite(p75)" :x="PAD.l + 4" :y="geo.q75y" class="pc-qtxt q75t" text-anchor="start">P75 卖出参考 {{ fmtN(p75) }}</text>
      <line v-if="Number.isFinite(p25)" :x1="PAD.l" :y1="geo.y(p25)" :x2="W - PAD.r" :y2="geo.y(p25)" class="pc-quant q25" />
      <text v-if="Number.isFinite(p25)" :x="PAD.l + 4" :y="geo.q25y" class="pc-qtxt q25t" text-anchor="start">P25 买入参考 {{ fmtN(p25) }}</text>

      <!-- 官方均价参考线（旁路参照不进信号）：点线 + 中性提亮，与 P25/P75 语义色区分 -->
      <line v-if="Number.isFinite(official)" :x1="PAD.l" :y1="geo.y(official)" :x2="W - PAD.r" :y2="geo.y(official)" class="pc-quant qoff" />
      <text v-if="Number.isFinite(official)" :x="PAD.l + 4" :y="geo.offy" class="pc-qtxt qofft" text-anchor="start">官方均价 {{ fmtN(official) }}</text>

      <path :d="geo.area" class="pc-area" />
      <path :d="geo.line" class="pc-line" fill="none" />
      <circle v-bind="geo.dot" class="pc-dot" />
      <!-- 「现在」值缺省给占位而非 0：与 svg aria-label 的 current != null 判定
           同口径（?? 0 会把缺失渲染成「现在 0」的误导读数） -->
      <text :x="geo.cur.x" :y="geo.cur.y" class="pc-curtxt" :text-anchor="geo.cur.anchor">现在 {{ current != null ? fmtN(current) : '—' }}</text>

      <!-- X 轴三档（首/中/尾）：7 天轴只给首尾时中段无时间锚点，查值读数的
           「MM-DD HH:mm」无从对照；中点对齐 iOS 按天标签的密度。三个标签
           首左锚/中中锚/尾右锚，最窄 400 基准（绘图区 340）下各 ~66px 互不相撞 -->
      <text :x="geo.firstX" :y="H - 8" class="pc-tick">{{ geo.labels.first }}</text>
      <text :x="geo.midX" :y="H - 8" class="pc-tick" text-anchor="middle">{{ geo.labels.mid }}</text>
      <text :x="geo.lastX" :y="H - 8" class="pc-tick" text-anchor="end">{{ geo.labels.last }}</text>

      <!-- 查值十字线：纵向虚线 + 数据点强调圈；只动 opacity（位置瞬跟指针），
           probe 空时坐标兜底 0（层整体 opacity 0 不可见） -->
      <g class="pc-xh" :class="{ on: probe }">
        <line :x1="probe ? probe.x : 0" :y1="PAD.t" :x2="probe ? probe.x : 0" :y2="H - PAD.b" />
        <circle :cx="probe ? probe.x : 0" :cy="probe ? probe.y : 0" r="3.5" />
      </g>
    </svg>
  </div>
  <p v-else class="pc-empty">历史数据不足</p>
</template>

<style scoped>
.pchart { width: 100%; }
/* 查值读数条：常驻 mono 小字（与图内刻度同族），高度 ~20px；
   b 用 --tx-strong 立权（每条读数唯一主数字）。查值中（.on）整行 faint→dim、
   主数字→accent（选择语义：唯一强调色可作文字色），空闲回落——只动颜色，
   150ms 微交互档，与十字线淡入同步 */
.pc-readout {
  margin: 0 0 var(--sp-1);
  font-family: var(--mono); font-size: var(--fs-2xs); color: var(--faint);
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  transition: color var(--t-fast) var(--ease);
}
.pc-readout b { color: var(--tx-strong); font-weight: 700; font-variant-numeric: tabular-nums; transition: color var(--t-fast) var(--ease); }
.pc-readout.on { color: var(--dim); }
.pc-readout.on b { color: var(--accent); }
/* 查值十字线：纵向虚线（中性 --dim，不与 P25/P75 语义色抢）+ 点强调圈
   （accent 描边呼应主线）；只动 opacity，激活 150ms 微交互档淡入。
   圈心填宿主面 --card2：本图两个落位（子弹/雷达页）展开面板 td 背景均为
   card2，此前填 --bg 深一档面阶、圈心显深斑；iOS 同位强调圈即「宿主卡面
   填底 + accent 描边」（PriceChart.swift），双端同口径 */
.pc-xh { opacity: 0; transition: opacity var(--t-fast) var(--ease); pointer-events: none; }
.pc-xh.on { opacity: 1; }
.pc-xh line { stroke: var(--dim); stroke-width: 1; stroke-dasharray: 3 3; }
.pc-xh circle { fill: var(--card2); stroke: var(--accent); stroke-width: 2; }
@media (prefers-reduced-motion: reduce) {
  .pc-xh { transition: none; } /* 十字线位置本就瞬跟，淡入也瞬时 */
  .pc-readout, .pc-readout b { transition: none; } /* 读数态切换同样瞬时 */
}
/* ≥680 容器：680 基准 viewBox 随容器等比放大，全宽展开行（~1160px）下刻度字会
   渲染到 ~17px、超过正文基准，与下方脚注字号倒挂；封顶 900px（≈1.32x）让图内
   文字回到 12~14px 字阶族。<680 容器：脚本按容器实际宽收窄 viewBox 基准
   （ResizeObserver，下限 400），缩放比恒 ≈1，小屏刻度/标注不再等比缩小难读 */
.pc-svg {
  display: block; width: 100%; max-width: 900px; height: auto;
  /* 触屏横向拖动归查值、纵向手势仍归页面滚动；不支持时整行声明被丢弃、
     行为退回纯展示（图仍完整可读），功能无损 */
  touch-action: pan-y;
  /* 查值手感两件套：十字光标先于移动就示意「图可查」；拖动查值时鼠标框选
     不再选中图内 text（SVG text 默认可选，拖过刻度/标注会拖出高亮选区）。
     user-select 不影响读屏（aria-label 在 svg 上）与键盘路径 */
  cursor: crosshair;
  user-select: none;
  -webkit-user-select: none;
}
.pc-line { stroke: var(--accent); stroke-width: 1.8; }
.pc-area { fill: var(--accent); opacity: .08; }
.pc-dot { fill: var(--tx-strong); }
.pc-curtxt { font-family: var(--mono); font-size: var(--fs-2xs); fill: var(--tx-strong); }
.pc-tick { font-family: var(--mono); font-size: var(--fs-micro); fill: var(--faint); }
.pc-quant { stroke-dasharray: 5 4; stroke-width: 1; }
.q75 { stroke: var(--danger); }
.q75t { fill: var(--danger); }
.q25 { stroke: var(--ok); }
.q25t { fill: var(--ok); }
/* 官方均价参考线：点线更密 + dim 色（旁路参照，不与买卖语义色抢）；标注同色 */
.qoff { stroke: var(--dim); stroke-dasharray: 2 3; }
.qofft { fill: var(--dim); }
/* 分位标注承载价格实义数据（「P75 卖出参考 1,234」），与同为线标注的 .pc-curtxt
   统一到 fs-2xs（11px，mono 小标签档）——原 fs-micro(10px) 按 base.css 口径只许
   给不承载实义数据的字段名/刻度；坐标轴刻度（.pc-tick）仍留 micro。pickY 防撞的
   ≥11px 基线间距对 11px 字仍成立（ascent ≈9px），标注左锚 PAD.l+4、绘图区
   ≥340 视图单位宽，加宽的文字不会碰到右缘「现在」标注 */
.pc-qtxt { font-family: var(--mono); font-size: var(--fs-2xs); }
.pc-empty { color: var(--faint); font-size: var(--fs-sm); }
</style>
