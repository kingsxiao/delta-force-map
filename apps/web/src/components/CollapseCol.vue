<script setup>
// 折叠列（全站统一）：结构沿袭 legacy 的 .col / .col-head / .col-body / .col-inner，
// 动画用 grid-template-rows 0fr → 1fr（legacy index.html 与 ttk.html 同构实现）。
// open 状态由父组件持有（便于默认展开/联动），点击时 emit('toggle')。
defineProps({
  open: { type: Boolean, default: false },
  label: { type: String, required: true },
  note: { type: String, default: '' },
})

defineEmits(['toggle'])
</script>

<template>
  <div class="col" :class="{ open }">
    <button class="col-head" type="button" :aria-expanded="open" @click="$emit('toggle')">
      <span class="col-label">{{ label }}</span>
      <span v-if="note" class="col-note">{{ note }}</span>
      <svg class="chev" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
        <path
          d="M4 6l4 4 4-4"
          fill="none"
          stroke="currentColor"
          stroke-width="1.6"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
    </button>
    <div class="col-body">
      <div class="col-inner">
        <slot />
      </div>
    </div>
  </div>
</template>

<style scoped>
.col {
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  background: var(--card);
  overflow: hidden;
  box-shadow: var(--edge-light);
  transition: border-color var(--t-med), box-shadow var(--t-med);
}
.col + .col { margin-top: var(--sp-3); }
.col:hover {
  border-color: var(--line-hover);
  box-shadow: var(--edge-hover);
}
/* 展开态：左缘 2px --accent-dim 指示条（展开/选中统一语义；实色 --accent 留给冠军/最佳）
   + 提亮描边，折叠列表里一眼可辨哪些已展开 */
.col.open {
  border-color: var(--line-hover);
  box-shadow: var(--edge-light), inset 2px 0 0 var(--accent-dim);
}
.col-head {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  width: 100%;
  padding: 13px 16px;
  background: none;
  border: 0;
  color: var(--tx-strong);
  cursor: pointer;
  text-align: left;
  font-size: var(--fs-md);
  font-weight: 600;
  line-height: var(--lh-tight); /* 长标题折行时行距不塌缩（button 默认 line-height:normal） */
  transition: background var(--t-med);
}
.col-head:hover { background: var(--row-hover); }
/* 按下态：面再抬一档（--lift），触屏无 hover 时按压可见 */
.col-head:active { background: var(--lift); }
.col-label { flex: 1; min-width: 0; }
.col-note {
  font-size: var(--fs-xs);
  font-weight: 400;
  color: var(--faint);
  white-space: nowrap;
  min-width: 0; /* 窄屏放不下时 note 先于 label 收缩并省略号截断（AmmoTable 的
                   「口径 · N 弹 · 枪名清单」很长），防整行溢出被 .col 裁掉 */
  overflow: hidden;
  text-overflow: ellipsis;
}
.chev {
  flex: none;
  color: var(--faint);
  /* 箭头统一 --t-slow .22s（MOTION.md §3-C 收编三档并存）：略快于折叠体 .25s，
     先转后合，读作同一动作的前导 */
  transition: transform var(--t-slow) var(--ease), color var(--t-fast);
}
.col.open .chev { transform: rotate(180deg); color: var(--accent); }
.col-body {
  display: grid;
  grid-template-rows: 0fr;
  /* 高度动画走 grid-rows 0fr→1fr（只动布局轨，不动画 height）；时长取状态切换档
     --t-panel .25s（--t-collapse 同值历史别名，新代码一律写新名，MOTION.md §2.1） */
  transition: grid-template-rows var(--t-panel) var(--ease);
}
.col.open .col-body { grid-template-rows: 1fr; }
.col-inner { overflow: hidden; }
@media (prefers-reduced-motion: reduce) {
  .col-head, .chev, .col-body, .col { transition: none; }
}
</style>
