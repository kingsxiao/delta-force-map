<script setup>
import { useRoute } from 'vue-router'

const route = useRoute()

// 三个主 tab；active 高亮按 route.path 精确比对（'/' 不应匹配到所有路由）
const tabs = [
  { to: '/', label: '地图' },
  { to: '/tactics', label: '打法' },
  { to: '/ttk', label: 'TTK排行' },
]
</script>

<template>
  <header class="site-topbar">
    <div class="wrap bar-inner">
      <router-link to="/" class="brand" aria-label="三角洲行动 · 战术图集 首页">
        <span class="brand-glyph" aria-hidden="true"></span>
        <span class="brand-mark">DELTA FORCE</span>
        <span class="brand-sub">战术图集</span>
      </router-link>

      <nav class="tabs" aria-label="站点导航">
        <router-link
          v-for="t in tabs"
          :key="t.to"
          :to="t.to"
          class="tab"
          :class="{ active: route.path === t.to }"
        >
          {{ t.label }}
        </router-link>
      </nav>
    </div>

    <!-- hero 特效插槽（机制保留）：v2.2 起特效迁入首页 .site-head，此处不再注入内容 -->
    <div class="hero-slot">
      <slot name="hero-fx" />
    </div>
  </header>
</template>

<style scoped>
.site-topbar {
  position: relative;
  background: var(--bg2);
  border-bottom: 1px solid var(--line);
}
.bar-inner {
  position: relative;
  z-index: 2;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-4);
  height: 56px;
}
.brand {
  display: flex;
  align-items: center;
  gap: 10px;
  text-decoration: none;
}
/* 品牌菱形标：与全站 ◆ / 菱形点位同一几何语言 */
.brand-glyph {
  flex: none;
  width: 8px;
  height: 8px;
  background: var(--accent);
  transform: rotate(45deg);
  box-shadow: 0 0 10px rgba(45, 212, 191, .35);
}
.brand-mark {
  font-family: var(--mono);
  font-size: var(--fs-sm);
  font-weight: 700;
  letter-spacing: .22em;
  color: var(--tx-strong);
}
.brand-sub {
  font-family: var(--sans);
  font-size: var(--fs-xs);
  color: var(--faint);
  letter-spacing: .12em;
  transform: translateY(1px);
}
.tabs {
  display: flex;
  gap: var(--sp-5);
}
/* 下划线式 tab：文字 + 底部指示条，与页内胶囊 chips 拉开层级 */
.tab {
  position: relative;
  display: inline-block;
  padding: 6px 2px;
  font-size: var(--fs-sm);
  color: var(--dim);
  text-decoration: none;
  letter-spacing: .05em;
  transition: color var(--t-med);
}
.tab::after {
  content: "";
  position: absolute;
  left: 0;
  right: 0;
  bottom: -1px;
  height: 2px;
  background: var(--accent);
  transform: scaleX(0);
  transform-origin: left center;
  transition: transform var(--t-med) var(--ease), opacity var(--t-med);
}
.tab:hover { color: var(--tx); }
.tab:hover::after { transform: scaleX(1); opacity: .3; }
.tab.active { color: var(--accent); }
.tab.active::after { transform: scaleX(1); opacity: 1; }
/* 特效层容器：绝对定位不影响导航条布局；v2.2 起不再注入内容，机制保留 */
.hero-slot {
  position: absolute;
  inset: 0;
  pointer-events: none;
}
.hero-slot > :deep(*) {
  pointer-events: auto;
}
/* 窄屏（--bp-mini 480px）：brand 收缩 + tab 间距收紧，消除 375px 视口溢出 */
@media (max-width: 480px) {
  .brand-sub { display: none; }
  .brand-mark { letter-spacing: .12em; }
  .tabs { gap: var(--sp-4); }
}
@media (prefers-reduced-motion: reduce) {
  .tab, .tab::after { transition: none; }
}
</style>
