<script setup>
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { useAccount } from '../composables/useAccount'

const route = useRoute()
const { user } = useAccount()

// 三个主 tab + 账号入口（登录态显示用户名）；active 高亮按 route.path
// 精确比对（'/' 不应匹配到所有路由）
const tabs = [
  { to: '/ammo', label: '子弹行情' },
  { to: '/radar', label: '异动雷达' },
  { to: '/craft', label: '特勤处制造' },
  { to: '/ttk', label: 'TTK 排行' },
]

// 溢出提示：tabs 横向滚动承接时滚动条被藏掉，「右边还有 tab」必须另有可感信号。
// 纯 CSS 感知不了 scrollWidth>clientWidth，只能在尺寸/滚动变化时手动挂摘 .can-scroll
// （驱动右缘渐隐 mask）；滚到最右即摘除，渐隐不会一直压着最后一个 tab。
const tabsEl = ref(null)
let tabsRO = null
function syncTabsOverflow() {
  const el = tabsEl.value
  if (!el) return
  const more = el.scrollWidth - el.clientWidth > 1
  const atEnd = el.scrollLeft + el.clientWidth >= el.scrollWidth - 1
  el.classList.toggle('can-scroll', more && !atEnd)
}
onMounted(() => {
  const el = tabsEl.value
  if (!el) return
  syncTabsOverflow()
  tabsRO = new ResizeObserver(syncTabsOverflow)
  tabsRO.observe(el)
  // 逐个 tab 也观察：登录后「登录」换成用户名、字体晚加载改宽，都不动容器盒宽，
  // 只盯容器会漏刷新
  el.querySelectorAll('.tab').forEach((t) => tabsRO.observe(t))
  el.addEventListener('scroll', syncTabsOverflow, { passive: true })
})
onBeforeUnmount(() => {
  if (tabsRO) tabsRO.disconnect()
  if (tabsEl.value) tabsEl.value.removeEventListener('scroll', syncTabsOverflow)
})
</script>

<template>
  <header class="site-topbar">
    <div class="wrap bar-inner">
      <router-link to="/" class="brand" aria-label="三角洲行动 · delta force hub 首页">
        <span class="brand-glyph" aria-hidden="true"></span>
        <span class="brand-mark">DELTA FORCE</span>
        <span class="brand-sub">delta force hub</span>
      </router-link>

      <nav class="tabs" ref="tabsEl" aria-label="站点导航">
        <router-link
          v-for="t in tabs"
          :key="t.to"
          :to="t.to"
          class="tab"
          :class="{ active: route.path === t.to }"
        >
          {{ t.label }}
        </router-link>
        <!-- 账号入口与主 tab 同样式：登录后显示用户名，未登录显示「登录」。
             用户名规则允许 16 字符（全中文常态比 4 个主 tab 加起来还宽），原样显示
             会把顶栏需求宽撑出 701~880px 长尾区间：tabs 被迫滚动、账号 tab 只露
             几个字。入口的可点价值高于完整展示价值 → 按宽截断（见 .acct-name），
             全名保留在 title（hover 可见）与 DOM 文本（读屏器不受 CSS 截断影响） -->
        <router-link
          to="/account"
          class="tab"
          :class="{ active: route.path === '/account' }"
          :title="user ? user.username : undefined"
        >
          <span class="acct-name">{{ user ? user.username : '登录' }}</span>
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
  flex: none; /* 不参与收缩：窄屏收缩压力全交给 .tabs（否则 DELTA FORCE 会被压折行） */
  align-items: center;
  gap: 10px;
  text-decoration: none;
  transition: transform var(--t-fast) var(--ease);
}
/* 品牌链接 hover：副标提亮一档（--faint → --dim），主标保持强文字色 */
.brand:hover .brand-sub { color: var(--dim); }
.brand:active { transform: translateY(1px); }
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
  transition: color var(--t-med) var(--ease);
}
.tabs {
  display: flex;
  align-self: stretch; /* 拉通顶栏全高：tab 触达区 44 → 56px，且 ::after 指示条
                           （bottom:-1px）贴住顶栏下边线，激活态与分隔线连续成一体 */
  gap: var(--sp-5);
  /* 溢出承接常开：顶栏未压缩自然需求宽约 664px（brand+gap+tabs），561~663px 一带
     曾经既放不下又没有滚动，页面被撑出横向滚动条、「登录」被裁出视口；任何宽度
     统一交给横向滚动承接（min-width:0 让 tabs 可在 brand 旁收缩出滚动空间）。
     滚动条本身藏掉（复用全站 pills 的 overflow-x 范式），溢出信号由 .can-scroll
     右缘渐隐承担 */
  min-width: 0;
  overflow-x: auto;
  scrollbar-width: none;
  padding-bottom: 1px; /* 给 ::after 指示条的 -1px 底部溢出留位，防滚动容器裁剪 */
}
.tabs::-webkit-scrollbar { display: none; }
/* 右缘渐隐 = 「右边还有 tab」的唯一可感信号（滚动条已藏）；class 由 JS 按真实
   溢出挂摘（见 syncTabsOverflow），不溢出/已滚到最右时绝不出现 */
.tabs.can-scroll {
  -webkit-mask-image: linear-gradient(90deg, #000 0, #000 calc(100% - 24px), transparent 100%);
  mask-image: linear-gradient(90deg, #000 0, #000 calc(100% - 24px), transparent 100%);
}
/* 账号 tab 文字按宽截断：8em（fs-sm 13px ≈ 104px）= 中文 8 字 / 英文约 14 字符，
   超出显示省略号。span 作为 .tab（inline-flex）的 flex item 自动块化，ellipsis 生效；
   侧限 8em 是平衡点：12~16 字长名下 820px 级视口 tabs 不再溢出，727px 级溢出减半，
   而短名/「登录」不受影响（内容窄于上限时 max-width 不介入） */
.acct-name {
  max-width: 8em;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
/* 下划线式 tab：文字 + 底部指示条，与页内胶囊 chips 拉开层级 */
.tab {
  position: relative;
  display: inline-flex;
  align-items: center;
  flex: none; /* 横向滚动模式下不吃收缩，保持整词宽 */
  min-height: 44px; /* 触控行高下限（HIG 44pt）；.tabs 已拉通 56px 顶栏全高，实际行高即 56px */
  padding: 6px 2px;
  font-size: var(--fs-sm);
  color: var(--dim);
  text-decoration: none;
  letter-spacing: .05em;
  white-space: nowrap; /* 放不下时由 .tabs 横向滚动承接，绝不允许逐字折行 */
  transition: color var(--t-med) var(--ease), transform var(--t-fast) var(--ease);
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
  transition: transform var(--t-med) var(--ease), opacity var(--t-med) var(--ease);
}
.tab:hover { color: var(--tx); }
.tab:hover::after { transform: scaleX(1); opacity: .3; }
.tab.active { color: var(--accent); }
.tab.active::after { transform: scaleX(1); opacity: 1; }
/* 按下态：文字再提亮一档 + 整体下沉 1px + 指示条压低，触屏（无 hover）同样有「按实」反馈 */
.tab:active { color: var(--tx-strong); transform: translateY(1px); }
.tab:active::after { opacity: .15; }
/* 当前路由 tab 按下时保持主色文字与满亮指示条（选中态不被按下态覆盖） */
.tab.active:active { color: var(--accent); }
.tab.active:active::after { opacity: 1; }
/* 特效层容器：绝对定位不影响导航条布局；v2.2 起不再注入内容，机制保留 */
.hero-slot {
  position: absolute;
  inset: 0;
  pointer-events: none;
}
.hero-slot > :deep(*) {
  pointer-events: auto;
}
/* 窄屏（≤700px）：brand 收缩（藏副标、字距减半）+ tabs gap 收窄。门槛不是拍脑袋：
   未压缩时顶栏自然需求宽约 664px，旧门槛 560px 之上的 561~663px 一带既放不下又
   无承接（横向滚动承接旧只在 ≤560px 生效）；直接抬过 664px 需求线（+36px 余量），
   让这一带压缩后全部 tab 无需滚动即可见，彻底消灭「无承接区间」 */
@media (max-width: 700px) {
  .brand-sub { display: none; }
  .brand-mark { letter-spacing: .12em; }
  .tabs { gap: var(--sp-4); }
}
@media (prefers-reduced-motion: reduce) {
  .tab, .tab::after, .brand, .brand-sub { transition: none; }
}
</style>
