<script setup>
// TacticsView.vue — 打法页 '/tactics'（工程师A）。
// 数据与地图页同源（src/data/maps/*.json 的 guide / loot），图选择器走 ?map=slug query
// （hash 路由的 query 属路由状态，不属被禁的裸锚点 hash）；内容复用 MapDetail
// （= legacy makeCol/listBody/bossBody 折叠列 + makeSpawn 五段卡 + lootBody 爆率表）。
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { MAPS } from '../data/mapIndex'
import { useReveal } from '../composables/useReveal'
import MapDetail from './maps/MapDetail.vue'

const route = useRoute()
const rootRef = ref(null)
const { observeRoot } = useReveal()

const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches

const slug = computed(() => (MAPS.some((m) => m.slug === route.query.map) ? route.query.map : MAPS[0].slug))
const current = computed(() => MAPS.find((m) => m.slug === slug.value))

/* 标签页标题随当前图切换（TtkView 同款口径；卸载还原首页标题） */
const HOME_TITLE = '三角洲行动 · 地图与打法详解'
watch(current, (m) => { document.title = m ? '三角洲行动 · ' + m.map + '打法手册' : HOME_TITLE }, { immediate: true })
onBeforeUnmount(() => { document.title = HOME_TITLE })

watch(slug, () => {
  nextTick(() => {
    observeRoot(rootRef.value)
    window.scrollTo({ top: 0, behavior: reduced ? 'auto' : 'smooth' })
  })
})
onMounted(() => observeRoot(rootRef.value))
</script>

<template>
  <div ref="rootRef" class="tactics-page">
    <header class="site-head">
      <div class="wrap">
        <p class="kicker">DELTA FORCE · TACTICS</p>
        <h1>打法手册</h1>
        <p class="lede">按图索引的实战打法：出生点思路、撤离点、资源路线、Boss 情报与物资爆率参考。</p>
        <p class="meta">数据整理自公开资料（2026-10 版本） · 爆率为社区统计口径，非官方数据</p>
      </div>
    </header>

    <nav class="topbar" aria-label="地图选择">
      <div class="pills">
        <router-link
          v-for="m in MAPS"
          :key="m.slug"
          class="pill"
          :class="{ on: m.slug === slug }"
          :to="{ path: '/tactics', query: { map: m.slug } }"
        >{{ m.map }}</router-link>
      </div>
    </nav>

    <div class="wrap layout">
      <p class="cur-map reveal in">
        <span class="cur-num">{{ String(MAPS.indexOf(current) + 1).padStart(2, '0') }}</span>
        <span class="cur-name">{{ current.map }}</span>
        <span class="mode-tag">{{ current.mode }}</span>
      </p>

      <div :key="slug">
        <MapDetail :map="current" />
      </div>
    </div>
  </div>
</template>

<style scoped>
.tactics-page { padding-bottom: 30px; }
.site-head { padding: 78px 0 46px; border-bottom: 1px solid var(--line2); }
/* 页头字级/眉题/导语走 base.css 全局 .kicker/.lede/.meta 与 h1 规则 */

/* 图选择器（样式沿用 legacy pills） */
.topbar {
  position: sticky;
  top: 0;
  z-index: var(--z-header);
  background: var(--panel);
  backdrop-filter: blur(10px);
  -webkit-backdrop-filter: blur(10px);
  border-bottom: 1px solid var(--line2);
}
.pills { display: flex; gap: var(--sp-2); overflow-x: auto; padding: 10px 20px; scrollbar-width: none; }
.pills::-webkit-scrollbar { display: none; }
.pill {
  flex: none;
  padding: 7px 15px;
  border-radius: var(--radius-pill);
  border: 1px solid var(--line);
  background: var(--bg2);
  color: var(--dim);
  font-size: var(--fs-xs);
  text-decoration: none;
  white-space: nowrap;
  transition: color var(--t-med), border-color var(--t-med);
}
.pill:hover { color: var(--tx); border-color: var(--line-hover); }
.pill.on { color: var(--accent); border-color: var(--accent-dim); background: var(--accent-bg); }

.layout { padding-top: 34px; }
.cur-map { display: flex; align-items: baseline; gap: var(--sp-4); margin-bottom: 22px; }
.cur-num { font-family: var(--mono); font-size: var(--fs-sm); color: var(--accent); letter-spacing: .08em; }
.cur-name { font-size: clamp(var(--fs-xl), 3vw, var(--fs-2xl)); font-weight: 700; letter-spacing: .02em; color: var(--tx-strong); }
.mode-tag {
  font-family: var(--mono);
  font-weight: 400;
  font-size: var(--fs-micro);
  letter-spacing: .12em;
  color: var(--dim);
  border: 1px solid var(--line);
  border-radius: var(--radius-pill);
  padding: 3px 11px;
  transform: translateY(1px);
}

@media (prefers-reduced-motion: reduce) {
  .pill { transition: none; }
}
</style>
