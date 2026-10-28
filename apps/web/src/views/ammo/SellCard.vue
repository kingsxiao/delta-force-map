<script setup>
/* SellCard — 卖出信号迷你卡：战术行情票根（与 SignalCard 同族、danger 语义）
   结构（自上而下）：切角图标匣 + 弹名 + P 分位徽章 → 现价英雄行（大数 +
   日内高位时段）→ 7 天分位轨道（卖出线刻度，阈值经 rules 下发不写死）。
   整卡可点，emit('open') 由父级联动全表展开该弹种走势；
   hover 泛红上浮、现价闪变与方向箭头口径沿旧版。 */
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { picThumb } from '@shared/js/marketMeta.js'
import { predictSellEta, fmtPeak } from '@shared/js/sellEta.js'
import { fmt, gradeVar } from '../../utils/format.js'
import { hideImg } from '../../composables/imgReady'

const props = defineProps({
  item: { type: Object, required: true },
  /* 信号门槛展示子集（快照顶层 rules）：卖出分位线染色与刻度同源，
     缺失（旧快照）退 v2 定稿值 */
  rules: { type: Object, default: () => ({}) },
})
defineEmits(['open'])

/* fmt / gradeVar 收编 ../../utils/format.js；图标加载失败就地隐藏的事件处理
   走 ../../composables/imgReady（占位底样式见 motion.css「图片占位」段） */

/* 卖出分位线（analyze.mjs SELL_RANK_MIN）：轨道刻度与徽章悬浮说明共用 */
const sellMin = computed(() => (Number.isFinite(props.rules.SELL_RANK_MIN) ? props.rules.SELL_RANK_MIN : 0.8))
const rankPct = computed(() => (Number.isFinite(props.item.rank) ? Math.round(props.item.rank * 100) : null))

/* 现价已在卖出区，回答「今天几点出」：日内高位时段 */
const peak = computed(() => {
  const e = predictSellEta(props.item)
  return e && e.peakStart != null ? fmtPeak(e.peakStart, e.peakEnd) : null
})

/* ---------- 现价闪变：轮询/SSE 静默刷新的因果反馈 ----------
   父级按 :key=name 复用组件实例，item.current 原地变化——diff 新旧价挂
   up/down 类：色过渡取 220ms 微交互档（MOTION.md 档位封闭；思路库的 0.8s
   只作类停留窗口、不作动效时长），0.8s 后摘类回落。方向箭头常驻「现价」
   标签行直到下次变化：RM 下的静态等价物（RM 时不挂色类、箭头照常），且
   箭头不进数字列，杜绝列宽跳动。 */
const priceFlash = ref('') // '' | 'up' | 'down'，色脉冲类，动效毕自动摘
const priceDir = ref('') // '' | 'up' | 'down'，常驻方向箭头
let flashTimer = 0
const rmMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches
watch(
  () => props.item.current,
  (cur, old) => {
    if (!Number.isFinite(cur) || !Number.isFinite(old) || cur === old) return
    priceDir.value = cur > old ? 'up' : 'down'
    if (rmMotion()) return
    priceFlash.value = cur > old ? 'up' : 'down'
    clearTimeout(flashTimer)
    flashTimer = setTimeout(() => { priceFlash.value = '' }, 800)
  },
)
onBeforeUnmount(() => clearTimeout(flashTimer))
</script>

<template>
  <button
    class="sell-card press"
    :aria-label="`${item.name}，现价 ${fmt(item.current)}，处 7 天 ${rankPct ?? '—'}% 高位，查看走势`"
    :title="peak ? `${item.name}：日内高位通常在 ${peak}（近 7 天同小时均价统计），建议在该时段分批挂卖` : `${item.name} 卖出信号`"
    @click="$emit('open')"
  >
    <span class="sl-head">
      <span
        class="sl-ic" :style="{ '--gd': gradeVar(item.grade) }" :title="`品级 ${item.grade}`"
      >
        <img
          v-if="item.pic" :src="picThumb(item.pic, 96)"
          alt="" width="26" height="24" loading="lazy" decoding="async"
          @error="hideImg"
        >
      </span>
      <b class="sl-name">{{ item.name }}</b>
      <span
        class="sl-rank"
        :title="rankPct != null ? `现价处近 7 天 ${rankPct}% 分位（卖出线 ≥${Math.round(sellMin * 100)}%）` : '分位数据不足'"
      >P{{ rankPct ?? '—' }}</span>
    </span>

    <span class="sl-hero">
      <span class="sl-price">
        <i class="sl-k">现价<i v-if="priceDir" class="sl-dir" :class="priceDir" aria-hidden="true">{{ priceDir === 'up' ? '▲' : '▼' }}</i></i>
        <b class="sl-num" :class="priceFlash">{{ fmt(item.current) }}</b>
      </span>
      <span v-if="peak" class="sl-peak">
        <svg class="sl-clock" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.5A6.5 6.5 0 1 0 8 14.5 6.5 6.5 0 0 0 8 1.5Zm.7 2.9v3.44l2.66 1.54-.7 1.2-3.36-1.94V4.4h1.4Z" fill="currentColor"/></svg>
        {{ peak }} 宜出
      </span>
    </span>

    <!-- 7 天分位轨道：红色渐变填充到现价位置，刻度 = 卖出线（rules 下发），
         与 SignalCard 区间游标 / 全表分位条同一视觉语言 -->
    <span
      class="sl-meter" role="img"
      :aria-label="rankPct != null ? `7 天分位 ${rankPct}%，贴近高位（卖出线 ≥${Math.round(sellMin * 100)}%）` : '分位数据不足'"
    >
      <i class="sl-track">
        <i v-if="rankPct != null" class="sl-fill" :style="{ width: `${rankPct}%` }"></i>
        <i class="sl-tick" :style="{ left: `${sellMin * 100}%` }"></i>
      </i>
    </span>
  </button>
</template>

<style scoped>
/* 卖出语义派生色统一 color-mix（真值 rgba 兜底，写法同 ttk PenMatrix）；
   可点卡 hover 上浮基准 translateY(-2px)，与 SignalCard 对齐 */
.sell-card {
  position: relative; isolation: isolate; /* 给 ::before 泛红叠层定位 + 独立层叠（z:-1 压在卡面之上、内容之下） */
  display: flex; flex-direction: column; gap: 10px;
  width: 100%; min-width: 0;
  padding: 12px 14px;
  text-align: left; cursor: pointer;
  color: var(--tx); font-family: inherit;
  background: linear-gradient(180deg, var(--card2) 0%, var(--card) 70%);
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  box-shadow: var(--edge-light);
  transition: transform var(--t-med) var(--ease), border-color var(--t-med) var(--ease), box-shadow var(--t-med) var(--ease);
}
/* hover 泛红面走独立叠层淡入：两段 linear-gradient 之间不可插值，原先直接换 background
   会在 lift / 描边缓动的同一帧里面色瞬跳（动与不动叠在一起不精致）；叠层只动 opacity，
   也落在动效红线（opacity/transform）内。border-radius 继承卡面圆角，inset:0 贴
   padding box 不压描边 */
.sell-card::before {
  content: '';
  position: absolute; inset: 0; z-index: -1;
  border-radius: inherit;
  background: linear-gradient(180deg, rgba(217, 106, 89, .12) 0%, transparent 70%);
  background: linear-gradient(180deg, color-mix(in srgb, var(--danger) 12%, transparent) 0%, transparent 70%);
  opacity: 0;
  transition: opacity var(--t-med) var(--ease);
  pointer-events: none;
}
/* :active 并入颜色/泛红（不含 transform）：hover 的泛红面 + 描边提亮在触屏
   （hover:none）下永不触发——「每个 hover 独享的信息都要有触屏等价物」，点按
   瞬间给同款强调（150ms 快档见下）；位移刻意不并——按住的 transform 归全局
   .press:active 的 scale(.98)「按实」，若在此重复声明 -2px 上浮（scoped
   特异性更高）会盖掉微缩，按压感反号。键盘 :focus-visible 亦同组 */
.sell-card:hover,
.sell-card:focus-visible,
.sell-card:active {
  border-color: rgba(217, 106, 89, .45);
  border-color: color-mix(in srgb, var(--danger) 45%, transparent);
  box-shadow: var(--edge-hover);
}
.sell-card:hover,
.sell-card:focus-visible {
  transform: translateY(-2px);
}
.sell-card:hover::before,
.sell-card:focus-visible::before,
.sell-card:active::before { opacity: 1; }
/* 按压「按实」的 scale(.98) 挂全局 .press（motion.css 状态类）；这里只留按压当帧的
   150ms 微交互档时长——按下时落回原位并微缩，松手沿卡片 hover 档（--t-med）缓动回
   lift 态；键盘 Enter/Space 与触屏点按同样命中 :active */
.sell-card:active {
  transition-duration: var(--t-fast);
}

/* ---------- 头部：切角图标匣（游戏同款品级染底 + 描边，口径同 SignalCard .sc-ic）
   + 弹名 + P 分位徽章（同 SignalCard .sc-head 族） ---------- */
.sl-head { display: flex; align-items: center; gap: 10px; min-width: 0; }
.sl-ic {
  position: relative; flex: none;
  width: 38px; height: 34px;
  display: grid; place-items: center;
  background: var(--deep);
  background: color-mix(in srgb, var(--gd, var(--faint)) 15%, var(--deep));
  border: 1px solid var(--line);
  border-color: color-mix(in srgb, var(--gd, var(--faint)) 45%, transparent);
  /* 右上切角：战术弹药匣轮廓，与 SignalCard .sc-ic 同族 */
  clip-path: polygon(0 0, calc(100% - 9px) 0, 100% 9px, 100% 100%, 0 100%);
}
.sl-ic img { width: 26px; height: 24px; object-fit: contain; }
.sl-name {
  flex: 1; min-width: 0;
  font-size: var(--fs-sm); font-weight: 600; color: var(--tx-strong);
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.sl-rank {
  flex: none;
  font-family: var(--mono); font-size: var(--fs-2xs);
  color: var(--danger); letter-spacing: .06em;
  border: 1px solid rgba(217, 106, 89, .4); background: rgba(217, 106, 89, .1);
  border-color: color-mix(in srgb, var(--danger) 40%, transparent);
  background: color-mix(in srgb, var(--danger) 10%, transparent);
  border-radius: var(--radius-pill); padding: 2px 9px;
}

/* ---------- 现价英雄行：大数在左、日内高位时段在右 ---------- */
.sl-hero { display: flex; align-items: flex-end; justify-content: space-between; gap: 10px; }
.sl-price { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.sl-k { font-family: var(--mono); font-size: var(--fs-micro); color: var(--faint); letter-spacing: .12em; }
.sl-num {
  font-family: var(--mono); font-size: var(--fs-xl); font-weight: 700;
  line-height: 1.1; color: var(--tx-strong);
  font-variant-numeric: tabular-nums;
  transition: color var(--t-slow) var(--ease);
}
/* 现价闪变：涨绿跌红（与图表 P25 绿 / P75 红的行情感位恒定一致），
   类挂 0.8s 后摘、色过渡 220ms 渐入渐出 */
.sl-num.up { color: var(--ok); }
.sl-num.down { color: var(--danger); }
/* 方向箭头：挂在「现价」标签行（不进数字列，列宽恒定）；micro 号指示符号 */
.sl-dir { font-style: normal; margin-left: 3px; font-size: var(--fs-micro); }
.sl-dir.up { color: var(--ok); }
.sl-dir.down { color: var(--danger); }
/* 日内高位时段：danger 素文本 + 时钟图标（不加胶囊描边——P 徽章与轨道已承担
   红色语义，卡内红块过多会互相稀释） */
.sl-peak {
  flex: none; display: inline-flex; align-items: center; gap: 5px;
  font-family: var(--mono); font-size: var(--fs-2xs); color: var(--danger);
  padding-bottom: 1px;
}
.sl-clock { width: 11px; height: 11px; flex: none; opacity: .85; }

/* ---------- 7 天分位轨道（同全表 .rank-bar 语言）：填充染卖出红，刻度=卖出线 ---------- */
.sl-meter { display: block; }
.sl-track { position: relative; display: block; height: 6px; background: var(--line2); border-radius: 4px; }
.sl-fill {
  position: absolute; top: 0; bottom: 0; left: 0;
  border-radius: 4px;
  background: linear-gradient(90deg, rgba(217, 106, 89, .45), var(--danger));
  background: linear-gradient(90deg, color-mix(in srgb, var(--danger) 45%, transparent), var(--danger));
}
.sl-tick {
  position: absolute; top: -2px; bottom: -2px; width: 1px;
  background: var(--line-hover);
}

/* 微交互过渡的 reduced-motion 关闭（hover 上浮降级为仅描边与面变化，泛红面瞬显；
   现价闪变降级为瞬时色跳，方向箭头不受影响本就静态；.press 按压微缩的 RM 由
   motion.css 文件尾统一兜底） */
@media (prefers-reduced-motion: reduce) {
  .sell-card, .sell-card::before { transition: none; }
  .sell-card:hover, .sell-card:focus-visible { transform: none; }
  .sl-num { transition: none; }
}
</style>
