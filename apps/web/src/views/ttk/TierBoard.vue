<script setup>
/* ============================================================
   TierBoard — T0-T3 强度分档速览带
   借鉴 DFTTK 首页「T0 顶级 / T1 强势 / T2 主流 / T3 可用」分档总览：
   在 68 行平铺排行前补上「第一眼结论」。分档由 TtkView 以固定基准
   （5 级甲 · 胸部 · 每枪最佳弹）计算，不随筛选联动——分档是稳定标签。
   交互：点击枪名 = 填入枪械搜索并平滑滚动到排行表（父组件 pickGun）。
   ============================================================ */
defineProps({
  // [{ t:'T0', label:'顶级', color:'var(--lv5)', count, from, to（纯数字，单位由模板统一补）, names:[zh...] }]
  tiers: { type: Array, required: true },
})
defineEmits(['pick'])
const MAX_CHIPS = 7
</script>

<template>
  <div class="tier-board">
    <div class="tb-caption">
      <span class="tb-title">强度分档</span>
      <span class="tb-note">固定基准：5 级甲 · 胸部 · 每枪最佳弹 · 点击枪名定位到排行行</span>
    </div>
    <div class="tb-grid">
      <div v-for="tg in tiers" :key="tg.t" class="tb-card" :style="{ '--tier': tg.color }">
        <div class="tb-head">
          <span class="tb-t">{{ tg.t }}</span>
          <span class="tb-label">{{ tg.label }}</span>
          <span class="tb-count">{{ tg.count }} 把</span>
        </div>
        <!-- 区间单位只在末尾出现一次（from/to 为纯数字，由父组件拆掉 fmtMs 单位）；
             空档（count=0）退「—」，不带单位后缀 -->
        <div class="tb-range">{{ tg.count ? tg.from + ' – ' + tg.to + ' ms' : '—' }}</div>
        <div class="tb-chips">
          <button
            v-for="n in tg.names.slice(0, MAX_CHIPS)"
            :key="n"
            type="button"
            class="tb-chip"
            @click="$emit('pick', n)"
          >{{ n }}</button>
          <span v-if="tg.names.length > MAX_CHIPS" class="tb-more">+{{ tg.names.length - MAX_CHIPS }}</span>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.tier-board {
  margin: var(--sp-4) 0 var(--sp-2);
}
.tb-caption {
  display: flex;
  align-items: baseline;
  gap: var(--sp-3);
  /* 窄屏长注整体折行到标题下方，不在行内硬折 */
  flex-wrap: wrap;
  margin-bottom: var(--sp-2);
}
.tb-title {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  letter-spacing: .26em;
  color: var(--dim);
}
.tb-note {
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  color: var(--faint);
  letter-spacing: .04em;
}
.tb-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: var(--sp-3);
}
.tb-card {
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  background: var(--card);
  box-shadow: var(--edge-light);
  padding: 13px 15px 12px;
}
/* 卡片本身不可点击（无 hover 提亮）：可点的只有卡内枪名 chips（.tb-chip 自带 hover）；
   分档身份色只由 .tb-t 标题色承担（全站规范：卡片不带左缘竖条） */
.tb-head {
  display: flex;
  align-items: baseline;
  gap: 8px;
}
.tb-t {
  font-family: var(--mono);
  font-size: var(--fs-lg);
  font-weight: 700;
  color: var(--tier);
  letter-spacing: .04em;
}
.tb-label {
  font-size: var(--fs-xs);
  color: var(--tx);
}
.tb-count {
  margin-left: auto;
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  color: var(--faint);
}
.tb-range {
  font-family: var(--mono);
  /* 实义数据（毫秒区间）守字阶下限：--fs-2xs 只给 kicker/mono 小标签/表头（base.css
     字阶注释），区间是该卡第二读数；faint→dim 同步提读数层级（全场景 6.1:1，
     与 tb-count 的计数标签拉开「数据 > 标注」秩序） */
  font-size: var(--fs-xs);
  color: var(--dim);
  margin-top: 2px;
  font-variant-numeric: tabular-nums;
}
.tb-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 5px;
  margin-top: 10px;
}
.tb-chip {
  position: relative; /* 触屏垫层伪元素的定位锚（见文件尾 hover:none 块） */
  border: 1px solid var(--line);
  border-radius: var(--radius-sm);
  background: var(--bg2);
  color: var(--dim);
  font-size: var(--fs-xs);
  padding: 2px 7px;
  cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease), background var(--t-fast) var(--ease), transform var(--t-fast) var(--ease);
}
.tb-chip:hover,
.tb-chip:active {
  color: var(--tx-strong);
  border-color: var(--line-hover);
  background: var(--lift);
}
/* 按压「按实」形变（全站主按钮 scale 语汇，MOTION §3-D）：chips 是本卡唯一可点
   元素、本页触屏主动线之一（点枪名 → 填搜索 → 定位排行），色面反馈外补形变回声；
   hover 不加位移——chips 行密集，悬停晃动易误读为可拖拽 */
.tb-chip:active { transform: scale(.97); }
.tb-more {
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  color: var(--faint);
  align-self: center;
  padding: 0 2px;
}
@media (max-width: 1024px) {
  .tb-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
@media (max-width: 680px) {
  .tb-grid { grid-template-columns: 1fr; }
  .tb-card { padding: 12px 14px 11px 18px; }
}
/* 触屏命中垫层（≥44px 原则，与 ControlSeg .seg-btn 同手法）：枪名 chip 桌面 2px 内距高约 21px，
   是本页触屏主操作之一（点枪名 → 填搜索 → 定位排行）。无 hover 设备真实内距提到 6px
   （约 29px）、::before 再外延 4px（约 37px）。chips 行间距 5px、垂直只外延 4px，
   换行后相邻垫层仅叠压 3px，不出现点字面边缘命中邻行的情况 */
@media (hover: none) {
  .tb-chip { padding: 6px 9px; }
  .tb-chip::before {
    content: "";
    position: absolute;
    left: -3px;
    right: -3px;
    top: -4px;
    bottom: -4px;
  }
}
@media (prefers-reduced-motion: reduce) {
  .tb-chip { transition: none; }
  /* RM：按压形变停，瞬时色面反馈保留（同 iOS「动画置 nil、色面态仍生效」口径） */
  .tb-chip:active { transform: none; }
}
</style>
