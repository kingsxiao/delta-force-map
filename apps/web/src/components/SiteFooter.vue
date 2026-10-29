<script setup>
// 全站页脚：版权说明
import { computed } from 'vue'
import { useRoute } from 'vue-router'

const year = new Date().getFullYear()
const route = useRoute()
/* /ttk 页自身即排行页，「延伸内容」导流行不再出现 */
const showExtend = computed(() => route.path !== '/ttk')
</script>

<template>
  <footer class="site-foot">
    <div class="wrap">
      <p class="foot-brand">三角洲行动 · 非官方数据站</p>
      <p v-if="showExtend" class="foot-line">
        延伸内容：<router-link to="/ttk" class="foot-link">全枪械 TTK 排行</router-link>——弹药穿透等级 ×
        护甲减伤逐发模拟，附弹药库与判定矩阵。
      </p>
      <p class="foot-line foot-copy">
        《三角洲行动》（Delta Force）游戏名称及相关素材版权归腾讯 / 天美工作室群所有。本站为数据整理，仅供个人学习参考（© {{ year }}），不含任何商业用途。
      </p>
    </div>
  </footer>
</template>

<style scoped>
.site-foot {
  margin-top: var(--sp-8);
  padding: var(--sp-6) 0 var(--sp-7);
  border-top: 1px solid var(--line);
  background: var(--bg2);
}
.foot-brand {
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  letter-spacing: .22em;
  color: var(--faint);
  margin-bottom: var(--sp-3);
}
.foot-line {
  font-size: var(--fs-xs);
  color: var(--dim);
  max-width: 76ch;
  margin-bottom: var(--sp-2);
}
.foot-link {
  color: var(--accent);
  text-decoration: none;
  text-underline-offset: 3px; /* hover 出现下划线时与中文字形拉开距离，不再贴着笔画 */
}
.foot-link:hover { text-decoration: underline; }
/* 按下态同 hover（加下划线）：触屏无 hover 时按压即时可见 */
.foot-link:active { text-decoration: underline; }
.foot-copy {
  color: var(--faint);
  margin-bottom: 0;
}
</style>
