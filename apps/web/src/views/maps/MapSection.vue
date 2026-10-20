<script setup>
// MapSection.vue — 单图分区（工程师A）：legacy renderMap（L755-768）的 Vue 版。
// 结构：map-head 标题 → MapViewer（页内查看器）→ MapDetail（打法+档位）。
// section id = slug（scroll spy 与页内导航定位锚点；不写裸 hash，导航只 scrollIntoView）。
import MapViewer from './MapViewer.vue'
import MapDetail from './MapDetail.vue'

const props = defineProps({
  map: { type: Object, required: true },
  index: { type: Number, required: true },
})
const emit = defineEmits(['full'])

function onFull(idx) {
  emit('full', { map: props.map, idx })
}
</script>

<template>
  <section :id="map.slug" class="map-section">
    <header class="map-head reveal">
      <div class="map-num">{{ String(index + 1).padStart(2, '0') }}</div>
      <h2 class="map-title">
        <span>{{ map.map }}</span>
        <span class="mode-tag">{{ map.mode }}</span>
      </h2>
    </header>

    <!-- 首图 eager（LCP + 冒烟断言依赖），其余 lazy：首访只下载视口内图片 -->
    <MapViewer :map="map" :eager="index === 0" @full="onFull" />

    <MapDetail :map="map" />
  </section>
</template>

<style scoped>
/* legacy CSS L66-78（map section），取值令牌化；.reveal 走 base.css 全局 */
.map-section { padding: 58px 0 10px; border-top: 1px solid var(--line2); scroll-margin-top: 76px; }
@media (min-width: 1024px) { .map-section { scroll-margin-top: 20px; } }
.map-section:first-child { border-top: 0; }
.map-head { display: flex; align-items: baseline; gap: var(--sp-4); margin-bottom: 22px; }
.map-num { font-family: var(--mono); font-size: var(--fs-sm); color: var(--accent); letter-spacing: .08em; transform: translateY(-1px); }
.map-title {
  font-size: clamp(var(--fs-xl), 3vw, var(--fs-2xl));
  font-weight: 700;
  letter-spacing: .02em;
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  flex-wrap: wrap;
  color: var(--tx-strong);
}
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
</style>
