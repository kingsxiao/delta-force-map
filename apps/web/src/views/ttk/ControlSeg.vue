<script setup>
// 分段控件（legacy buildSeg L588 / segDefs L617-644 的通用化）：
// items 支持 {v,label,title?,dot?,cls?} 与 {div:true} 分隔线两种条目；
// 单选模式（默认）：点选中项不重复 emit（legacy L610 if(get()===it.v) return 同口径）；
// 多选模式（multiple）：modelValue 为数组，点击切换选中态并 emit 新数组，
// "至少保留一项 / 全部"等守卫由父组件在 update 回调里处理。
import { onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'

const props = defineProps({
  items: { type: Array, required: true },
  modelValue: { type: [String, Number, Array], default: null },
  multiple: { type: Boolean, default: false },
  // 组名（可选）：落到 role="group" 的 aria-label——可见的 .ctrl-label 是纯视觉 span，
  // 与组内按钮无关联，读屏需要可辨识的组名
  name: { type: String, default: '' },
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

/* ---------- 单选滑动指示（MOTION.md §3-B 分段控件选中指示的滑动） ----------
   选中底从「逐钮换底」改为绝对定位滑块随选中项滑动。位移走 transform 过渡（220ms）；
   宽高不参与过渡——组内按钮宽度不等（如 排序 TTK/发数），切换时滑块先瞬时变
   宽/变窄再滑动到位（动画 width 属红线，scaleX 会扭曲圆角，取舍为瞬变宽 + 滑动）。
   挂载帧先量位并渲染一帧，双 rAF + 首跳强制读 offsetWidth 提交样式后才挂过渡类——
   单 rAF 回调先于 style recalc，会与 mounted 写入同帧合并而触发从 (0,0) 滑入（复核实测）。
   字体晚到 / 断点换行的错位由 ResizeObserver 兜底：同时观察容器与每个按钮（≤680
   断点 .seg 定宽 100%，只观察容器会漏掉「按钮变宽而容器不变」），重测与选中切换
   同走 220ms 滑动贴合（过渡常开，非瞬时）。
   多选组不适用（可多项同时选中），不渲染滑块、保留逐钮 chip 三态。 */
const rootEl = ref(null)
const pill = reactive({ x: 0, y: 0, w: 0, h: 0, on: false, ready: false })

function measure() {
  if (props.multiple || !rootEl.value) return
  const btn = rootEl.value.querySelector('.seg-btn.on')
  if (!btn) { pill.on = false; return }
  pill.x = btn.offsetLeft
  pill.y = btn.offsetTop
  pill.w = btn.offsetWidth
  pill.h = btn.offsetHeight
  pill.on = true
}

let ro = null
onMounted(() => {
  measure()
  requestAnimationFrame(() => {
    // 强制一次样式/布局提交（读 offsetWidth），确保首帧以已定位、无过渡的滑块渲染
    if (rootEl.value) void rootEl.value.offsetWidth
    requestAnimationFrame(() => { pill.ready = true })
  })
  if (typeof ResizeObserver !== 'undefined') {
    ro = new ResizeObserver(measure)
    ro.observe(rootEl.value)
    rootEl.value.querySelectorAll('.seg-btn').forEach((b) => ro.observe(b))
  }
})
onBeforeUnmount(() => { if (ro) ro.disconnect() })
// flush post：等 .on 类落到新按钮后再量位置（watch 默认 pre 会在 DOM 更新前跑）
watch(() => props.modelValue, measure, { flush: 'post' })
</script>

<template>
  <div ref="rootEl" class="seg" :class="{ single: !multiple }" role="group" :aria-label="name || undefined">
    <!-- 单选滑块（量位元素）：选中面随选中项滑动；多选组不渲染 -->
    <span
      v-if="!multiple"
      class="seg-pill"
      :class="{ on: pill.on, ready: pill.ready }"
      :style="{ width: pill.w + 'px', height: pill.h + 'px', transform: 'translate(' + pill.x + 'px,' + pill.y + 'px)' }"
      aria-hidden="true"
    ></span>
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
  background: var(--bg2); /* 分段控件槽底与 .fig-tabs 统一（MapViewer），不再用更暗的 --bg */
  border: 1px solid var(--line2);
  border-radius: var(--radius);
  padding: 3px;
  max-width: 100%;
  position: relative; /* 滑块 offsetLeft/offsetTop 的定位锚（offsetParent） */
}
/* 单选滑块：选中底（card2，与旧 .seg-btn.on 同面）转移到绝对定位实体，切换时滑动；
   visibility 兜底——量到选中钮前不露面（挂载同帧即量到，常态不可见窗口极短） */
.seg-pill {
  position: absolute;
  left: 0;
  top: 0;
  border-radius: var(--radius-sm);
  background: var(--card2);
  visibility: hidden;
}
.seg-pill.on { visibility: visible; }
.seg-pill.ready { transition: transform var(--t-slow) var(--ease); }
.seg-btn {
  border: 0;
  background: none;
  color: var(--dim);
  font-size: var(--fs-xs);
  padding: 4.5px 11px;
  border-radius: var(--radius-sm);
  cursor: pointer;
  transition: color var(--t-fast) var(--ease), background var(--t-fast) var(--ease);
  white-space: nowrap;
  display: inline-flex;
  position: relative; /* 滑块遮字修复：无 position 的按钮绘制在绝对定位滑块之下（定位元素
                        绘制在普通流内容之上，与 DOM 顺序无关）；relative 后与滑块同为
                        定位元素、按 DOM 顺序（按钮在后）绘制在其上 */
  align-items: center;
  gap: 6px;
  font-variant-numeric: tabular-nums;
}
.seg-btn:hover { color: var(--tx); background: var(--lift); }
/* 按下同 hover（规格「单选/分段」）；置于 .on 之前——选中项按下仍保持选中观感 */
.seg-btn:active { color: var(--tx); background: var(--lift); }
.seg-btn.on { background: var(--card2); color: var(--accent); }
/* 单选组：选中面交给滑块，按钮只留文字变色（滑块与按钮底不叠加）；
   多选组不受影响，仍逐钮换底 */
.single .seg-btn.on { background: none; }
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
  /* 全宽堆叠下按钮均衡分摊行宽；字阶降一档与 .ctrl-label 的紧凑堆叠形态匹配 */
  .seg-btn { flex: 1 1 auto; justify-content: center; padding: 4px 9px; font-size: var(--fs-2xs); }
}
@media (prefers-reduced-motion: reduce) {
  .seg-btn { transition: none; }
  /* 须写 .ready（0,2,0）匹配特异性——media query 不提升特异性，
     单写 .seg-pill（0,1,0）压不过 .seg-pill.ready 的过渡（复核实测） */
  .seg-pill.ready { transition: none; } /* 滑块瞬移，选中态语义不变 */
}
</style>
