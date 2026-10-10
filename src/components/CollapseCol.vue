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
  box-shadow: var(--edge-light), inset 0 0 0 1px rgba(255, 255, 255, .02);
}
/* 展开态：左缘主色细条（70% 感知充分）+ 提亮描边，折叠列表里一眼可辨哪些已展开 */
.col.open {
  border-color: var(--line-hover);
  box-shadow: var(--edge-light), inset 2px 0 0 rgba(45, 212, 191, .7);
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
  transition: background var(--t-med);
}
.col-head:hover { background: var(--row-hover); }
.col-label { flex: 1; min-width: 0; }
.col-note {
  font-size: var(--fs-xs);
  font-weight: 400;
  color: var(--faint);
  white-space: nowrap;
}
.chev {
  flex: none;
  color: var(--faint);
  transition: transform .25s var(--ease), color var(--t-med);
}
.col.open .chev { transform: rotate(180deg); color: var(--accent); }
.col-body {
  display: grid;
  grid-template-rows: 0fr;
  transition: grid-template-rows .25s var(--ease);
}
.col.open .col-body { grid-template-rows: 1fr; }
.col-inner { overflow: hidden; }
@media (prefers-reduced-motion: reduce) {
  .col-head, .chev, .col-body, .col { transition: none; }
}
</style>
