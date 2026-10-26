<script setup>
/* SignalCard — 买入信号主打卡：战术行情卡样式
   结构（自上而下）：图标+弹名+分位徽章 → 中性 sparkline → 英雄利润带
   （唯一绿色焦点：预赚/发 大数）→ 价格三栏 → 7 天区间游标（阈值染色轨道）
   → 数量试算 → 卖出时机脚注。
   视觉锚点：HUD 对角括线（::before/::after）+ 卡面纵向渐变 + 顶缘高光；
   官方弹药图标走 picThumb CDN 缩略（原图最大 1.2MB，不可直连）。 */
import { computed, ref, watch } from 'vue'
import Sparkline from './Sparkline.vue'
import { picThumb } from '@shared/js/marketMeta.js'
import { predictSellEta, fmtHours, fmtPeak } from '@shared/js/sellEta.js'

const props = defineProps({
  item: { type: Object, required: true },
})

const qty = ref(100)
/* 数量下限 1：输入 0 / 清空时试算区不出现「+0（+8.2%）」或空值——展示
   按夹取值算，失焦再把输入框本身落回规范值（输入过程中不打断改写） */
const safeQty = computed(() => {
  const n = Math.round(Number(qty.value))
  return Number.isFinite(n) && n >= 1 ? n : 1
})
function clampQty() { qty.value = safeQty.value }

/* ---------- 我的买入价（localStorage，key=ammo-mycost，{弹名:成本}） ----------
   默认回填优先级：用户记过的价 → 囤货台账（ammo-positions）里该弹的成本 → 现价；
   改动按弹名持久化（隐私模式写失败仅本次会话生效）。台账只读不写——在卡片上
   改价不会覆盖台账里已录的成本。 */
const MYCOST_KEY = 'ammo-mycost'
function readStoredCost(name) {
  for (const key of [MYCOST_KEY, 'ammo-positions']) {
    try {
      const raw = JSON.parse(localStorage.getItem(key))
      if (!raw) continue
      if (Array.isArray(raw)) {
        const hit = raw.find((p) => p && p.name === name && Number.isFinite(+p.cost))
        if (hit) return +hit.cost
      } else if (typeof raw === 'object' && Number.isFinite(+raw[name])) {
        return +raw[name]
      }
    } catch { /* 存储不可读时按现价兜底 */ }
  }
  return null
}
const myCost = ref(readStoredCost(props.item.name) ?? props.item.current)
/* 未记过价的卡片跟随现价：buyList 按 :key=name 复用组件实例，SSE / 轮询静默
   刷新后 item.current 已变而 ref 只在创建时求值一次，会停在陈旧现价；用户
   记过价（本机存档或本会话手动改过，隐私模式存不进也由 manualCost 兜住）
   则保持用户口径不跟随 */
let manualCost = false
watch(
  () => props.item.current,
  (cur) => {
    if (manualCost || readStoredCost(props.item.name) != null) return
    if (Number.isFinite(cur) && cur > 0) myCost.value = cur
  },
)
const safeCost = computed(() => {
  const n = Number(myCost.value)
  return Number.isFinite(n) && n > 0 ? n : props.item.current
})
function saveMyCost() {
  manualCost = true // 本会话手动记过价：现价再变也不夺走用户口径
  try {
    const raw = JSON.parse(localStorage.getItem(MYCOST_KEY)) || {}
    if (Number.isFinite(+myCost.value) && +myCost.value > 0) raw[props.item.name] = +myCost.value
    else delete raw[props.item.name]
    localStorage.setItem(MYCOST_KEY, JSON.stringify(raw))
  } catch { /* 隐私模式等写入失败时仅本次会话生效 */ }
}
/* 输入 0 / 清空时按现价兜底展示，失焦落回规范值再持久化（口径同 qty 夹取） */
function clampCost() {
  myCost.value = safeCost.value
  saveMyCost()
}
function resetCost() {
  myCost.value = props.item.current
  saveMyCost()
}

/* 按成本价重算的两档口径（与囤货台账一致）：
   现价直出 = current×(1−税率)；挂目标价到手 = netSell（契约字段） */
const netNow = computed(() => props.item.current * (1 - props.item.taxRate))
const gainNow = computed(() => netNow.value - safeCost.value)
const gainP75 = computed(() => props.item.netSell - safeCost.value)
const costPct = computed(() => gainP75.value / safeCost.value)

/* 预计卖出时间（历史到达历时 + 日内节律，纯函数在 ./sellEta.js） */
const eta = computed(() => predictSellEta(props.item))
const etaPeak = computed(() => {
  if (!eta.value || eta.value.peakStart == null) return ''
  const p = fmtPeak(eta.value.peakStart, eta.value.peakEnd) || ''
  return eta.value.liftPct != null ? `${p}（比低位高 ${Math.round(eta.value.liftPct * 100)}%）` : p
})
const etaTip = computed(() => {
  if (!eta.value || eta.value.medianH == null) return ''
  return (
    `依据：近 7 天 ${eta.value.episodes} 次从当前价位档涨到挂卖价的完整上涨` +
    `（中位 ${fmtHours(eta.value.medianH)}、最快 ${fmtHours(eta.value.fastestH)}）` +
    `；日内高位按 7 天同小时均价统计。历史统计不代表未来`
  )
})
/* 预计历时的展示门槛：至少 2 次完整上涨样本（单样本中位没有置信度） */
const etaReady = computed(() => !!eta.value && eta.value.medianH != null && eta.value.episodes >= 2)

const fmt = (n) => (Number.isFinite(n) ? Math.round(n).toLocaleString('zh-CN') : '—')
/* 收益率带符号（按成本重算后可能为负）：+8.2% / -3.1% */
const pct = (n) => (Number.isFinite(n) ? `${n >= 0 ? '+' : ''}${(n * 100).toFixed(1)}%` : '—')
/* 带符号金额（利润可能为负）：+12,345 / -1,024 */
const fmtSigned = (n) => (Number.isFinite(n) ? `${n >= 0 ? '+' : '-'}${Math.abs(Math.round(n)).toLocaleString('zh-CN')}` : '—')
// 品级色沿用 base.css --lv* 语义变量（2 绿 ~ 6 红）
const gradeVar = (g) => (g >= 2 && g <= 6 ? `var(--lv${g})` : 'var(--faint)')
const rankPct = (r) => (Number.isFinite(r) ? Math.round(r * 100) : null)
// 游标定位夹在 2%~98%：rank 极值时菱形不出轨道端头
const markPos = (r) => Math.min(98, Math.max(2, rankPct(r) ?? 50))
// 图标加载失败（CDN 抖动等）就地隐藏，不占位不报错
const hideImg = (e) => { e.target.style.display = 'none' }
</script>

<template>
  <article class="sig-card">
    <header class="sc-head">
      <span class="sc-ic" :class="{ empty: !item.pic }">
        <img
          v-if="item.pic" :src="picThumb(item.pic, 128)"
          alt="" width="32" height="28" loading="lazy" decoding="async"
          @error="hideImg"
        >
        <i class="sc-grade" :style="{ background: gradeVar(item.grade) }" :title="`品级 ${item.grade}`"></i>
      </span>
      <h4 class="sc-name">{{ item.name }}</h4>
      <span
        class="sc-rank" :class="{ low: item.rank != null && item.rank <= 0.35 }"
        :title="`现价处近 7 天 ${rankPct(item.rank)}% 分位`"
      >P{{ rankPct(item.rank) }}</span>
    </header>

    <Sparkline :curve="item.curve" :width="200" :height="40" class="sc-spark" />

    <!-- 英雄带：每发税后利润是全卡唯一大号彩色数字 -->
    <div class="sc-hero">
      <b class="hero-num">+{{ fmt(item.profitPerRound) }}</b>
      <span class="hero-unit">预赚 / 发</span>
      <span class="hero-pct">{{ pct(item.profitPct) }}</span>
    </div>

    <div class="sc-grid">
      <div class="sc-cell">
        <span class="sc-k">买入 ≤</span>
        <span class="sc-v strong">{{ fmt(item.current) }}</span>
      </div>
      <div class="sc-cell">
        <span class="sc-k">挂卖价</span>
        <span class="sc-v">{{ fmt(item.targetSell) }}</span>
      </div>
      <div class="sc-cell">
        <span class="sc-k">税后到手</span>
        <span class="sc-v">{{ fmt(item.netSell) }}</span>
      </div>
    </div>

    <!-- 预计卖出时间：历史到达历时 + 日内节律（统计口径见 METHOD，悬浮有依据） -->
    <div v-if="etaReady" class="sc-eta" :title="etaTip">
      <svg class="eta-ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.5A6.5 6.5 0 1 0 8 14.5 6.5 6.5 0 0 0 8 1.5Zm.7 2.9v3.44l2.66 1.54-.7 1.2-3.36-1.94V4.4h1.4Z" fill="currentColor"/></svg>
      <span class="eta-txt">
        <span class="eta-main">预计卖出 <b>≈ {{ fmtHours(eta.medianH) }}</b> 后<span v-if="eta.etaLabel">（{{ eta.etaLabel }} 前后）</span></span>
        <span class="eta-sub">最快 {{ fmtHours(eta.fastestH) }}<template v-if="etaPeak"> · 日内高位 {{ etaPeak }}</template></span>
      </span>
    </div>

    <!-- 7 天区间游标：轨道两端按买入(≤25%)/卖出(≥80%)阈值染色，菱形标记 = 现价位置 -->
    <div
      class="sc-range" role="img"
      :aria-label="`现价处近 7 天 ${rankPct(item.rank)}% 分位，区间 ${fmt(item.weekLow)} 至 ${fmt(item.weekHigh)}`"
    >
      <span class="r-val">{{ fmt(item.weekLow) }}</span>
      <div class="r-track">
        <i
          class="r-mark"
          :class="{ low: item.rank <= 0.35, high: item.rank >= 0.8 }"
          :style="{ left: `${markPos(item.rank)}%` }"
        ></i>
      </div>
      <span class="r-val">{{ fmt(item.weekHigh) }}</span>
    </div>

    <div class="sc-qty">
      <span class="sc-k">数量</span>
      <button
        v-for="n in [100, 500, 1000]" :key="n"
        class="qty-chip" :class="{ on: safeQty === n }" @click="qty = n"
      >{{ n }}</button>
      <input v-model.number="qty" class="qty-in" type="number" min="1" aria-label="自定义数量" @blur="clampQty" />
    </div>
    <!-- 我的买入价：默认回填现价，按弹名记住（见 script 口径）；「现价」一键回切 -->
    <div class="sc-cost">
      <span class="sc-k">我的买入价</span>
      <input v-model.number="myCost" class="qty-in cost-in" type="number" min="1" step="any" aria-label="我的买入价（默认现价）" @change="saveMyCost" @blur="clampCost" />
      <button class="cost-reset" type="button" :title="`回填现价 ${fmt(item.current)}`" @click="resetCost">现价</button>
      <span class="cost-hint">按弹名记住 · 本机存储</span>
    </div>
    <!-- 试算按成本价重算：总投入 / 挂目标价利润（收益率 = 到价利润 ÷ 成本） -->
    <div class="sc-totals">
      <span>总投入 <b>{{ fmt(safeCost * safeQty) }}</b></span>
      <span class="tot-profit" :class="{ neg: gainP75 < 0 }">挂目标价利润 {{ fmtSigned(gainP75 * safeQty) }}（{{ pct(costPct) }}）</span>
    </div>
    <!-- 两档到手对比：现价直出（急用钱立卖）vs 挂目标价等到价，利润均按「我的买入价」口径 -->
    <div class="sc-exit">
      <span>现价直出 <b>{{ fmt(netNow * safeQty) }}</b><i :class="gainNow >= 0 ? 'pos' : 'neg'">（利润 {{ fmtSigned(gainNow * safeQty) }}）</i></span>
      <span>挂目标价到手 <b>{{ fmt(item.netSell * safeQty) }}</b><i :class="gainP75 >= 0 ? 'pos' : 'neg'">（利润 {{ fmtSigned(gainP75 * safeQty) }}）</i></span>
    </div>

    <footer class="sc-foot">
      什么时候卖：价格回到 <b>{{ fmt(item.targetSell) }}</b>（近 3 天 75 分位）即挂卖；乐观目标 {{ fmt(item.netHigh) }}（7 天高点税后）。
      <template v-if="item.stopLoss">破 <b>{{ fmt(item.stopLoss) }}</b> 止损离场。</template>
      税率 {{ (item.taxRate * 100).toFixed(0) }}%。
    </footer>
  </article>
</template>

<style scoped>
/* 信号语义色派生统一 color-mix（var(--ok) = --lv2 语义），逐条保留真值 rgba 兜底行，
   写法同 ttk PenMatrix 范本 */
.sig-card {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
  padding: var(--sp-4);
  background: linear-gradient(180deg, var(--card2) 0%, var(--card) 58%);
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  box-shadow: var(--edge-light);
  transition: transform var(--t-med) var(--ease), border-color var(--t-med) var(--ease), box-shadow var(--t-med) var(--ease);
}
.sig-card:hover {
  transform: translateY(-2px);
  border-color: rgba(133, 181, 120, .38);
  border-color: color-mix(in srgb, var(--ok) 38%, transparent);
  box-shadow: var(--edge-hover);
}

/* HUD 对角括线：左上 / 右下两枚 L 形，hover 点亮——卡片唯一的战术装饰 */
.sig-card::before,
.sig-card::after {
  content: '';
  position: absolute;
  width: 12px; height: 12px;
  border: 0 solid rgba(133, 181, 120, .45);
  border: 0 solid color-mix(in srgb, var(--ok) 45%, transparent);
  transition: border-color var(--t-med) var(--ease);
  pointer-events: none;
}
.sig-card::before { top: 7px; left: 7px; border-top-width: 2px; border-left-width: 2px; }
.sig-card::after { bottom: 7px; right: 7px; border-bottom-width: 2px; border-right-width: 2px; }
.sig-card:hover::before,
.sig-card:hover::after {
  border-color: rgba(133, 181, 120, .9);
  border-color: color-mix(in srgb, var(--ok) 90%, transparent);
}

/* ---------- 头部：切角图标框 + 品级菱形角标 + 弹名 + 分位徽章 ---------- */
.sc-head { display: flex; align-items: center; gap: var(--sp-3); }
.sc-ic {
  position: relative;
  width: 44px; height: 44px; flex: none;
  display: grid; place-items: center;
  background: var(--deep);
  border: 1px solid var(--line);
  /* 右上切角：战术弹药匣轮廓，切边处无描边为有意为之 */
  clip-path: polygon(0 0, calc(100% - 11px) 0, 100% 11px, 100% 100%, 0 100%);
}
.sc-ic.empty { border-style: dashed; clip-path: none; }
.sc-ic img { width: 30px; height: 28px; object-fit: contain; }
.sc-grade {
  position: absolute; right: 3px; bottom: 3px;
  width: 7px; height: 7px; transform: rotate(45deg);
  box-shadow: 0 0 0 2px var(--deep); /* 镶边让角标压在图标上仍可读 */
}
.sc-name {
  flex: 1; min-width: 0; margin: 0;
  font-size: var(--fs-lg);
  font-weight: 700;
  color: var(--tx-strong);
  line-height: var(--lh-tight);
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
.sc-rank {
  flex: none; align-self: flex-start;
  font-family: var(--mono); font-size: var(--fs-2xs);
  color: var(--dim); letter-spacing: .06em;
  background: var(--card);
  border: 1px solid var(--line);
  border-radius: var(--radius-pill);
  padding: 2px 9px;
}
.sc-rank.low {
  color: var(--ok);
  border-color: rgba(133, 181, 120, .4); background: rgba(133, 181, 120, .1);
  border-color: color-mix(in srgb, var(--ok) 40%, transparent);
  background: color-mix(in srgb, var(--ok) 10%, transparent);
}

/* 卡内走势满宽自适应（viewBox 5:1）；颜色降为中性纹理（含当前点圆点，经
   --spark-dot 透传），绿色焦点只留给 hero 带 */
.sc-spark {
  --spark-line: var(--dim);
  --spark-fill: var(--dim);
  --spark-dot: var(--dim);
  display: block; width: 100%; height: auto;
}

/* ---------- 英雄带：预赚/发 大数 + 收益率 ---------- */
.sc-hero {
  display: flex; align-items: baseline; gap: var(--sp-2);
  padding: 10px 14px;
  background: linear-gradient(90deg, rgba(133, 181, 120, .12), rgba(133, 181, 120, .03) 78%);
  background: linear-gradient(90deg, color-mix(in srgb, var(--ok) 12%, transparent), color-mix(in srgb, var(--ok) 3%, transparent) 78%);
  border-left: 2px solid var(--ok);
  border-radius: var(--radius-sm);
}
.hero-num {
  font-family: var(--mono); font-weight: 700;
  font-size: var(--fs-display);
  line-height: 1;
  color: var(--ok);
  letter-spacing: -.01em;
  font-variant-numeric: tabular-nums;
}
.hero-unit { font-family: var(--mono); font-size: var(--fs-2xs); color: var(--dim); white-space: nowrap; }
.hero-pct { margin-left: auto; font-family: var(--mono); font-weight: 700; font-size: var(--fs-md); color: var(--ok); }

/* ---------- 价格三栏（hairline 分隔） ---------- */
.sc-grid { display: grid; grid-template-columns: repeat(3, 1fr); }
.sc-cell {
  display: flex; flex-direction: column; gap: 3px;
  padding: 2px var(--sp-3);
  border-left: 1px solid var(--line2);
  min-width: 0;
}
.sc-cell:first-child { border-left: 0; padding-left: 2px; }
.sc-k { font-family: var(--mono); font-size: var(--fs-2xs); color: var(--faint); letter-spacing: .08em; white-space: nowrap; }
.sc-v {
  font-family: var(--mono); font-size: var(--fs-md); color: var(--tx);
  font-variant-numeric: tabular-nums;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.sc-v.strong { color: var(--tx-strong); font-weight: 700; }

/* ---------- 预计卖出时间条（--accent 预测语义：区别于绿色利润焦点与红色卖出语义；
   派生色统一 color-mix + 真值 rgba 兜底，accent 真值 #2dd4bf = rgb(45,212,191)） ---------- */
.sc-eta {
  display: flex; align-items: center; gap: 10px;
  padding: 9px 14px;
  border-left: 2px solid var(--accent-dim);
  border-radius: var(--radius-sm);
  background: linear-gradient(90deg, rgba(45, 212, 191, .1), rgba(45, 212, 191, .02) 78%);
  background: linear-gradient(90deg, color-mix(in srgb, var(--accent) 10%, transparent), color-mix(in srgb, var(--accent) 2%, transparent) 78%);
}
.eta-ic { flex: none; width: 15px; height: 15px; color: var(--accent); }
.eta-txt { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
.eta-main { font-size: var(--fs-sm); color: var(--tx); }
.eta-main b {
  font-family: var(--mono); font-weight: 700; color: var(--accent);
  font-variant-numeric: tabular-nums; white-space: nowrap;
}
.eta-sub {
  font-family: var(--mono); font-size: var(--fs-2xs); color: var(--faint);
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}

/* ---------- 7 天区间游标 ---------- */
.sc-range { display: flex; align-items: center; gap: var(--sp-2); }
.r-val { font-family: var(--mono); font-size: var(--fs-2xs); color: var(--faint); flex: none; }
.r-track {
  position: relative; flex: 1; height: 6px;
  border-radius: var(--radius-pill);
  /* 轨道即阈值图例：左端 ≤26% 淡绿（买入区）、右端 ≥21% 淡红（卖出区） */
  background:
    linear-gradient(90deg, rgba(133, 181, 120, .32), rgba(133, 181, 120, .02) 26%),
    linear-gradient(270deg, rgba(217, 106, 89, .34), rgba(217, 106, 89, .02) 21%),
    var(--line2);
  background:
    linear-gradient(90deg, color-mix(in srgb, var(--ok) 32%, transparent), color-mix(in srgb, var(--ok) 2%, transparent) 26%),
    linear-gradient(270deg, color-mix(in srgb, var(--danger) 34%, transparent), color-mix(in srgb, var(--danger) 2%, transparent) 21%),
    var(--line2);
}
.r-mark {
  position: absolute; top: 50%;
  width: 9px; height: 9px;
  transform: translate(-50%, -50%) rotate(45deg);
  background: var(--tx-strong);
  border-radius: 2px;
  box-shadow: 0 0 0 2px var(--card);
}
.r-mark.low { background: var(--ok); }
.r-mark.high { background: var(--danger); }

/* ---------- 数量试算 ---------- */
.sc-qty { display: flex; align-items: center; flex-wrap: wrap; gap: 6px; }
.qty-chip {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  color: var(--dim); font-family: var(--mono); font-size: var(--fs-2xs);
  padding: 2px 10px; cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease), background-color var(--t-fast) var(--ease);
}
/* 按下同 hover（chip 规格，与主表 .chip 对齐） */
.qty-chip:hover,
.qty-chip:active { color: var(--tx); border-color: var(--line-hover); }
.qty-chip.on { background: var(--accent-bg); color: var(--accent); border-color: var(--accent-dim); }
.qty-in {
  width: 76px; background: var(--card); border: 1px solid var(--line); border-radius: var(--radius);
  color: var(--tx); font-family: var(--mono); font-size: var(--fs-xs); padding: 3px 8px;
  transition: border-color var(--t-fast) var(--ease);
}
/* 键盘可达走全局 :focus-visible 外框；:focus 只做边框提亮，不抹 outline */
.qty-in:focus { border-color: var(--accent-dim); }
/* number 步进箭头占宽且挤不进窄列：隐藏（键盘直输 / 滚轮仍可调），同台账 .pos-in 口径 */
.qty-in::-webkit-outer-spin-button, .qty-in::-webkit-inner-spin-button { -webkit-appearance: none; margin: 0; }
.qty-in[type="number"] { -moz-appearance: textfield; appearance: textfield; }
/* iOS Safari 聚焦 <16px 输入会整页自动放大（viewport 未锁 maximum-scale）：
   移动端临时升到 16px 防缩放跳动，桌面不变 */
@media (max-width: 680px) {
  .qty-in { font-size: var(--fs-lg); }
}
.sc-totals {
  display: flex; flex-wrap: wrap; gap: var(--sp-4);
  border-top: 1px dashed var(--line2); padding-top: 10px;
  font-size: var(--fs-xs); color: var(--dim);
}
.sc-totals b { font-family: var(--mono); color: var(--tx-strong); }
.tot-profit { color: var(--ok); font-family: var(--mono); }
.tot-profit.neg { color: var(--danger); }

/* ---------- 我的买入价行（与数量行同构；「现价」一键回切 + 本机存储提示） ---------- */
.sc-cost { display: flex; align-items: center; flex-wrap: wrap; gap: 6px; }
.cost-in { width: 92px; }
.cost-reset {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  color: var(--dim); font-family: var(--mono); font-size: var(--fs-2xs);
  padding: 2px 10px; cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
}
/* 按下同 hover（chip 规格） */
.cost-reset:hover,
.cost-reset:active { color: var(--tx); border-color: var(--line-hover); }
.cost-hint { font-size: var(--fs-2xs); color: var(--faint); }

/* ---------- 两档到手对比：现价直出 vs 挂目标价（同成本口径，双列 hairline 分隔） ---------- */
.sc-exit {
  display: grid; grid-template-columns: 1fr 1fr;
  border-top: 1px dashed var(--line2); padding-top: 8px;
  font-size: var(--fs-xs); color: var(--dim);
}
.sc-exit > span { min-width: 0; padding: 0 var(--sp-2); }
.sc-exit > span + span { border-left: 1px solid var(--line2); }
.sc-exit b {
  font-family: var(--mono); color: var(--tx-strong);
  font-variant-numeric: tabular-nums; display: block;
}
.sc-exit i { font-style: normal; font-family: var(--mono); font-size: var(--fs-2xs); }
.sc-exit i.pos { color: var(--ok); }
.sc-exit i.neg { color: var(--danger); }

.sc-foot {
  font-size: var(--fs-xs);
  color: var(--dim);
  line-height: 1.7;
  border-top: 1px dashed var(--line2);
  padding-top: 10px;
}
.sc-foot b { color: var(--tx-strong); }

/* 本卡微交互过渡的 reduced-motion 关闭（hover 上浮降级为仅描边/高光变化） */
@media (prefers-reduced-motion: reduce) {
  .sig-card, .sig-card::before, .sig-card::after, .qty-chip, .qty-in, .cost-reset { transition: none; }
  .sig-card:hover { transform: none; }
}
</style>
