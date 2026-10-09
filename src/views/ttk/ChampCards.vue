<script setup>
// 场景最快卡（legacy renderChamps L917-941）：ALL + 当前类别所属兵种各一张，
// picks 由父组件 computed 产出（label / c=最优组合 / top=ALL 高亮）。
import { CAL } from '../../data/ttk/calibers.js'
import { fmtMs } from './format.js'
import PenBadge from './PenBadge.vue'

defineProps({
  picks: { type: Array, required: true }, // {label, c=最优组合, top?, scen?="5级头" 场景标注}
})
</script>

<template>
  <div class="champs">
    <div v-for="p in picks" :key="p.label" class="champ" :class="{ top: p.top }">
      <div class="champ-label">{{ p.label }}</div>
      <div class="champ-gun">{{ p.c.gun.zh }}</div>
      <div class="champ-sub">
        <PenBadge :p="p.c.am.pen" />
        <span>{{ CAL[p.c.gun.cal].label }} · {{ p.c.am.n }} · {{ p.c.btk }} 发<template v-if="p.scen"> · {{ p.scen }}</template></span>
      </div>
      <div class="champ-ttk">{{ fmtMs(p.c.ttk) }}<small>TTK · {{ p.c.gun.rpm }} RPM</small></div>
    </div>
  </div>
</template>

<style scoped>
.champs {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(235px, 1fr));
  gap: var(--sp-3);
  margin: 18px 0 6px;
}
.champ {
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  background: var(--card);
  padding: 15px 17px 13px;
  position: relative;
  overflow: hidden;
  transition: border-color var(--t-med);
}
.champ:hover { border-color: var(--line-hover); }
.champ.top {
  border-color: var(--accent-dim);
  background: linear-gradient(135deg, var(--accent-bg), var(--card) 55%);
}
.champ.top:hover { border-color: var(--accent-dim); }
.champ-label {
  font-family: var(--mono);
  font-size: var(--fs-micro);
  letter-spacing: .3em;
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
@media (max-width: 860px) {
  .champs { grid-template-columns: 1fr; }
  .champ { padding: 13px 15px 11px; }
}
</style>
