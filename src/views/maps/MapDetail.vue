<script setup>
// MapDetail.vue — 单图打法详情（工程师A）：简介/撤离点/资源路线/Boss/实战建议/来源 六折叠列
// + 出生点打法卡列表 + 物资点爆率表。地图页（MapSection）与打法页（TacticsView）共用，
// 对应 legacy renderMap L769-790 的 blocks + 出生点 + 爆率 三段。
import { ref } from 'vue'
import CollapseCol from '../../components/CollapseCol.vue'
import GuideBlocks from './GuideBlocks.vue'
import SpawnCard from './SpawnCard.vue'
import LootTable from './LootTable.vue'

defineProps({
  map: { type: Object, required: true },
})

const lootOpen = ref(false)
</script>

<template>
  <div class="map-detail">
    <GuideBlocks :map="map" />

    <div class="block-h">
      <span class="bht">出生点打法</span>
      <span class="bhline"></span>
      <span class="bhc">{{ map.guide.spawns.length }} 个出生点</span>
    </div>
    <div class="spawn-list">
      <SpawnCard v-for="(s, i) in map.guide.spawns" :key="i" :spawn="s" />
    </div>

    <div class="block-h">
      <span class="bht">物资点爆率</span>
      <span class="bhline"></span>
      <span v-if="map.loot && map.loot.length" class="bhc">{{ map.loot.length }} 处物资点</span>
    </div>
    <div class="reveal">
      <CollapseCol :open="lootOpen" label="爆率表" note="社区统计 · 非官方数据" @toggle="lootOpen = !lootOpen">
        <div class="col-pad">
          <LootTable :loot="map.loot" />
        </div>
      </CollapseCol>
    </div>
  </div>
</template>

<style scoped>
/* 小节标题（.block-h）走 base.css 全局；爆率表口径说明沿用折叠列 note */
.spawn-list { display: flex; flex-direction: column; gap: 10px; }
.col-pad { padding: 2px 16px 16px; }
</style>
