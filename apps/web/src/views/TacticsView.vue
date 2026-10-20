<script setup>
// TacticsView.vue — 打法页 '/tactics'（工程师A）。
// 数据与地图页同源（src/data/maps/*.json 的 guide / loot），图选择器走 ?map=slug query
// （hash 路由的 query 属路由状态，不属被禁的裸锚点 hash）；内容复用 MapDetail
// （= legacy makeCol/listBody/bossBody 折叠列 + makeSpawn 五段卡 + lootBody 档位表）。
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { MAPS } from '../data/mapIndex'
import { useReveal } from '../composables/useReveal'
import MapDetail from './maps/MapDetail.vue'

const route = useRoute()
const router = useRouter()
const rootRef = ref(null)
const { observeRoot } = useReveal()

const slug = computed(() => (MAPS.some((m) => m.slug === route.query.map) ? route.query.map : MAPS[0].slug))
const current = computed(() => MAPS.find((m) => m.slug === slug.value))

/* §QA 打法页缩略（16/9 cover）垂直裁切带：正方形 fig0 在 16/9 框内 cover 居中只显示
   图内 y 21.9%-78.1%，各图标注内容带不同——按各 fig0 标注像素分布（出生点编号/地名
   标签的 y 范围扫描）逐图定 object-position 纵向百分比，让内容带在框内居中：
   长弓溪谷/潮汐监狱底部编号标注不再贴底边，零号大坝顶部出生点编号不再被上缘裁切；
   未列出者（巴克什/航天基地标注贴满全图）保持居中 */
const EMBED_VPOS = { linghaodaba: '42%', changgongxigu: '55%', chaoxijianyu: '58%', hedianzhan: '48%' }
const embedPos = computed(() => '50% ' + (EMBED_VPOS[slug.value] || '50%'))

/* 标签页标题随当前图切换（TtkView 同款口径；卸载还原首页标题） */
const HOME_TITLE = '三角洲行动 · 战术图集'
watch(current, (m) => { document.title = m ? '三角洲行动 · ' + m.map + '打法手册' : HOME_TITLE }, { immediate: true })
onBeforeUnmount(() => { document.title = HOME_TITLE })

/* §6.2 切图滚顶：换图属场景切换非连续滚动，瞬时归位后 reveal 从顶自然级联
   （behavior 用 'instant'——base.css html{scroll-behavior:smooth} 下 'auto' 会
   跟随 CSS 值变成 1 秒级平滑倒带） */
watch(slug, () => {
  nextTick(() => {
    observeRoot(rootRef.value)
    window.scrollTo({ top: 0, behavior: 'instant' })
  })
})
onMounted(() => observeRoot(rootRef.value))

/* §6.2「查看交互大图」：跳回地图页对应 section——路由走 router.push，
   页内定位一律 scrollIntoView，禁止向地址栏 hash 写裸锚点（契约 5） */
async function gotoMapSection(target) {
  if (route.path !== '/') await router.push('/')
  await nextTick() /* 等 MapsView 挂载、6 个 section 渲染（静态 v-for，同步就绪） */
  const el = document.getElementById(target)
  if (el) el.scrollIntoView({ behavior: 'instant', block: 'start' }) /* 'instant' 同上：不随 CSS smooth 平滑滚 */
}
</script>

<template>
  <div ref="rootRef" class="tactics-page">
    <header class="wrap compact-head">
      <h1>打法手册</h1>
      <p class="meta">六图打法单独成页：先选图，再看该图的出生点思路与撤离细节。</p>
    </header>

    <nav class="topbar sticky-bar" aria-label="地图选择">
      <div class="pills">
        <!-- aria-current 手动按当前图判定：vue-router 的 exact-active 不看 query，
             六颗同 path 不同 query 的胶囊会被全部标 aria-current="page"，读屏无法辨别；
             手绑值经 fallthrough 覆盖 router-link 内部写入，未命中者属性被移除。
             replace：换图属筛选非导航，不写历史，返回键一步离开本页 -->
        <router-link
          v-for="m in MAPS"
          :key="m.slug"
          class="pill"
          :class="{ on: m.slug === slug }"
          :to="{ path: '/tactics', query: { map: m.slug } }"
          :aria-current="m.slug === slug ? 'page' : undefined"
          replace
        >{{ m.map }}</router-link>
      </div>
    </nav>

    <div class="wrap layout">
      <p class="cur-map reveal in">
        <span class="cur-num">{{ String(MAPS.indexOf(current) + 1).padStart(2, '0') }}</span>
        <span class="cur-name">{{ current.map }}</span>
        <span class="mode-tag">{{ current.mode }}</span>
      </p>

      <!-- §6.2 地图视觉：静态缩略 + 跳地图页交互大图，治首屏大面积空白；
           图框在首屏内，eager+fetchpriority=high 对齐站内「首图 eager」约定保 LCP -->
      <figure class="map-embed reveal in">
        <img :src="current.fig[0].src" :alt="current.map + ' 地图缩略图'" :style="{ objectPosition: embedPos }" loading="eager" fetchpriority="high" decoding="async" draggable="false">
        <button type="button" class="map-link" @click="gotoMapSection(current.slug)">查看交互大图 →</button>
      </figure>

      <div :key="slug">
        <MapDetail :map="current" />
      </div>
    </div>
  </div>
</template>

<style scoped>
/* 页头走 base.css .compact-head（单行式） */
.tactics-page { padding-bottom: var(--sp-6); }

/* 图选择器（样式沿用 legacy pills）；吸顶面板走 base.css .sticky-bar（§5.10 弃 blur），
   胶囊条限宽对齐 1240px 内容列（padding 28px 与 .wrap 同缘） */
.pills {
  display: flex;
  gap: var(--sp-2);
  overflow-x: auto;
  padding: 10px 28px;
  scrollbar-width: none;
  max-width: var(--wrap);
  margin: 0 auto;
}
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
  transition: color var(--t-med) var(--ease), border-color var(--t-med) var(--ease);
}
.pill:hover,
.pill:active { color: var(--tx); border-color: var(--line-hover); }
.pill.on { color: var(--accent); border-color: var(--accent-dim); background: var(--accent-bg); }

.layout { padding-top: var(--sp-5); }
.cur-map { display: flex; align-items: baseline; gap: var(--sp-4); margin-bottom: var(--sp-5); }
.cur-num { font-family: var(--mono); font-size: var(--fs-sm); color: var(--accent); letter-spacing: .08em; font-variant-numeric: tabular-nums; }
.cur-name { font-size: clamp(var(--fs-xl), 3vw, var(--fs-2xl)); font-weight: 700; letter-spacing: .02em; color: var(--tx-strong); }
.mode-tag {
  font-family: var(--mono);
  font-weight: 400;
  font-size: var(--fs-micro);
  letter-spacing: .12em;
  color: var(--dim);
  border: 1px solid var(--line);
  border-radius: var(--radius-pill);
  padding: var(--sp-1) var(--sp-3);
  transform: translateY(1px);
}

/* 地图缩略（§6.2）：16/9 静态缩略 + 右下跳转链；底幕 --deep 与图框同语言 */
.map-embed {
  position: relative;
  margin: 0 0 var(--sp-5);
  aspect-ratio: 16 / 9;
  background: var(--deep);
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  overflow: hidden;
  box-shadow: var(--edge-light);
}
.map-embed img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; user-select: none; -webkit-user-select: none; }
.map-link {
  position: absolute;
  right: var(--sp-3);
  bottom: var(--sp-3);
  display: inline-flex;
  align-items: center;
  padding: 6px 12px;
  border: 1px solid var(--line);
  border-radius: var(--radius);
  background: var(--scrim);
  backdrop-filter: blur(var(--panel-blur));
  -webkit-backdrop-filter: blur(var(--panel-blur));
  box-shadow: var(--shadow-sm);
  color: var(--accent);
  font-size: var(--fs-xs);
  letter-spacing: .04em;
  cursor: pointer;
  transition: color var(--t-med) var(--ease), border-color var(--t-med) var(--ease);
}
/* hover 不降亮：默认字即 --accent，hover 只提边一档；按下同 hover（次要按钮规范）。
   focus-visible 走 base.css 全局 2px --accent 外框，此处不覆盖 */
.map-link:hover,
.map-link:active { border-color: var(--line-hover); }

@media (prefers-reduced-motion: reduce) {
  .pill, .map-link { transition: none; }
}
</style>
