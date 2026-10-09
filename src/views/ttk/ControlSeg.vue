<script setup>
// 分段控件（legacy buildSeg L588 / segDefs L617-644 的通用化）：
// items 支持 {v,label,title?,dot?,cls?} 与 {div:true} 分隔线两种条目；
// 单选模式（默认）：点选中项不重复 emit（legacy L610 if(get()===it.v) return 同口径）；
// 多选模式（multiple）：modelValue 为数组，点击切换选中态并 emit 新数组，
// "至少保留一项 / 全部"等守卫由父组件在 update 回调里处理。
defineProps({
  items: { type: Array, required: true },
  modelValue: { type: [String, Number, Array], default: null },
  multiple: { type: Boolean, default: false },
})

const emit = defineEmits(['update:modelValue'])

function isOn(it, modelValue, multiple) {
  return multiple ? (modelValue || []).includes(it.v) : it.v === modelValue
}

function pick(it, modelValue, multiple) {
  if (it.div || it.v === undefined) return
  if (multiple) {
    const arr = modelValue || []
    emit('update:modelValue', arr.includes(it.v) ? arr.filter((x) => x !== it.v) : arr.concat(it.v))
    return
  }
  if (it.v === modelValue) return
  emit('update:modelValue', it.v)
}
</script>

<template>
  <div class="seg" role="group">
    <template v-for="(it, i) in items" :key="i">
      <span v-if="it.div" class="seg-div" aria-hidden="true"></span>
      <button
        v-else
        type="button"
        class="seg-btn"
        :class="[it.cls, { on: isOn(it, modelValue, multiple) }]"
        :title="it.title || null"
        :aria-pressed="String(isOn(it, modelValue, multiple))"
        @click="pick(it, modelValue, multiple)"
      >
        <span v-if="it.dot != null" class="lv-dot" :style="{ '--lv': it.dot }" aria-hidden="true"></span>{{ it.label }}
      </button>
    </template>
  </div>
</template>

<style scoped>
.seg {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 2px;
  background: var(--bg);
  border: 1px solid var(--line2);
  border-radius: var(--radius);
  padding: 3px;
  max-width: 100%;
}
.seg-btn {
  border: 0;
  background: none;
  color: var(--dim);
  font-size: var(--fs-xs);
  padding: 4.5px 11px;
  border-radius: var(--radius-sm);
  cursor: pointer;
  transition: color var(--t-fast), background var(--t-fast);
  white-space: nowrap;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-variant-numeric: tabular-nums;
}
.seg-btn:hover { color: var(--tx); background: var(--lift); }
.seg-btn.on { background: var(--card2); color: var(--accent); }
.seg-div {
  width: 1px;
  align-self: stretch;
  margin: 4px 5px;
  background: var(--line2);
  flex: none;
}
.lv-dot {
  width: 8px;
  height: 8px;
  border-radius: 2px;
  background: var(--lv, var(--line-hover));
  flex: none;
  border: 1px solid rgba(255, 255, 255, .14);
}
.seg-btn.none .lv-dot {
  background: transparent;
  border: 1px dashed var(--faint);
}
@media (max-width: 680px) {
  .seg { flex-wrap: wrap; width: 100%; }
  .seg-btn { flex: 1 1 auto; justify-content: center; padding: 5px 9px; }
}
@media (max-width: 560px) {
  .seg-btn { padding: 4px 9px; font-size: var(--fs-2xs); }
}
@media (prefers-reduced-motion: reduce) {
  .seg-btn { transition: none; }
}
</style>
