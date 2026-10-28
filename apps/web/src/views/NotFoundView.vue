<script setup>
/* NotFoundView — 未匹配路由的兜底提示页（/:pathMatch(.*)*）
   hash 路由下无 catch-all 时 RouterView 渲染空、页面只剩顶栏页脚；README
   收录的旧链接（如已下线的 /#/tactics）或手滑地址落进来至少要有去处指引。 */
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { useReveal } from '../composables/useReveal'

const route = useRoute()
/* 落地路径原样回显：手滑/改错一个字符的地址能立即对上号（比泛泛的「页面
   不存在」省一次猜）；catch-all 下 route.path 即未匹配的原始路径 */
const badPath = route.path

const LINKS = [
  { to: '/ammo', label: '子弹行情' },
  { to: '/radar', label: '异动雷达' },
  { to: '/craft', label: '特勤处制造' },
  { to: '/ttk', label: 'TTK 排行' },
  { to: '/account', label: '账号' },
]

/* 入场：卡片挂 .reveal（12px 上移 + 淡入，base.css 页面级档）——路由层只管整页
   淡入，位移交给页内 reveal，两层各司其职（MOTION.md §3-A，与其余页同构） */
const rootEl = ref(null)
const { observeRoot } = useReveal()

let prevTitle = '' // 路由标题：进入存默认值，卸载还原（模式同 AmmoMarketView）
onMounted(() => {
  prevTitle = document.title
  document.title = '三角洲行动 · 页面不存在'
  observeRoot(rootEl.value)
})
onBeforeUnmount(() => { document.title = prevTitle })
</script>

<template>
  <div ref="rootEl" class="wrap page nf">
    <div class="nf-card reveal">
      <h1 class="nf-title">页面不存在</h1>
      <p class="nf-desc">
        当前地址（<code class="nf-path">{{ badPath }}</code>）没有对应页面——旧的战术地图
        等已下线的模块会落到这里。可从下面入口继续：
      </p>
      <nav class="nf-links" aria-label="可用页面">
        <router-link v-for="l in LINKS" :key="l.to" :to="l.to" class="nf-link press">{{ l.label }}</router-link>
      </nav>
    </div>
  </div>
</template>

<style scoped>
.nf { padding: var(--sp-8) 0 var(--sp-7); }
.nf-card {
  background: var(--card);
  /* 虚线用 --line2 画在 --bg 上对比度仅约 1.25:1，轮廓几乎不可见、卡片失去结构感；
     提一档到全站卡片描边规格 --line，虚线「未完成感」样式保持不变 */
  border: 1px dashed var(--line);
  border-radius: var(--radius);
  padding: var(--sp-6);
  color: var(--tx);
  /* 顶缘微光补上卡片三件套第三件（面差+描边+--edge-light，对照 .col / .sk-card /
     .sk-stat 全站卡片语汇）：深色层次靠面阶梯+顶缘光成立，本卡此前独缺、面感偏平 */
  box-shadow: var(--edge-light);
}
.nf-title { margin: 0 0 var(--sp-3); font-size: var(--fs-xl); color: var(--tx-strong); }
.nf-desc { margin: 0 0 var(--sp-4); color: var(--dim); font-size: var(--fs-sm); line-height: var(--lh-body); }
/* 回显路径用 mono + 断行防御：路径可能极长（手滑粘贴一串），anywhere 允许在
   任意字符间断行，不让卡片撑出横向滚动 */
.nf-path {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  color: var(--tx);
  overflow-wrap: anywhere;
}
.nf-links { display: flex; flex-wrap: wrap; gap: var(--sp-2); }
/* 入口 chips：胶囊描边，hover 提亮。底面用 --card2 而非 --card：本 chips 落在
   --card 卡片内，同色叠加会融进卡面只剩细边框，提一档恢复面差（同分段控件选中面） */
.nf-link {
  background: var(--card2);
  border: 1px solid var(--line);
  border-radius: var(--radius-pill);
  padding: 5px 16px;
  color: var(--dim);
  font-size: var(--fs-sm);
  text-decoration: none;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease), transform var(--t-fast) var(--ease);
}
/* 触屏命中区：指针粗介质下 padding 5→11px（视觉高约 30 → 46px，过 44 下限）。
   刻意用真实 padding 而非 ::before 外扩垫层：chips 间距仅 8px，垫层外扩会让
   相邻命中区叠压、点击归属错乱；真实尺寸永远与命中区同源 */
@media (pointer: coarse) {
  .nf-link { padding: 11px 18px; }
}
.nf-link:hover,
.nf-link:active { color: var(--tx); border-color: var(--line-hover); }
/* 按压微缩挂全局 .press（motion.css 状态类；transition 已含 transform 项，符合其约定） */

/* .reveal 的 RM 降级由 base.css 全局兜底；.press 的 RM 由 motion.css 兜底，
   这里只关本地 color/border 过渡 */
@media (prefers-reduced-motion: reduce) {
  .nf-link { transition: none; }
}
</style>
