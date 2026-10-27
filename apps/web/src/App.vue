<script setup>
import SiteHeader from './components/SiteHeader.vue'
import SiteFooter from './components/SiteFooter.vue'
import BackTop from './components/BackTop.vue'
</script>

<template>
  <!-- 顶栏 hero-slot 插槽机制保留（当前无注入方） -->
  <SiteHeader />

  <!-- 路由过渡只淡入（.route-* 定义在 motion.css）：不设 mode="out-in"——离场元素
       无过渡类即瞬时卸载，绝不阻塞新视图进场；位移与级联错峰交给页内 .reveal，
       杜绝「离场淡出 + 进场淡入 + 页内入场」三层叠加（MOTION.md §3-A） -->
  <router-view v-slot="{ Component, route }">
    <Transition name="route">
      <component :is="Component" :key="route.path" />
    </Transition>
  </router-view>

  <SiteFooter />
  <BackTop />
</template>
