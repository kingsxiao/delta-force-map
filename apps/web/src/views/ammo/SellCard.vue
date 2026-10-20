<script setup>
/* SellCard — 卖出信号迷你卡：图标 + 弹名 + 分位说明 + 现价；
   整卡可点，emit('open') 由父级联动全表展开该弹种走势。
   左缘 2px 卖出红 + 纵向渐变面，hover 泛红上浮。
   副行附日内高位时段（7 天同小时均价统计，纯函数在 ./sellEta.js）。 */
import { computed } from 'vue'
import { picThumb } from '@shared/js/marketMeta.js'
import { predictSellEta, fmtPeak } from '@shared/js/sellEta.js'

const props = defineProps({
  item: { type: Object, required: true },
})
defineEmits(['open'])

const fmt = (n) => (Number.isFinite(n) ? Math.round(n).toLocaleString('zh-CN') : '—')
const gradeVar = (g) => (g >= 2 && g <= 6 ? `var(--lv${g})` : 'var(--faint)')
const hideImg = (e) => { e.target.style.display = 'none' }

/* 现价已在卖出区，回答「今天几点出」：日内高位时段 */
const peak = computed(() => {
  const e = predictSellEta(props.item)
  return e && e.peakStart != null ? fmtPeak(e.peakStart, e.peakEnd) : null
})
</script>

<template>
  <button
    class="sell-card"
    :aria-label="`${item.name}，现价 ${fmt(item.current)}，处 7 天 ${Math.round(item.rank * 100)}% 高位，查看走势`"
    :title="peak ? `${item.name}：日内高位通常在 ${peak}（近 7 天同小时均价统计），建议在该时段分批挂卖` : `${item.name} 卖出信号`"
    @click="$emit('open')"
  >
    <span class="sl-ic">
      <img
        v-if="item.pic" :src="picThumb(item.pic, 96)"
        alt="" width="28" height="24" loading="lazy" decoding="async"
        @error="hideImg"
      >
      <i class="sl-grade" :style="{ background: gradeVar(item.grade) }" :title="`品级 ${item.grade}`"></i>
    </span>
    <span class="sl-body">
      <b class="sl-name">{{ item.name }}</b>
      <span class="sl-sub">7 天 {{ Math.round(item.rank * 100) }}% 高位<template v-if="peak"> · {{ peak }} 宜出</template><template v-else> · 建议出货</template></span>
    </span>
    <span class="sl-price">
      <i>现价</i>
      <b>{{ fmt(item.current) }}</b>
    </span>
  </button>
</template>

<style scoped>
/* 卖出语义派生色统一 color-mix（真值 rgba 兜底，写法同 ttk PenMatrix）；
   可点卡 hover 上浮基准 translateY(-2px)，与 SignalCard 对齐 */
.sell-card {
  display: flex; align-items: center; gap: var(--sp-2);
  width: 100%; min-width: 0;
  padding: 9px 12px;
  text-align: left; cursor: pointer;
  color: var(--tx); font-family: inherit;
  background: linear-gradient(180deg, var(--card2) 0%, var(--card) 70%);
  border: 1px solid var(--line);
  border-left: 2px solid rgba(217, 106, 89, .45);
  border-left: 2px solid color-mix(in srgb, var(--danger) 45%, transparent);
  border-radius: var(--radius);
  box-shadow: var(--edge-light);
  transition: transform var(--t-med) var(--ease), border-color var(--t-med) var(--ease), background var(--t-med) var(--ease), box-shadow var(--t-med) var(--ease);
}
.sell-card:hover,
.sell-card:focus-visible {
  transform: translateY(-2px);
  border-color: rgba(217, 106, 89, .45);
  border-color: color-mix(in srgb, var(--danger) 45%, transparent);
  border-left-color: var(--danger);
  background: linear-gradient(180deg, rgba(217, 106, 89, .12) 0%, var(--card) 70%);
  background: linear-gradient(180deg, color-mix(in srgb, var(--danger) 12%, transparent) 0%, var(--card) 70%);
  box-shadow: var(--edge-hover);
}

.sl-ic {
  position: relative; flex: none;
  width: 32px; height: 28px;
  display: grid; place-items: center;
}
.sl-ic img { width: 28px; height: 24px; object-fit: contain; }
.sl-grade {
  position: absolute; left: -2px; bottom: -2px;
  width: 6px; height: 6px; transform: rotate(45deg);
  box-shadow: 0 0 0 2px var(--card);
}
.sl-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
.sl-name {
  font-size: var(--fs-sm); font-weight: 600; color: var(--tx-strong);
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.sl-sub {
  font-family: var(--mono); font-size: var(--fs-2xs);
  color: var(--danger); opacity: .85;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.sl-price {
  flex: none; display: flex; flex-direction: column; align-items: flex-end; gap: 1px;
}
.sl-price i { font-style: normal; font-family: var(--mono); font-size: var(--fs-micro); color: var(--faint); }
.sl-price b { font-family: var(--mono); font-size: var(--fs-md); color: var(--tx-strong); font-variant-numeric: tabular-nums; }

/* 微交互过渡的 reduced-motion 关闭（hover 上浮降级为仅描边/面变化） */
@media (prefers-reduced-motion: reduce) {
  .sell-card { transition: none; }
  .sell-card:hover, .sell-card:focus-visible { transform: none; }
}
</style>
