<script setup>
import SiteHeader from './components/SiteHeader.vue'
import SiteFooter from './components/SiteFooter.vue'
import BackTop from './components/BackTop.vue'
import HeroFx from './views/maps/HeroFx.vue'
</script>

<template>
  <SiteHeader>
    <!-- hero 特效接线（冻结）：HeroFx 由地图工程师 A 填充，
         其内部自行判定路由为 '/' 才真正挂载 FxCanvas，/tactics、/ttk 无特效 -->
    <template #hero-fx>
      <HeroFx />
    </template>
  </SiteHeader>

  <router-view />

  <SiteFooter />
  <BackTop />
</template>
