<script setup>
import { onBeforeUnmount, onMounted, watch } from 'vue'
import { useRoute } from 'vue-router'
import SiteHeader from './components/SiteHeader.vue'
import SiteFooter from './components/SiteFooter.vue'
import BackTop from './components/BackTop.vue'

const route = useRoute()

/* 跳过顶栏直达内容：hash 路由下不能靠 href="#main" 原生锚点——location.hash 一变
   vue-router 就把它当 /main 路由解析、直落 404；改为 JS 接管：焦点移到内容容器
   （tabindex=-1 可编程聚焦、不进 Tab 序）再滚到其顶缘。scrollIntoView 不传 behavior
   = 跟随 html 的 scroll-behavior（base.css 平滑、RM 下 auto），不另判 RM */
function skipToMain(e) {
  e.preventDefault()
  const el = document.getElementById('main')
  if (!el) return
  el.focus({ preventScroll: true })
  el.scrollIntoView({ block: 'start' })
}

/* 路由切换回顶（壳层兜底，终审轮补的缺口）：router.js 未配置 scrollBehavior——
   vue-router 的 handleScroll 在无 scrollBehavior 时直接 return（源码
   vue-router.mjs:1466-1467），push 导航不重置滚动；上一页（如 /ammo 长表）滚到
   2000px 再点顶栏换页，会落在新区内容中段。规则：
   · 链接点击 / ⌘K 跳转等 push 导航 → 瞬时回顶：换页是「换内容」不是「滚动」，
     平滑滚动反而与 .route 淡入（motion.css）打架；
   · popstate（前进/后退）→ 交还浏览器原生恢复：无 scrollBehavior 时
     scrollRestoration 保持 auto（vue-router 仅在配置了 scrollBehavior 才置
     manual，源码 vue-router.mjs:1169），「回到上次浏览位置」正是后退的预期；
   · 首次导航跳过：初始 '/' 重定向发生在挂载后，若不跳过会在刷新时抢在浏览器
     的滚动恢复之前压回顶部（首航时页面本就在顶部，跳过零损失）；
   · 同页仅 query 变更不回顶：换页判据是 route.path 前后对比（TTK 页
     筛选/键入 router.replace 同步 query、⌘K 站内搜索等，内容还是那一页，
     拽回顶部会打断用户浏览位置）。watch 源仍带 fullPath——每次导航（含后退
     只改 query 的 popstate）都要过一遍守卫把 navByPop 消费掉，否则标志滞留，
     下一跳跨页回顶会被误吞。
   scrollTo 必须强制瞬时：html 有全局 scroll-behavior:smooth（base.css:138），
   两参 scrollTo 与 behavior:'auto' 都会跟随它——临时内联置 auto、滚完还原 */
let navByPop = false
let firstNav = true
const onPop = () => { navByPop = true }
function jumpTop() {
  const el = document.documentElement
  const prev = el.style.scrollBehavior
  el.style.scrollBehavior = 'auto' // 压过 html 的 smooth，本次恒瞬时
  window.scrollTo(0, 0)
  el.style.scrollBehavior = prev
}
watch(
  () => [route.path, route.fullPath],
  ([path], [prevPath]) => {
    if (firstNav) { firstNav = false; return }
    if (navByPop) { navByPop = false; return }
    if (path === prevPath) return // 同页 query 变更：不回顶
    jumpTop()
  }
)
onMounted(() => window.addEventListener('popstate', onPop))
onBeforeUnmount(() => window.removeEventListener('popstate', onPop))
</script>

<template>
  <!-- 跳过导航出路（WCAG 2.4.1）：顶栏可聚焦项随 tab 数增长（brand + 10 tab + ⌘K），
       键盘 / 读屏器用户每换一页都得先把它们走一遍。链接默认移出视口、仅 Tab 聚焦时
       在顶栏左上现身（样式 base.css .skip-link），鼠标用户永远看不到它。
       href 保留 #main 让它是合法可聚焦链接（无 href 的 a 不进 Tab 序），跳转由
       skipToMain 接管（见 script 注释） -->
  <a class="skip-link" href="#main" @click="skipToMain">跳到主内容</a>

  <!-- 顶栏 hero-slot 插槽机制保留（当前无注入方） -->
  <SiteHeader />

  <!-- 内容容器只是 skip 目标，刻意不用 <main>：AccountView 根元素已自带 <main>
       （AccountView.vue:183），壳层再包一层会让 /account 出现双 main 地标违规；
       地标统一属各视图根元素的事，这里只负责「出路」 -->
  <div id="main" tabindex="-1">
    <!-- 路由过渡只淡入（.route-* 定义在 motion.css）：不设 mode="out-in"——离场元素
         无过渡类即瞬时卸载，绝不阻塞新视图进场；位移与级联错峰交给页内 .reveal，
         杜绝「离场淡出 + 进场淡入 + 页内入场」三层叠加（MOTION.md §3-A） -->
    <router-view v-slot="{ Component, route }">
      <Transition name="route">
        <component :is="Component" :key="route.path" />
      </Transition>
    </router-view>
  </div>

  <SiteFooter />
  <BackTop />
</template>
