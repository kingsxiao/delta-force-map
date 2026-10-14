<script setup>
// MapsView.vue — 地图页 '/'（工程师A）：legacy index.html 骨架（L275-320）+
// 导航 / scroll spy / reveal（L793-854）的 Vue 版。
// 迁移强制动作：legacy L805 / L812 的 history.replaceState(null,'','#'+slug) 不迁移——
// hash 路由下裸 '#slug' 会被当作路由路径（刷新/回退无匹配路由），页内锚点一律 scrollIntoView；
// active 高亮由滚动位置计算（legacy setActive 的 href 比对改为 scroll spy）。
import { onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { MAPS } from '../data/mapIndex'
import { useReveal } from '../composables/useReveal'
import MapSection from './maps/MapSection.vue'
import MapLightbox from './maps/MapLightbox.vue'
import FxCanvas from './maps/FxCanvas.vue'

const rootRef = ref(null)
const { observeRoot } = useReveal()

const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches
const scrollMode = () => (reduced ? 'auto' : 'smooth')

/* §6.1 hero 数据大数带：一律数据插值、禁止手写；只统计本页内容
   （hotspots / 出生点打法卡 / 资源路线 / 撤离方案），不掺其他页面数据 */
const hsTotal = MAPS.reduce((n, m) => n + m.hs.length, 0)
const spawnCards = MAPS.reduce((n, m) => n + m.guide.spawns.length, 0)
const lootRoutes = MAPS.reduce((n, m) => n + m.guide.lootRoutes.length, 0)
const exitPlans = MAPS.reduce((n, m) => n + m.guide.extractions.length, 0)

/* §QA 两轮点名（卡片网格明度断层）：六张 fig0 缩略可见带（图内 y≈38-62%，44px 条）
   实测亮度差异大（90/52/39/82/45/78），无遮罩参与——按均值统一到 ~78 基线，
   逐图 brightness 增益（>1 为提亮、<1 为压暗），消除 05 潮汐监狱等暗卡断层 */
const THUMB_GAIN = {
  linghaodaba: 0.86,
  changgongxigu: 1.5,
  bakeshi: 2.0,
  hangtianjidi: 0.96,
  chaoxijianyu: 1.9,
  hedianzhan: 1.0,
}
function thumbFilter(slug) {
  const g = THUMB_GAIN[slug]
  /* 重提亮（≥1.5）会稀释对比度显灰蒙，补一小档 contrast 抵消（视觉复核意见） */
  return g && g !== 1 ? `brightness(${g})${g >= 1.5 ? ' contrast(1.04)' : ''}` : 'none'
}

/* ---- 页内导航（scrollIntoView only，不写裸 hash） ---- */
function scrollToSection(slug) {
  const sec = document.getElementById(slug)
  if (sec) sec.scrollIntoView({ behavior: scrollMode(), block: 'start' })
}

/* ---- scroll spy（legacy onScroll L823-838；返回顶部由全站 BackTop 组件承担） ---- */
const activeSlug = ref(MAPS[0].slug)
let ticking = false
function onScroll() {
  ticking = false
  const probe = window.innerHeight * 0.35
  let cur = MAPS[0].slug
  for (const m of MAPS) {
    const sec = document.getElementById(m.slug)
    if (sec && sec.getBoundingClientRect().top <= probe) cur = m.slug
  }
  if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4) {
    cur = MAPS[MAPS.length - 1].slug
  }
  activeSlug.value = cur
}
function onScrollThrottled() {
  if (!ticking) {
    ticking = true
    requestAnimationFrame(onScroll)
  }
}

/* ---- 灯箱（全局单例；MapSection 的「放大查看」按钮打开） ---- */
const lb = reactive({ open: false, map: null, idx: 0 })
function openLightbox({ map, idx }) {
  lb.map = map
  lb.idx = idx
  lb.open = true
}

onMounted(() => {
  window.addEventListener('scroll', onScrollThrottled, { passive: true })
  observeRoot(rootRef.value)
  onScroll()
})
onBeforeUnmount(() => {
  window.removeEventListener('scroll', onScrollThrottled)
})
</script>

<template>
  <div ref="rootRef" class="maps-page">
    <header class="site-head">
      <FxCanvas mode="hero" canvas-id="fxHero" />
      <div class="wrap">
        <div class="hero-main">
          <p class="kicker">DELTA FORCE · OPERATIONS ATLAS</p>
          <h1>三角洲行动 · 地图与打法</h1>
          <p class="lede">
            六张烽火地带地图的标注大图与实战打法：出生点思路、撤离、资源路线、Boss
            情报与物资档位。地图支持拖拽缩放与标注点选，双击或右下角放大按钮可查看大图。
          </p>
          <p class="meta">数据整理自公开资料（2026-10 版本） · 物资价值为社区主观分级，非官方数据</p>
          <p class="head-cta">
            <a class="cta" href="#map-index" @click.prevent="scrollToSection('map-index')">开始浏览地图 ↓</a>
          </p>
        </div>
        <div class="hero-stats" aria-label="地图数据概览">
          <p class="stat">
            <span class="stat-num">{{ hsTotal }}</span><span class="stat-label">个标注点位</span>
          </p>
          <p class="stat">
            <span class="stat-num">{{ spawnCards }}</span><span class="stat-label">张出生点打法</span>
          </p>
          <p class="stat">
            <span class="stat-num">{{ lootRoutes }}</span><span class="stat-label">条资源路线</span>
          </p>
          <p class="stat">
            <span class="stat-num">{{ exitPlans }}</span><span class="stat-label">条撤离方案</span>
          </p>
        </div>
      </div>
    </header>

    <nav class="topbar sticky-bar" aria-label="地图导航">
      <div class="pills">
        <a
          v-for="m in MAPS"
          :key="m.slug"
          class="pill"
          :class="{ on: activeSlug === m.slug }"
          :href="'#' + m.slug"
          @click.prevent="scrollToSection(m.slug)"
        >{{ m.map }}</a>
      </div>
    </nav>

    <!-- 六图索引（§6.1）：桌面补首屏总览、移动端补 <1024px 无索引的缺环；不新增 .hs / .map-section -->
    <nav id="map-index" class="wrap map-index reveal" aria-label="地图索引">
      <a
        v-for="(m, i) in MAPS"
        :key="m.slug"
        class="mi-card"
        :href="'#' + m.slug"
        @click.prevent="scrollToSection(m.slug)"
      >
        <span class="mi-thumb"><img :src="m.fig[0].src" :alt="m.map + ' 缩略图'" :style="{ filter: thumbFilter(m.slug) }" loading="lazy" decoding="async"></span>
        <span class="mi-num">{{ String(i + 1).padStart(2, '0') }}</span>
        <span class="mi-name">{{ m.map }}</span>
        <span class="mi-mode">{{ m.mode }}</span>
      </a>
    </nav>

    <div id="top" class="wrap layout">
      <aside class="sidenav" aria-label="地图导航">
        <p class="sidenav-title">烽火地带 / MAPS</p>
        <nav class="sidenav-list">
          <a
            v-for="(m, i) in MAPS"
            :key="m.slug"
            class="nav-item"
            :class="{ on: activeSlug === m.slug }"
            :href="'#' + m.slug"
            @click.prevent="scrollToSection(m.slug)"
          >
            <span class="nav-num">{{ String(i + 1).padStart(2, '0') }}</span>
            <span class="nav-name">{{ m.map }}</span>
            <span class="nav-mode">{{ m.mode }}</span>
          </a>
        </nav>
        <p class="sidenav-title sn-gap">资料 / DATA</p>
        <router-link class="nav-item" to="/ttk">
          <span class="nav-num">↗</span>
          <span class="nav-name">TTK 排行</span>
          <span class="nav-mode">全枪械 · 7 类武器</span>
        </router-link>
      </aside>

      <main>
        <MapSection v-for="(m, i) in MAPS" :key="m.slug" :map="m" :index="i" @full="openLightbox" />
      </main>
    </div>

    <MapLightbox :open="lb.open" :map="lb.map" :start-idx="lb.idx" @close="lb.open = false" />
  </div>
</template>

<style scoped>
/* 页头字级/眉题/导语走全局 .kicker/.lede/.meta 与 h1 规则；padding 收紧一档
   （base 公共 64/32 → 32/24），让六图索引更早进入首屏。特效画布（#fxHero）
   按 §6.1/§7.1 挂本页头，铺满 hero 区；.wrap 置于其上。 */
/* overflow clip：特效库挂载后给 #fxHero 写内联 width（实测 1200px），窄视口下
   绝对定位 canvas 会把整页撑出横向滚动；特效本就应限定在 hero 盒内，兜底裁掉 */
.site-head { border-bottom: 1px solid var(--line2); position: relative; padding: var(--sp-6) 0 var(--sp-5); overflow: clip; }
.site-head .wrap {
  position: relative;
  z-index: 1;
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: var(--sp-7);
  align-items: end;
}
/* hero 右侧数据大数带：mono 大数 + faint 小标（§6.1 第 3 条） */
.hero-stats { display: flex; flex-direction: column; gap: var(--sp-3); }
.stat { display: flex; align-items: baseline; gap: var(--sp-2); justify-content: flex-end; white-space: nowrap; margin: 0; }
.stat-num {
  font-family: var(--mono);
  font-size: var(--fs-display);
  font-weight: 600;
  line-height: var(--lh-tight);
  color: var(--tx-strong);
  font-variant-numeric: tabular-nums;
}
.stat-label { font-family: var(--mono); font-size: var(--fs-2xs); letter-spacing: .12em; color: var(--faint); }
@media (max-width: 820px) {
  .site-head .wrap { grid-template-columns: 1fr; }
  .stat { justify-content: flex-start; }
}

/* 主 CTA（§5.3 一级）：页头唯一行动点 */
.head-cta { margin-top: var(--sp-5); }
.head-cta .cta {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-2);
  padding: 10px 20px;
  border: 1px solid var(--accent);
  border-radius: var(--radius);
  color: var(--accent);
  text-decoration: none;
  font-size: var(--fs-md);
  letter-spacing: .05em;
  background: var(--accent-bg);
  transition: background var(--t-med) var(--ease), border-color var(--t-med) var(--ease), transform var(--t-fast) var(--ease);
}
.head-cta .cta:hover { background: var(--accent-soft); border-color: var(--accent); }
/* 按下态（主要按钮规范）：scale(.98) 触觉反馈 */
.head-cta .cta:active { transform: scale(.98); }

/* 六图索引（§6.1）：44px 缩略条 + 编号 + 图名 + 模式标签，卡片语言同 §5.2；
   scroll-margin 给移动端吸顶胶囊条留位（hero CTA 滚动目标） */
.map-index { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); gap: var(--sp-3); padding-top: var(--sp-5); scroll-margin-top: 56px; }
.mi-card {
  display: flex;
  flex-direction: column;
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  background: var(--card);
  box-shadow: var(--edge-light);
  overflow: clip;
  text-decoration: none;
  transition: border-color var(--t-med) var(--ease), box-shadow var(--t-med) var(--ease), transform var(--t-med) var(--ease);
}
/* 可点索引卡（整卡为链接）：hover 边提亮 + --edge-hover 组合描边 + 上浮 -2px；按下同 hover */
.mi-card:hover,
.mi-card:active { border-color: var(--line-hover); box-shadow: var(--edge-hover); transform: translateY(-2px); }
.mi-thumb { display: block; height: 44px; background: var(--deep); border-bottom: 1px solid var(--line2); }
.mi-thumb img { display: block; width: 100%; height: 100%; object-fit: cover; }
/* §QA 两轮视觉回归：编号/模式副标题小字再提亮一档（--faint→--dim 未达标）：
   --dim(6.1:1) → --tx，仍属 base.css 四级正文灰阶，层级仍低于图名 --tx-strong */
.mi-num { font-family: var(--mono); font-size: var(--fs-2xs); color: var(--tx); letter-spacing: .1em; margin: 10px 12px 0; }
.mi-name { font-size: var(--fs-sm); font-weight: 600; color: var(--tx-strong); margin: 2px 12px 0; }
.mi-mode { font-family: var(--mono); font-size: var(--fs-2xs); letter-spacing: .12em; color: var(--tx); margin: 3px 12px 12px; }

/* legacy CSS L42-70（layout / sidenav / topbar pills），取值令牌化；
   断点统一 min-width: 1024px 一种写法（§4.1），移动端胶囊条默认显示 */
.layout { display: grid; grid-template-columns: minmax(0, 1fr); gap: 0; padding-top: 6px; }
.sidenav { display: none; }
.pills { display: flex; gap: var(--sp-2); overflow-x: auto; padding: 10px 28px; scrollbar-width: none; }
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
@media (min-width: 1024px) {
  .topbar { display: none; }
  .layout { grid-template-columns: 212px minmax(0, 1fr); gap: 52px; align-items: start; }
  .sidenav { display: block; position: sticky; top: 28px; padding-top: 40px; }
  .sidenav-title {
    font-family: var(--mono);
    font-size: var(--fs-micro);
    letter-spacing: .3em;
    color: var(--faint);
    margin: 0 0 var(--sp-3) 14px;
  }
  .sn-gap { margin-top: var(--sp-5); }
  .nav-item {
    display: block;
    padding: 9px 14px;
    border-left: 2px solid transparent;
    color: var(--dim);
    text-decoration: none;
    transition: color var(--t-med) var(--ease), border-color var(--t-med) var(--ease), background var(--t-med) var(--ease);
  }
  .nav-item:hover,
  .nav-item:active { color: var(--tx); }
  .nav-item.on {
    border-left-color: var(--accent);
    color: var(--tx);
    background: linear-gradient(90deg, var(--accent-bg), transparent 80%);
  }
  .nav-num { font-family: var(--mono); font-size: var(--fs-micro); color: var(--faint); letter-spacing: .1em; transition: color var(--t-med) var(--ease); }
  .nav-item.on .nav-num { color: var(--accent); }
  .nav-name { display: block; font-size: var(--fs-sm); font-weight: 600; margin-top: 1px; }
  .nav-mode { display: block; font-size: var(--fs-micro); color: var(--faint); margin-top: 1px; }
}
main { min-width: 0; padding-bottom: 30px; }

@media (prefers-reduced-motion: reduce) {
  .nav-item, .nav-num, .pill, .head-cta .cta, .mi-card { transition: none; }
}
</style>
