import { createRouter, createWebHashHistory } from 'vue-router'
import MapsView from './views/MapsView.vue'

// hash 路由：静态托管零配置（免 SPA fallback）。
// 约定：hash 模式下禁止任何代码向 location.hash 写入裸锚点（会变成路由路径），
// 页内锚点导航一律 scrollIntoView，不设 /:slug 之类的兜底路由。
// 落地路由 '/' 保持静态 import（免 chunk 瀑布），其余视图动态 import 按需分包。
const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', name: 'maps', component: MapsView },
    { path: '/tactics', name: 'tactics', component: () => import('./views/TacticsView.vue') },
    { path: '/ttk', name: 'ttk', component: () => import('./views/TtkView.vue') },
    { path: '/ammo', name: 'ammo', component: () => import('./views/AmmoMarketView.vue') },
    { path: '/radar', name: 'radar', component: () => import('./views/MarketRadarView.vue') },
  ],
})

export default router
