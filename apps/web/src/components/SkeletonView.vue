<script setup>
// SkeletonView — 首载骨架屏（MOTION.md §4 统一方案，全站唯一骨架组件）
// 只输出 .sk-* 占位结构（motion.css）：不拉数据、不占 .state-card 等既有类名
// （server/smoke.mjs 选择器兼容，见 MOTION.md §6-6）。结构贴近各页真实布局：
// table = 表头条 + N 行（/ammo /radar /craft 榜单）、cards = 信号卡网格、
// hero = 时利最佳主卡。用法：
//   <SkeletonView v-if="loadState === 'loading'" variant="table" :rows="8" />
defineProps({
  variant: { type: String, default: 'table' }, // 'table' | 'cards' | 'hero'
  rows: { type: Number, default: 8 }, // table 变体行数（弹药 8 / 雷达 10）
  // table 变体表头条数：与 .sk-row 同模板对轨（motion.css .sk-head），首条横跨
  // 图标位 + 名字位两轨，故 8 轨对应 7 条；多于 7 条会被 grid 自动换行到第二行
  cols: { type: Number, default: 7 },
})

// 行内数字条宽度按 (行, 列) 固定种子错开：避免 N 行完全同宽显得机械，
// 纯函数保证重渲染宽度稳定（骨架不闪变）
function numW(r, i) {
  return `${62 + ((r * 7 + i * 11) % 34)}%`
}
// 名字条模拟的是「文字宽」不是「列宽」：名字轨是 1.1fr 弹性轨，宽屏下吞掉全部剩余
// 空间（1240 容器约 680px），条若写 100% 会铺成横跨半屏的长条，而真实物品名只有
// 4~8 字（≈96~150px）。按行种子在 96~151px 间错开；窄屏名字轨可能窄于条宽，
// min(100%) 兜住不溢轨
function nameW(r) {
  return `min(100%, ${96 + ((r * 37) % 56)}px)`
}
</script>

<template>
  <!-- 根节点 role=status 供读屏器感知「加载中」；占位块本身对读屏器隐藏 -->
  <div class="sk-view" role="status" aria-label="正在加载">
    <!-- table：表头条 + rows × .sk-row（图标位 + 名字条 + 5 数字条 + 走势位） -->
    <div v-if="variant === 'table'" class="sk-tbl" aria-hidden="true">
      <div class="sk-head">
        <i v-for="c in cols" :key="c" class="sk sk-line"></i>
      </div>
      <div v-for="r in rows" :key="r" class="sk-row">
        <i class="sk sk-thumb"></i>
        <i class="sk sk-line" :style="{ '--w': nameW(r) }"></i>
        <i class="sk sk-num" :style="{ '--w': numW(r, 0) }"></i>
        <i class="sk sk-num" :style="{ '--w': numW(r, 1) }"></i>
        <i class="sk sk-num" :style="{ '--w': numW(r, 2) }"></i>
        <i class="sk sk-num" :style="{ '--w': numW(r, 3) }"></i>
        <i class="sk sk-num" :style="{ '--w': numW(r, 4) }"></i>
        <i class="sk sk-chart"></i>
      </div>
    </div>

    <!-- cards：2×3 信号卡骨架（列宽由 .sk-cards 对齐 .sig-grid 承接） -->
    <div v-else-if="variant === 'cards'" class="sk-cards" aria-hidden="true">
      <div v-for="c in 6" :key="c" class="sk-card">
        <i class="sk sk-line" style="--w: 58%"></i>
        <i class="sk sk-line" style="--w: 40%"></i>
        <i class="sk sk-num" style="--w: 44%"></i>
      </div>
    </div>

    <!-- hero：时利最佳主卡骨架（kicker + 徽标行 / 图标 + 名称两行 / 右侧大数） -->
    <div v-else-if="variant === 'hero'" class="sk-hero" aria-hidden="true">
      <div class="sk-hero-top">
        <i class="sk sk-line" style="--w: 96px"></i>
        <i class="sk sk-badge"></i>
        <i class="sk sk-badge" style="--w: 72px"></i>
      </div>
      <div class="sk-hero-main">
        <i class="sk sk-hero-thumb"></i>
        <div class="sk-hero-name">
          <i class="sk sk-line" style="--w: 78%"></i>
          <i class="sk sk-line" style="--w: 52%"></i>
        </div>
        <div class="sk-hero-fig">
          <i class="sk sk-hero-big"></i>
          <i class="sk sk-line" style="--w: 88px"></i>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* hero 变体组合样式：扫光与底色全在全局 .sk 基块上（sk-hero-thumb /
   sk-hero-big 都挂了 sk 类），这里只管几何贴近真实卡片（CraftView .hero） */

.sk-hero {
  padding: var(--sp-4) var(--sp-5);
  margin: var(--sp-5) 0 var(--sp-4);
  background: var(--card);
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  box-shadow: var(--edge-light);
}
.sk-hero-top {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  margin-bottom: var(--sp-4);
}
.sk-hero-main {
  display: flex;
  align-items: center;
  gap: var(--sp-4);
}
.sk-hero-thumb { width: 56px; height: 40px; flex: none; } /* 对齐 hero-ic 产出图标位 */
.sk-hero-name { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 8px; }
.sk-hero-fig { display: flex; flex-direction: column; align-items: flex-end; gap: 8px; flex: none; }
.sk-hero-big { width: 96px; height: 26px; } /* 对齐 .hero-num 大数（fs-display 档） */
</style>
