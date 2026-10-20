<script setup>
import SiteHeader from './components/SiteHeader.vue'
import SiteFooter from './components/SiteFooter.vue'
import BackTop from './components/BackTop.vue'
</script>

<template>
  <!-- v2.2：hero 特效迁入首页 .site-head（MapsView 内挂 FxCanvas，canvas-id="fxHero"），
       顶栏 hero-slot 插槽机制保留但不再注入内容；#fxHero id 与 data-fx 门链不变 -->
  <SiteHeader />

  <router-view />

  <SiteFooter />
  <BackTop />
</template>
