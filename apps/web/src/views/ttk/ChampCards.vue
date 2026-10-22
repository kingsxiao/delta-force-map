<script setup>
// 场景最快卡（§6.3：ALL + 类别卡 ≤3 张，一行 4 卡），
// picks 由父组件 computed 产出（label / c=最优组合 / top=ALL 高亮 / scen="5 级头" 场景标注）。
import { CAL } from '../../data/ttk/calibers.js'
import { fmtMs } from './format.js'
import PenBadge from './PenBadge.vue'

defineProps({
  picks: { type: Array, required: true },
  delay: { type: Number, default: 0 }, // 展示层扳机延迟（ms）：与排行行同口径等量平移
})
</script>

<template>
  <!-- .champ 挂 --ri 供容器级级联错峰（§7.3） -->
  <div class="champs">
    <div v-for="(p, i) in picks" :key="p.label" class="champ" :class="{ top: p.top }" :style="{ '--ri': i }">
      <div class="champ-label">{{ p.label }}</div>
      <div class="champ-gun">{{ p.c.gun.zh }}</div>
      <div class="champ-sub">
        <PenBadge :p="p.c.am.pen" solid />
        <span>{{ CAL[p.c.gun.cal].label }} · {{ p.c.am.n }} · {{ p.c.btk }} 发<template v-if="p.scen"> · {{ p.scen }}</template></span>
      </div>
      <div class="champ-ttk">{{ fmtMs(p.c.ttk + delay) }}<small>TTK · {{ p.c.gun.rpm }} RPM</small></div>
    </div>
  </div>
</template>

<style scoped>
/* 一行 4 卡（§6.3：repeat(4) 治 auto-fit 末行参差）；≤820 两列、≤680 单列；上距 12 促排行表进首屏 */
.champs {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: var(--sp-3);
  margin: var(--sp-3) 0 var(--sp-2);
}
.champ {
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  background: var(--card);
  box-shadow: var(--edge-light);
  padding: 15px 17px 13px;
  position: relative;
  overflow: hidden;
  transition: border-color var(--t-med) var(--ease), box-shadow var(--t-med) var(--ease);
}
.champ:hover {
  border-color: var(--line-hover);
  box-shadow: var(--edge-hover);
}
.champ.top {
  border-color: var(--accent-dim);
  background: linear-gradient(135deg, var(--accent-bg), var(--card) 55%);
}
.champ.top:hover { border-color: var(--accent-soft); }
.champ-label {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  letter-spacing: .2em;
  color: var(--faint);
  margin-bottom: 9px;
}
.champ.top .champ-label { color: var(--accent); }
.champ-gun {
  font-size: var(--fs-lg);
  font-weight: 700;
  letter-spacing: .01em;
  color: var(--tx-strong);
}
.champ-sub {
  font-size: var(--fs-xs);
  color: var(--dim);
  margin-top: 3px;
  display: flex;
  align-items: center;
  gap: 7px;
  flex-wrap: wrap;
}
.champ-ttk {
  font-family: var(--mono);
  font-size: var(--fs-display);
  font-weight: 600;
  color: var(--accent);
  margin-top: 9px;
  letter-spacing: .02em;
  font-variant-numeric: tabular-nums;
}
.champ-ttk small {
  font-size: var(--fs-2xs);
  color: var(--faint);
  font-weight: 400;
  margin-left: 5px;
  letter-spacing: .08em;
}
@media (max-width: 820px) {
  .champs { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .champ { padding: 13px 15px 11px; }
}
@media (max-width: 680px) {
  .champs { grid-template-columns: 1fr; }
}
@media (prefers-reduced-motion: reduce) {
  .champ { transition: none; }
}
</style>
