import { createRouter, createWebHashHistory } from 'vue-router'
import MapsView from './views/MapsView.vue'
import TacticsView from './views/TacticsView.vue'
import TtkView from './views/TtkView.vue'
import AmmoMarketView from './views/AmmoMarketView.vue'

// hash 路由：静态托管零配置（免 SPA fallback）。
// 约定：hash 模式下禁止任何代码向 location.hash 写入裸锚点（会变成路由路径），
// 页内锚点导航一律 scrollIntoView，不设 /:slug 之类的兜底路由。
const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', name: 'maps', component: MapsView },
    { path: '/tactics', name: 'tactics', component: TacticsView },
    { path: '/ttk', name: 'ttk', component: TtkView },
    { path: '/ammo', name: 'ammo', component: AmmoMarketView },
  ],
})

export default router
