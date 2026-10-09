<script setup>
// LootTable.vue — 物资点爆率表（工程师A）：legacy lootBody（L424-438）的声明式版本。
// 爆率为社区统计口径、非官方数据——口径说明由外层折叠列 note 保留。
defineProps({
  loot: { type: Array, required: true }, // [{ spot, items, rate }]
})
</script>

<template>
  <p v-if="!loot || !loot.length" class="loot-none">
    暂无可靠爆率数据：官方从未公布精确掉落率，社区亦无可靠统计，此处不做猜测。
  </p>
  <div v-else class="tbl-wrap">
    <table class="loot-table tbl">
      <thead>
        <tr>
          <th>物资点</th>
          <th>主要产出</th>
          <th>爆率与依据</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="(l, i) in loot" :key="i">
          <td class="td-spot">{{ l.spot }}</td>
          <td class="td-items">{{ l.items }}</td>
          <td class="td-rate">{{ l.rate }}</td>
        </tr>
      </tbody>
    </table>
  </div>
</template>

<style scoped>
/* 表格基座（表头/斑马纹/hover）走 base.css 全局 .tbl，此处仅保留本表特有布局 */
.tbl-wrap { overflow-x: auto; padding: 2px 10px 12px; }
.loot-table { min-width: 660px; }
.loot-table td { padding: 11px 10px; vertical-align: top; line-height: 1.7; }
.td-spot { font-weight: 600; color: var(--tx-strong); width: 26%; }
.td-items { color: var(--dim); width: 30%; }
.td-rate { color: var(--faint); font-size: var(--fs-xs); }
.loot-none { padding: 6px 16px 16px; color: var(--faint); font-size: var(--fs-sm); }
</style>
