<script setup>
// MapDetail.vue — 单图打法详情（工程师A）：简介/撤离点/资源路线/Boss/实战建议/来源 六折叠列
// + 出生点打法卡列表 + 物资点价值档位表。地图页（MapSection）与打法页（TacticsView）共用，
// 对应 legacy renderMap L769-790 的 blocks + 出生点 + 档位 三段。
import { ref } from 'vue'
import CollapseCol from '../../components/CollapseCol.vue'
import GuideBlocks from './GuideBlocks.vue'
import SpawnCard from './SpawnCard.vue'
import LootTable from './LootTable.vue'

defineProps({
  map: { type: Object, required: true },
})

/* 档位表保持收起（§6.2 默认展开策略），表头行 note 显示档位计数 */
const lootOpen = ref(false)
</script>

<template>
  <div class="map-detail">
    <GuideBlocks :map="map" />

    <div class="block-h">
      <span class="bht">出生点打法</span>
      <span class="bhline"></span>
      <span class="bhc">{{ map.guide.spawns.length }} 类主要出生点 · 点击展开</span>
    </div>
    <!-- §7.3 级联容器：IO 只观察 .reveal-group，子项入场按 --ri 错峰（base.css 全局规则） -->
    <div class="spawn-list reveal-group">
      <SpawnCard
        v-for="(s, i) in map.guide.spawns"
        :key="i"
        :spawn="s"
        :default-open="i === 0"
        :style="{ '--ri': i }"
      />
    </div>

    <div class="block-h">
      <span class="bht">物资点价值档位</span>
      <span class="bhline"></span>
      <span v-if="map.loot && map.loot.length" class="bhc">{{ map.loot.length }} 处物资点</span>
    </div>
    <div class="reveal">
      <CollapseCol :open="lootOpen" label="物资档位表" note="社区分级 · 非官方数据" @toggle="lootOpen = !lootOpen">
        <LootTable :loot="map.loot" />
      </CollapseCol>
    </div>
  </div>
</template>

<style scoped>
/* 小节标题（.block-h）走 base.css 全局；物资档位表口径说明沿用折叠列 note；
   折叠壳内容 padding（16/12）由 LootTable 自带，不再套 col-pad 双层 */
.spawn-list { display: flex; flex-direction: column; gap: 10px; }
</style>
