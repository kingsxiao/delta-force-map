import { createRouter, createWebHashHistory } from 'vue-router'

// hash 路由：静态托管零配置（免 SPA fallback）。
// 约定：hash 模式下禁止任何代码向 location.hash 写入裸锚点（会变成路由路径），
// 页内锚点导航一律 scrollIntoView；不设 /:slug 之类的参数兜底路由，仅留
// catch-all 提示页兜住未匹配路径（旧链接/已下线模块不再白屏）。
// 视图动态 import 按需分包；'/' 落地到子弹行情。
const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', redirect: '/ammo' },
    { path: '/ttk', name: 'ttk', component: () => import('./views/TtkView.vue') },
    // 弹种详情（手机端点行 / 卖出卡直达，桌面直链亦可开）：弹名作路径参数，
    // 实名含引号/空格/斜杠，调用方须 encodeURIComponent（vue-router 解析时解码）
    { path: '/ammo/item/:name', name: 'ammo-item', component: () => import('./views/AmmoDetailView.vue') },
    { path: '/ammo', name: 'ammo', component: () => import('./views/AmmoMarketView.vue') },
    { path: '/radar', name: 'radar', component: () => import('./views/MarketRadarView.vue') },
    { path: '/craft', name: 'craft', component: () => import('./views/CraftView.vue') },
    { path: '/account', name: 'account', component: () => import('./views/AccountView.vue') },
    { path: '/:pathMatch(.*)*', name: 'not-found', component: () => import('./views/NotFoundView.vue') },
  ],
})

export default router
