<script setup>
import SiteHeader from './components/SiteHeader.vue'
import SiteFooter from './components/SiteFooter.vue'
import BackTop from './components/BackTop.vue'
</script>

<template>
  <!-- 顶栏 hero-slot 插槽机制保留（当前无注入方） -->
  <SiteHeader />

  <router-view />

  <SiteFooter />
  <BackTop />
</template>
