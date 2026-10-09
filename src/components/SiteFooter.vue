<script setup>
// 全站页脚：数据来源与版权说明（文案沿袭 legacy 页脚，视觉阶段统一打磨）
const year = new Date().getFullYear()
</script>

<template>
  <footer class="site-foot">
    <div class="wrap">
      <p class="foot-brand">DELTA FORCE · FAN-MADE ATLAS</p>
      <p class="foot-line">
        数据整理自公开资料（2026-10 版本）：官方地图工具点位数据，以及腾讯官网、3DM、游民星空、17173、NGA、TapTap、B
        站等社区攻略。物资爆率均为社区统计口径，非官方数据，仅供参考。
      </p>
      <p class="foot-line">
        延伸内容：<router-link to="/ttk" class="foot-link">全枪械 TTK 击杀时间排行</router-link>——弹药穿透等级 ×
        护甲减伤逐发模拟，附弹药库与判定矩阵。
      </p>
      <p class="foot-line foot-copy">
        《三角洲行动》（Delta Force）游戏名称、地图素材及相关内容版权归腾讯 / 天美工作室群所有。本站为静态资料整理，仅供个人学习参考（©
        {{ year }}），不含任何商业用途。
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
}
.foot-link:hover { text-decoration: underline; }
.foot-copy {
  color: var(--faint);
  margin-bottom: 0;
}
</style>
