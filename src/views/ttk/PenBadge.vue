<script setup>
// 穿透等级徽标（legacy .pen[data-p] 0-7 全档样式保留，7 级为本页范围外的 .338 栓狙预留）
defineProps({
  p: { type: Number, required: true },
})
</script>

<template>
  <span class="pen" :data-p="p">{{ p }}<span class="u">级</span></span>
</template>

<style scoped>
/* 等级色板取自 base.css --lv0..--lv6（游戏语义：1白 2绿 3蓝 4紫 5金 6红） */
.pen {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: none;
  min-width: 20px;
  height: 20px;
  padding: 0 6px;
  border-radius: var(--radius-sm);
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  font-weight: 700;
  letter-spacing: .04em;
  color: var(--bg);
  background: var(--pc, var(--lv0));
}
.pen[data-p="0"] { --pc: var(--lv0); }
.pen[data-p="1"] { --pc: var(--lv1); }
.pen[data-p="2"] { --pc: var(--lv2); }
.pen[data-p="3"] { --pc: var(--lv3); }
.pen[data-p="4"] { --pc: var(--lv4); }
.pen[data-p="5"] { --pc: var(--lv5); }
.pen[data-p="6"] { --pc: var(--lv6); }
.pen[data-p="7"] { --pc: var(--lv6); background: linear-gradient(135deg, var(--lv6), color-mix(in srgb, var(--lv6) 62%, var(--bg))); }
.pen .u {
  font-size: var(--fs-micro);
  font-weight: 400;
  opacity: .75;
  margin-left: 1px;
}
</style>
