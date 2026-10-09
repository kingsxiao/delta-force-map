<script setup>
// SpawnCard.vue — 出生点五段卡（工程师A）：legacy makeSpawn（L443-462）的声明式版本。
// 打法思路 / 需要注意 / 能抽过点的位置 / 哪里要封烟 四宫格；默认收起，点击头行切换。
import { ref } from 'vue'

defineProps({
  spawn: { type: Object, required: true }, // { name, plan, watchOut, angles, smoke }
})

const open = ref(false)

const KVS = (s) => [
  ['打法思路', s.plan],
  ['需要注意', s.watchOut],
  ['能抽过点的位置', s.angles],
  ['哪里要封烟', s.smoke],
]
</script>

<template>
  <article class="spawn-card reveal" :class="{ open }">
    <button class="spawn-head" type="button" :aria-expanded="String(open)" @click="open = !open">
      <span class="spawn-name">{{ spawn.name }}</span>
      <svg class="chev" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
        <path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>
    <div class="col-body">
      <div class="col-inner">
        <div class="spawn-grid">
          <div v-for="kv in KVS(spawn)" :key="kv[0]" class="kv">
            <div class="kv-label">{{ kv[0] }}</div>
            <p>{{ kv[1] || '—' }}</p>
          </div>
        </div>
      </div>
    </div>
  </article>
</template>

<style scoped>
/* legacy CSS L172-193（spawn cards），取值令牌化；.reveal 走 base.css 全局 */
.spawn-list { display: flex; flex-direction: column; gap: 10px; }
.spawn-card {
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  background: var(--card);
  overflow: clip;
  transition: border-color var(--t-med);
}
.spawn-card:hover { border-color: var(--line-hover); }
.spawn-card.open { border-color: var(--line-hover); }
.spawn-head {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  width: 100%;
  padding: 14px 16px;
  background: none;
  border: 0;
  color: var(--tx-strong);
  cursor: pointer;
  text-align: left;
  font-size: var(--fs-md);
  font-weight: 600;
  transition: background var(--t-med);
}
.spawn-head:hover { background: var(--row-hover); }
.spawn-name { flex: 1; min-width: 0; line-height: 1.5; }
.chev { flex: none; color: var(--faint); transition: transform .25s var(--ease); }
.spawn-card.open .chev { transform: rotate(180deg); color: var(--accent); }
.col-body {
  display: grid;
  grid-template-rows: 0fr;
  transition: grid-template-rows .25s var(--ease);
}
.spawn-card.open .col-body { grid-template-rows: 1fr; }
.col-inner { overflow: hidden; min-height: 0; }
.spawn-grid { display: grid; grid-template-columns: 1fr 1fr; border-top: 1px solid var(--line2); }
.kv { padding: 14px 16px 16px; border-top: 1px solid var(--line2); }
.spawn-grid .kv:nth-child(-n + 2) { border-top: 0; }
.spawn-grid .kv:nth-child(odd) { border-right: 1px solid var(--line2); }
.kv-label {
  font-family: var(--mono);
  font-size: var(--fs-micro);
  letter-spacing: .24em;
  color: var(--accent);
  margin-bottom: 8px;
}
.kv p { font-size: var(--fs-sm); color: var(--dim); line-height: 1.85; text-align: justify; margin: 0; }
@media (max-width: 700px) {
  .spawn-grid { grid-template-columns: 1fr; }
  .spawn-grid .kv:nth-child(odd) { border-right: 0; }
  .spawn-grid .kv:nth-child(-n + 2) { border-top: 1px solid var(--line2); }
  .spawn-grid .kv:first-child { border-top: 0; }
}
@media (prefers-reduced-motion: reduce) {
  .spawn-head, .chev, .col-body { transition: none; }
}
</style>
