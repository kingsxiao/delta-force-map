<script setup>
// 穿透 × 护甲 判定矩阵（legacy renderMatrix L919-947）：
// 行=穿透等级 6→0，列=护甲 0-6；无甲列恒 100%；格类 m0/m50/m75/m100 + 对角线 diag。
import { computed } from 'vue'
import { passRate } from '../../data/ttk/model.js'
import CollapseCol from '../../components/CollapseCol.vue'
import PenBadge from './PenBadge.vue'

defineProps({
  open: { type: Boolean, default: true },
})

defineEmits(['toggle'])

const rows = computed(() => {
  const out = []
  for (let p = 6; p >= 0; p--) {
    const cells = []
    for (let a = 0; a <= 6; a++) {
      const v = a === 0 ? 1 : passRate(p, a)
      cells.push({
        v,
        cls: 'm' + Math.round(v * 100) + (a === p ? ' diag' : ''),
        pc: Math.round(v * 100) + '%',
        label: v === 0 ? '仅碎甲' : v === 0.5 ? '减半' : v === 0.75 ? '衰减' : '全额',
      })
    }
    out.push({ p, cells })
  }
  return out
})

const MX_NOTE = '对角线（弹等级 = 甲等级）为 50% 减半线，即「同级甲弹门槛」。低于对角线一律 0%（护甲破碎前不掉血），高于对角线一级 75%、两级及以上全额。7 级穿透弹为全游戏上限，仅 .338 AP（AWM）与 .50 BMG SLAP（M82）两款，可对 6 级甲保持 75% 通过率。'
</script>

<template>
  <CollapseCol :open="open" label="伤害通过率矩阵" note="0 / 50 / 75 / 100%" @toggle="$emit('toggle')">
    <div class="matrix-wrap">
      <table class="matrix">
        <thead>
          <tr>
            <th class="rw">弹 ↓ / 甲 →</th>
            <th v-for="a in 7" :key="'h' + a">{{ a - 1 === 0 ? '无甲' : (a - 1) + ' 级' }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="row in rows" :key="'p' + row.p">
            <th class="rw"><PenBadge :p="row.p" /></th>
            <td v-for="(cell, ci) in row.cells" :key="ci" :class="cell.cls">
              <span class="pc">{{ cell.pc }}</span>{{ cell.label }}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <div class="mx-note">{{ MX_NOTE }}</div>
  </CollapseCol>
</template>

<style scoped>
.matrix-wrap {
  overflow-x: auto;
  padding: var(--sp-3) var(--sp-4);
}
.matrix {
  border-collapse: collapse;
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  min-width: 520px;
  font-variant-numeric: tabular-nums;
}
.matrix th {
  font-weight: 400;
  font-size: var(--fs-micro);
  letter-spacing: .14em;
  color: var(--faint);
  padding: 7px 8px;
  text-align: center;
  white-space: nowrap;
}
.matrix th.rw { text-align: left; }
.matrix td {
  padding: 8px 8px;
  text-align: center;
  border: 1px solid var(--line2);
  min-width: 56px;
  color: var(--dim);
  position: relative; /* 格 hover 面纱（::after）的定位锚 */
}
.matrix td .pc {
  display: block;
  font-size: var(--fs-xs);
  font-weight: 600;
}
/* 通过率语义色：绿=全额 / 琥珀=衰减 · 减半 / 红=仅碎甲（取自 base.css 反馈色） */
.matrix td.m100 .pc { color: var(--ok); }
.matrix td.m75 .pc { color: var(--accent); }
.matrix td.m50 .pc { color: var(--accent); }
.matrix td.m0 .pc { color: var(--danger); }
/* 半透明派生底色范本（规则 7）：rgba 兜底一行在前（真值与 color-mix 百分比一致），
   color-mix(in srgb, var(--语义色) N%, transparent) 在后；底一律 8-12% 带 */
.matrix td.m100 { background: rgba(133, 181, 120, .11); background: color-mix(in srgb, var(--ok) 11%, transparent); }
.matrix td.m75 { background: rgba(45, 212, 191, .11); background: color-mix(in srgb, var(--accent) 11%, transparent); }
.matrix td.m50 { background: rgba(45, 212, 191, .08); background: color-mix(in srgb, var(--accent) 8%, transparent); }
.matrix td.m0 { background: rgba(217, 106, 89, .09); background: color-mix(in srgb, var(--danger) 9%, transparent); }
.matrix td.diag { box-shadow: inset 0 0 0 1px var(--accent-dim); }
/* 格 hover 高亮：--lift 白 6% 面纱叠在语义底色之上（全站通用 hover 面，MOTION.md §3-D：
   颜色/底三态切换、无位移）。四类格同一规则成立、不动各语义底色本体；只动 opacity（§6-1）。
   「选中」交互不存在（格不可点、无选中态业务），不另造状态 */
.matrix td::after {
  content: "";
  position: absolute;
  inset: 0;
  background: var(--lift);
  opacity: 0;
  transition: opacity var(--t-fast) var(--ease);
  pointer-events: none;
}
.matrix tbody td:hover::after { opacity: 1; }
.matrix :deep(.pen) { margin-right: 7px; }
.mx-note {
  padding: 0 var(--sp-4) var(--sp-3);
  font-size: var(--fs-xs);
  color: var(--faint);
  line-height: 1.7;
}
@media (prefers-reduced-motion: reduce) {
  .matrix td::after { transition: none; } /* 面纱瞬现瞬隐：状态反馈而非位移，保留 */
}
</style>
