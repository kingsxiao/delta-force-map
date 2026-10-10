<script setup>
// 穿透等级徽标，双模式（§5.5）：
// - ghost（默认，密集场景：排行行 / 弹药库 / 矩阵）：1px --lvN 描边 + 12% 色底 + tx-strong 数字，
//   等级信息由描边与色底承载（7 级 = lv6 描边 + lv5 内圈双色描边，弃渐变）；
// - solid（低密度强调：冠军卡 / 护甲一览；仅 5/6 级生效，0-4 一律 ghost）：--lvN 实底 + --bg 数字。
defineProps({
  p: { type: Number, required: true },
  solid: { type: Boolean, default: false },
})
</script>

<template>
  <span class="pen" :data-p="p" :class="{ solid }">{{ p }}<span class="u">级</span></span>
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
  color: var(--tx-strong);
  border: 1px solid var(--pc, var(--lv0));
  background: color-mix(in srgb, var(--pc, var(--lv0)) 12%, transparent);
}
.pen[data-p="0"] { --pc: var(--lv0); }
.pen[data-p="1"] { --pc: var(--lv1); }
.pen[data-p="2"] { --pc: var(--lv2); }
.pen[data-p="3"] { --pc: var(--lv3); }
.pen[data-p="4"] { --pc: var(--lv4); }
.pen[data-p="5"] { --pc: var(--lv5); }
.pen[data-p="6"] { --pc: var(--lv6); }
/* 7 级：双色描边（lv6 外描边 + lv5 内圈），与 0-6 平底语言一致 */
.pen[data-p="7"] { --pc: var(--lv6); box-shadow: inset 0 0 0 1px var(--lv5); }
/* 实底模式：仅 5/6 级（金 / 红），其余级别忽略 solid 保持 ghost */
.pen.solid[data-p="5"],
.pen.solid[data-p="6"] {
  background: var(--pc);
  color: var(--bg);
}
.pen .u {
  font-size: var(--fs-micro);
  font-weight: 400;
  opacity: .75;
  margin-left: 1px;
}
</style>
