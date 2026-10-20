<script setup>
// 弹药库单口径折叠列（legacy renderAmmo L855-916 的组件化）：
// "参考单发"= 口径基准枪面板 × 弹药系数（四舍五入到 0.1）；
// 备注列聚合弹药 note / est 与口径 est。open 状态由父组件持有（初始全收起，§6.3；
// 与 legacy renderAmmo 仅装配一次、筛选切换不重置的口径一致）。
import { computed } from 'vue'
import { GUNS } from '../../data/ttk/guns.js'
import { fmtCoef } from './format.js'
import CollapseCol from '../../components/CollapseCol.vue'
import PenBadge from './PenBadge.vue'

const props = defineProps({
  calKey: { type: String, required: true },
  cal: { type: Object, required: true },
  open: { type: Boolean, default: true },
})

defineEmits(['toggle'])

const gunsOf = computed(() =>
  GUNS.filter((g) => g.cal === props.calKey).map((g) => g.zh).join(' / '))

const countText = computed(() =>
  props.cal.sub + ' · ' + props.cal.ammo.length + ' 弹 · ' + gunsOf.value)

function refShot(am) {
  const rf = Math.round(props.cal.base * (am.flesh || 1) * 10) / 10
  const ra = Math.round(props.cal.armor * (am.amult || 1) * 10) / 10
  return rf + ' / ' + ra
}

function remark(am) {
  const bits = []
  if (am.note) bits.push(am.note)
  if (am.est) bits.push('置信度较低')
  if (props.cal.est) bits.push('口径数据置信度较低')
  return bits.join(' · ') || '—'
}
</script>

<template>
  <CollapseCol :open="open" :label="cal.label" :note="countText" @toggle="$emit('toggle')">
    <div class="tbl-wrap">
      <table class="tbl">
        <thead>
          <tr>
            <th>弹药</th><th>穿透</th><th>肉伤系数</th><th>甲伤系数</th><th>参考单发（肉/甲）</th><th>备注</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="am in cal.ammo" :key="am.n">
            <td class="strong">{{ am.n }}</td>
            <td><PenBadge :p="am.pen" /></td>
            <td class="mono num">{{ fmtCoef(am.flesh) }}</td>
            <td class="mono num">{{ fmtCoef(am.amult) }}</td>
            <td class="mono num">{{ refShot(am) }}</td>
            <td class="dimc">{{ remark(am) }}</td>
          </tr>
        </tbody>
      </table>
    </div>
    <p v-if="cal.note" class="cal-note">※ {{ cal.note }}</p>
  </CollapseCol>
</template>

<style scoped>
/* 表格基座（.tbl：表头/斑马纹/数字对齐）由 base.css 全局提供 */
.tbl-wrap {
  overflow-x: auto;
  padding: var(--sp-3) var(--sp-4);
}
.tbl { min-width: 640px; }
.cal-note {
  font-size: var(--fs-xs);
  color: var(--faint);
  padding: 0 var(--sp-4) var(--sp-2);
}
</style>
