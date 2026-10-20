<script setup>
// HotspotLayer.vue — 标注层（工程师A）：按 x/y 百分比渲染 .hs 按钮（指针点击判定由
// useViewer 的 vp 指针 tap 逻辑通过 closest('.hs')+dataset.i 完成，与 legacy 一致）；
// 键盘/读屏路径在此补齐——聚焦按钮 Enter/空格的合成 click（e.detail===0）emit 开卡，
// 指针 click（detail>0）一律忽略以免与 vp tap 路径双触发；
// 类型图层开关经 hidden 对象映射为 .hide-* 类（legacy L645-666）。
import { HS_TYPES } from '../../composables/useViewer'

const emit = defineEmits(['open'])

defineProps({
  hs: { type: Array, required: true },
  active: { type: Number, default: -1 },
  hidden: { type: Object, required: true }, // { spawn, extract, boss, loot } -> bool
})

/* 只接键盘/读屏合成点击：按钮被 Enter/空格激活时浏览器派发的 click 无指针计数（detail 0）；
   真指针 click detail≥1 直接返回，且不 preventDefault——保住按钮原生激活与后续默认行为 */
function onHsClick(i, e) {
  if (e.detail !== 0) return
  emit('open', i)
}
</script>

<template>
  <div
    class="hs-layer"
    :class="{
      'hide-spawn': hidden.spawn,
      'hide-extract': hidden.extract,
      'hide-boss': hidden.boss,
      'hide-loot': hidden.loot,
    }"
  >
    <button
      v-for="(sp, i) in hs"
      :key="i"
      type="button"
      class="hs"
      :class="['t-' + sp.type, { active: active === i }]"
      :style="{ left: sp.x * 100 + '%', top: sp.y * 100 + '%' }"
      :data-i="i"
      :aria-label="(HS_TYPES[sp.type] || sp.type) + '：' + sp.name"
      @click="onHsClick(i, $event)"
    >
      <i></i>
    </button>
  </div>
</template>

<style scoped>
/* legacy CSS L87-96 原样 */
.hs-layer { position: absolute; inset: 0; pointer-events: none; }
.hs {
  position: absolute;
  width: 15px;
  height: 15px;
  padding: 0;
  margin: 0;
  border: 0;
  background: none;
  cursor: pointer;
  pointer-events: auto;
  transform: translate(-50%, -50%) scale(var(--inv, 1));
}
/* §5.8 active 放大：合成式 transform 保留中心偏移与 --inv 反向缩放补偿；
   不加 transform 过渡——--inv 随地图缩放连续变化，过渡会让拖拽缩放时点位回弹，
   平滑感由 i 的 box-shadow 过渡承担（态切换瞬时跳变可接受） */
.hs.active {
  transform: translate(-50%, -50%) scale(calc(var(--inv, 1) * 1.15));
}
.hs i {
  display: block;
  width: 100%;
  height: 100%;
  background: var(--hc);
  border: 1.5px solid rgba(9, 12, 15, 0.9);
  box-shadow: 0 0 0 1.5px rgba(240, 244, 247, 0.85), 0 1px 5px rgba(0, 0, 0, 0.6);
  /* 手写 0.15s 收编 var(--t-fast)+var(--ease)（§动效一律令牌） */
  transition: box-shadow var(--t-fast) var(--ease);
}
.hs.t-spawn { --hc: var(--hs-spawn); }
.hs.t-spawn i { border-radius: 50%; }
.hs.t-extract { --hc: var(--hs-extract); }
.hs.t-extract i { border-radius: 3px; }
.hs.t-loot { --hc: var(--hs-loot); }
.hs.t-loot i { border-radius: 2px; transform: rotate(45deg) scale(0.86); }
.hs.t-boss { --hc: var(--hs-boss); width: 17px; height: 17px; }
.hs.t-boss i {
  border-radius: 50%;
  box-shadow: 0 0 0 1.5px rgba(240, 244, 247, 0.85), 0 0 0 3.5px color-mix(in srgb, var(--hs-boss) 35%, transparent), 0 1px 5px rgba(0, 0, 0, 0.6);
}
.hs:hover i,
.hs.active i {
  box-shadow: 0 0 0 1.5px rgba(240, 244, 247, 0.85), 0 0 0 4px rgba(240, 244, 247, 0.28), 0 2px 8px rgba(0, 0, 0, 0.7);
}
.hs-layer.hide-spawn .t-spawn,
.hs-layer.hide-extract .t-extract,
.hs-layer.hide-boss .t-boss,
.hs-layer.hide-loot .t-loot { display: none; }

@media (prefers-reduced-motion: reduce) {
  .hs i { transition: none; }
}
</style>
