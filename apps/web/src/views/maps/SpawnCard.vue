<script setup>
// SpawnCard.vue — 出生点五段卡（工程师A）：legacy makeSpawn（L443-462）的声明式版本。
// 打法思路 / 注意事项 / 可架枪点位 / 需封烟路段 四宫格；默认收起，点击头行切换；
// 首张卡由父级 MapDetail 传 default-open 展开（§6.2）。
// 入场不挂 .reveal——由父级 .spawn-list reveal-group 容器按 --ri 错峰驱动（§7.3）。
import { ref } from 'vue'

const props = defineProps({
  spawn: { type: Object, required: true }, // { name, plan, watchOut, angles, smoke }
  defaultOpen: { type: Boolean, default: false },
})

const open = ref(props.defaultOpen)

const KVS = (s) => [
  ['打法思路', s.plan],
  ['注意事项', s.watchOut],
  ['可架枪点位', s.angles],
  ['需封烟路段', s.smoke],
]
</script>

<template>
  <article class="spawn-card" :class="{ open }">
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
/* legacy CSS L172-193（spawn cards），取值令牌化；卡片基底同 §5.2（面差+描边+顶缘高光） */
.spawn-list { display: flex; flex-direction: column; gap: 10px; }
.spawn-card {
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  background: var(--card);
  overflow: clip;
  box-shadow: var(--edge-light);
  transition: border-color var(--t-med) var(--ease), box-shadow var(--t-med) var(--ease);
}
.spawn-card:hover { border-color: var(--line-hover); box-shadow: var(--edge-hover); }
/* 展开态：提亮描边 + 左缘 2px --accent-dim 指示条（与 CollapseCol 统一语义，实色 --accent 留给冠军/最佳） */
.spawn-card.open { border-color: var(--line-hover); box-shadow: var(--edge-light), inset 2px 0 0 var(--accent-dim); }
.spawn-card.open:hover { box-shadow: var(--edge-hover), inset 2px 0 0 var(--accent-dim); }
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
  transition: background var(--t-med) var(--ease);
}
.spawn-head:hover { background: var(--row-hover); }
/* 按下态：面再抬一档（--lift），触屏无 hover 时按压可见（同 CollapseCol col-head） */
.spawn-head:active { background: var(--lift); }
.spawn-name { flex: 1; min-width: 0; line-height: 1.5; }
.chev { flex: none; color: var(--faint); transition: transform var(--t-collapse) var(--ease), color var(--t-fast) var(--ease); }
.spawn-card.open .chev { transform: rotate(180deg); color: var(--accent); }
.col-body {
  display: grid;
  grid-template-rows: 0fr;
  transition: grid-template-rows var(--t-collapse) var(--ease);
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
.kv p { font-size: var(--fs-sm); color: var(--dim); line-height: 1.85; text-align: left; margin: 0; }
@media (max-width: 680px) {
  .spawn-grid { grid-template-columns: 1fr; }
  .spawn-grid .kv:nth-child(odd) { border-right: 0; }
  .spawn-grid .kv:nth-child(-n + 2) { border-top: 1px solid var(--line2); }
  .spawn-grid .kv:first-child { border-top: 0; }
}
@media (prefers-reduced-motion: reduce) {
  .spawn-card, .spawn-head, .chev, .col-body { transition: none; }
}
</style>
