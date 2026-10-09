<script setup>
// HeroFx.vue — SiteHeader #hero-fx slot 的实际内容（工程师A 填充）。
// 仅当前路由为 '/'（地图页）时挂载 FxCanvas；/tactics、/ttk 不渲染任何特效 DOM，
// 与 legacy ttk.html 头部无 canvas 的语义一致。
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import FxCanvas from './FxCanvas.vue'

const route = useRoute()
const isMaps = computed(() => route.path === '/')
</script>

<template>
  <FxCanvas v-if="isMaps" mode="hero" canvas-id="fxHero" />
</template>
