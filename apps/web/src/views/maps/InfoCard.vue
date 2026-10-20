<script setup>
// InfoCard.vue — 标注信息卡（工程师A）：legacy openCard（L667-711）的声明式版本。
// 带 gl 的物资点附档位行；带 gs 的出生点附「展开该出生点打法」联动（gs → guide.spawns[gs]，
// legacy L691）。展开/收起后 emit('expand') 交父级重算卡片定位（legacy 内直接 positionCard）。
import { ref, computed } from 'vue'
import { HS_TYPES, HS_TCOL } from '../../composables/useViewer'

const props = defineProps({
  spot: { type: Object, default: null },
  map: { type: Object, required: true },
})
const emit = defineEmits(['close', 'expand'])

const exp = ref(false)
const lootRow = computed(() =>
  props.spot && props.spot.gl != null && props.map.loot && props.map.loot[props.spot.gl]
    ? props.map.loot[props.spot.gl]
    : null,
)
const guideSpawn = computed(() =>
  props.spot && props.spot.gs != null && props.map.guide.spawns[props.spot.gs]
    ? props.map.guide.spawns[props.spot.gs]
    : null,
)

function spawnKvs(g) {
  return [
    ['打法思路', g.plan],
    ['注意事项', g.watchOut],
    ['可架枪点位', g.angles],
    ['需封烟路段', g.smoke],
  ]
}

function toggleExp() {
  exp.value = !exp.value
  emit('expand', exp.value)
}
</script>

<template>
  <aside v-if="spot" class="hs-card" :class="{ exp }">
    <div class="hd">
      <span class="tag" :style="{ background: HS_TCOL[spot.type] }">{{ HS_TYPES[spot.type] }}</span>
      <button
        class="x"
        type="button"
        aria-label="关闭"
        title="关闭"
        @pointerdown.stop
        @click="$emit('close')"
      >
        <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
          <path d="M3.5 3.5l9 9M12.5 3.5l-9 9" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
        </svg>
      </button>
    </div>
    <h4>{{ spot.name }}</h4>
    <p class="note">{{ spot.note }}</p>

    <div v-if="lootRow" class="rows">
      <div class="kv">
        <div class="kv-label">主要产出</div>
        <p>{{ lootRow.items }}</p>
      </div>
      <div class="kv">
        <div class="kv-label">档位与依据</div>
        <p>{{ lootRow.rate }}</p>
      </div>
    </div>

    <template v-if="guideSpawn">
      <button class="more-btn" type="button" @click="toggleExp">
        {{ exp ? '收起' : '展开该出生点打法' }}
      </button>
      <div class="hs-more">
        <div class="hs-more-clip">
          <div class="rows">
            <div v-for="kv in spawnKvs(guideSpawn)" :key="kv[0]" class="kv">
              <div class="kv-label">{{ kv[0] }}</div>
              <p>{{ kv[1] || '—' }}</p>
            </div>
          </div>
        </div>
      </div>
    </template>
  </aside>
</template>

<style scoped>
/* legacy CSS L112-135（.hs-card），取值令牌化。
   面底 --panel-solid + --shadow-md + --radius-lg（§5.8，浮在地图之上的信息层）。
   入场（§5.8）：父级 v-show 从 display:none 翻可见时 CSS animation 重播，
   只动 transform/opacity 不动布局轴（定位由内联 left/top 承担）。 */
.hs-card {
  position: absolute;
  z-index: 6;
  width: min(300px, 88%);
  background: var(--panel-solid);
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  box-shadow: var(--shadow-md);
  pointer-events: auto;
  max-height: 64%;
  overflow-y: auto;
  scrollbar-width: thin;
  animation: hs-card-in var(--t-fast) var(--ease);
}
/* 展开态：浮层投影保留 + 左缘 2px --accent-dim 指示条（与 CollapseCol/SpawnCard 统一语义） */
.hs-card.exp { box-shadow: var(--shadow-md), inset 2px 0 0 var(--accent-dim); }
@keyframes hs-card-in {
  from { opacity: 0; transform: translateY(6px) scale(.98); }
  to   { opacity: 1; transform: none; }
}
.hd { display: flex; align-items: center; gap: var(--sp-2); padding: 10px 12px 0; }
.tag {
  flex: none;
  font-family: var(--mono);
  font-size: var(--fs-micro);
  letter-spacing: .14em;
  padding: 2.5px 8px;
  border-radius: var(--radius-pill);
  color: var(--bg);
  font-weight: 700;
}
.x {
  margin-left: auto;
  flex: none;
  width: 22px;
  height: 22px;
  border: 0;
  border-radius: var(--radius-sm);
  background: none;
  color: var(--faint);
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  transition: color var(--t-fast) var(--ease), background var(--t-fast) var(--ease);
}
.x svg { display: block; }
.x:hover,
.x:active { color: var(--tx); background: var(--lift); }
h4 { font-size: var(--fs-sm); line-height: 1.5; margin: 9px 12px 0; padding-right: 16px; font-weight: 600; color: var(--tx-strong); }
.note { margin: 6px 0 0; padding: 0 12px 11px; font-size: var(--fs-xs); color: var(--dim); line-height: 1.7; }
.rows { border-top: 1px solid var(--line2); }
.kv { padding: 8px 12px; }
.kv + .kv { border-top: 1px solid var(--line2); }
.kv-label {
  font-family: var(--mono);
  font-size: var(--fs-micro);
  letter-spacing: .22em;
  color: var(--accent);
  margin-bottom: 4px;
}
.kv p { margin: 0; font-size: var(--fs-xs); color: var(--dim); line-height: 1.65; text-align: left; }
.more-btn {
  display: block;
  width: calc(100% - 24px);
  margin: 0 12px 10px;
  padding: 6px 0;
  border: 1px solid var(--line);
  border-radius: var(--radius);
  background: none;
  color: var(--accent);
  font-size: var(--fs-xs);
  letter-spacing: .06em;
  cursor: pointer;
  transition: border-color var(--t-fast) var(--ease), background var(--t-fast) var(--ease);
}
/* 次要按钮：hover/按下 边 --accent-dim + 底 --accent-bg（边面同改，一眼可辨） */
.more-btn:hover,
.more-btn:active { border-color: var(--accent-dim); background: var(--accent-bg); }
/* 展开与 SpawnCard / CollapseCol 同构：grid-rows 0fr→1fr（§5.7），时长统一 var(--t-collapse) */
.hs-more {
  display: grid;
  grid-template-rows: 0fr;
  transition: grid-template-rows var(--t-collapse) var(--ease);
}
.hs-card.exp .hs-more { grid-template-rows: 1fr; }
.hs-more-clip { overflow: hidden; min-height: 0; }
.exp .more-btn { color: var(--faint); border-color: var(--line2); }
/* 展开（「收起」）态 hover：保持次要按钮反馈——字提亮一档 + 边 --line-hover + 面 --lift，
   覆盖上面的默认 hover（源码序在后，避免 accent-bg 底配 faint 字的混搭） */
.exp .more-btn:hover,
.exp .more-btn:active { color: var(--dim); border-color: var(--line-hover); background: var(--lift); }
@media (prefers-reduced-motion: reduce) {
  .hs-card { animation: none; }
  .hs-more, .x, .more-btn { transition: none; }
}
</style>
