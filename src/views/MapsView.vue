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

const rootRef = ref(null)
const { observeRoot } = useReveal()

const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches
const scrollMode = () => (reduced ? 'auto' : 'smooth')

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

/* ---- 灯箱（全局单例；MapSection 的「全屏查看」按钮打开） ---- */
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
      <div class="wrap">
        <p class="kicker">DELTA FORCE · OPERATIONS ATLAS</p>
        <h1>三角洲行动 · 地图与打法</h1>
        <p class="lede">
          六张烽火地带地图的高清标注大图与实战打法：出生点思路、撤离点、资源路线、Boss
          情报与物资爆率参考。点击地图可放大查看细节。
        </p>
        <p class="meta">数据整理自公开资料（2026-10 版本） · 爆率为社区统计口径，非官方数据</p>
        <p class="head-cta">
          <router-link class="cta" to="/ttk">全枪械 TTK 击杀排行 →</router-link>
        </p>
      </div>
    </header>

    <nav class="topbar" aria-label="地图导航">
      <div class="pills">
        <router-link class="pill" to="/ttk">TTK 排行</router-link>
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
          <span class="nav-name">TTK 击杀排行</span>
          <span class="nav-mode">全枪械 · 7 兵种</span>
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
/* legacy CSS L36-40（header）+ L265-271（head-cta / sn-gap）原样，取值令牌化。
   页头字级/眉题/导语走 base.css 全局 .kicker/.lede/.meta 与 h1 规则。
   特效画布位于全站 SiteHeader 的 #hero-fx slot（脚手架冻结接线），本页头不再挂 canvas。 */
.site-head { padding: 78px 0 46px; border-bottom: 1px solid var(--line2); position: relative; }
.head-cta { margin-top: 20px; }
.head-cta .cta {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-2);
  padding: 8px 17px;
  border: 1px solid var(--accent-dim);
  border-radius: var(--radius);
  color: var(--accent);
  text-decoration: none;
  font-size: var(--fs-sm);
  letter-spacing: .05em;
  background: var(--accent-bg);
  transition: border-color var(--t-med), background var(--t-med);
}
.head-cta .cta:hover { border-color: var(--accent); background: rgba(45, 212, 191, .15); }

/* legacy CSS L42-70（layout / sidenav / topbar pills）原样，取值令牌化 */
.layout { display: grid; grid-template-columns: minmax(0, 1fr); gap: 0; padding-top: 6px; }
.sidenav { display: none; }
.topbar { display: none; }
@media (min-width: 1024px) {
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
    transition: color var(--t-med), border-color var(--t-med), background var(--t-med);
  }
  .nav-item:hover { color: var(--tx); }
  .nav-item.on {
    border-left-color: var(--accent);
    color: var(--tx);
    background: linear-gradient(90deg, var(--accent-bg), transparent 80%);
  }
  .nav-num { font-family: var(--mono); font-size: var(--fs-micro); color: var(--faint); letter-spacing: .1em; transition: color var(--t-med); }
  .nav-item.on .nav-num { color: var(--accent); }
  .nav-name { display: block; font-size: var(--fs-sm); font-weight: 600; margin-top: 1px; }
  .nav-mode { display: block; font-size: var(--fs-micro); color: var(--faint); margin-top: 1px; }
}
@media (max-width: 1023.5px) {
  .topbar {
    display: block;
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
}
main { min-width: 0; padding-bottom: 30px; }

@media (prefers-reduced-motion: reduce) {
  .nav-item, .pill, .head-cta .cta { transition: none; }
}
</style>
