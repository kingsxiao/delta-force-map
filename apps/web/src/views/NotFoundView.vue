<script setup>
/* NotFoundView — 未匹配路由的兜底提示页（/:pathMatch(.*)*）
   hash 路由下无 catch-all 时 RouterView 渲染空、页面只剩顶栏页脚；README
   收录的旧链接（如已下线的 /#/tactics）或手滑地址落进来至少要有去处指引。 */
import { onBeforeUnmount, onMounted } from 'vue'

const LINKS = [
  { to: '/ammo', label: '子弹行情' },
  { to: '/radar', label: '异动雷达' },
  { to: '/craft', label: '特勤处制造' },
  { to: '/ttk', label: 'TTK 排行' },
  { to: '/account', label: '账号' },
]

let prevTitle = '' // 路由标题：进入存默认值，卸载还原（模式同 AmmoMarketView）
onMounted(() => {
  prevTitle = document.title
  document.title = '三角洲行动 · 页面不存在'
})
onBeforeUnmount(() => { document.title = prevTitle })
</script>

<template>
  <div class="wrap page nf">
    <div class="nf-card">
      <h1 class="nf-title">页面不存在</h1>
      <p class="nf-desc">
        当前地址没有对应页面（旧的战术地图等已下线的模块会落到这里）。
        可从下面入口继续：
      </p>
      <nav class="nf-links" aria-label="可用页面">
        <router-link v-for="l in LINKS" :key="l.to" :to="l.to" class="nf-link">{{ l.label }}</router-link>
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
}
.nf-title { margin: 0 0 var(--sp-3); font-size: var(--fs-xl); color: var(--tx-strong); }
.nf-desc { margin: 0 0 var(--sp-4); color: var(--dim); font-size: var(--fs-sm); line-height: 1.7; }
.nf-links { display: flex; flex-wrap: wrap; gap: 8px; }
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
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
}
.nf-link:hover,
.nf-link:active { color: var(--tx); border-color: var(--line-hover); }
</style>
