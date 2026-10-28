<script setup>
// 穿透 × 护甲 判定矩阵（legacy renderMatrix L919-947）：
// 行=穿透等级 6→0，列=护甲 0-6；无甲列恒 100%；格类 m0/m50/m75/m100 + 对角线 diag。
import { computed, reactive } from 'vue'
import { passRate } from '../../data/ttk/model.js'
import CollapseCol from '../../components/CollapseCol.vue'
import PenBadge from './PenBadge.vue'

defineProps({
  open: { type: Boolean, default: true },
})

defineEmits(['toggle'])

/* 锁定十字（hover 十字引导的触屏等价物）：触屏没有 hover，横滚查值时行头随
   sticky 常驻、列头却可能滚出视口——点击任一格把「行 × 列」两轴面纱钉住，
   列头同步点亮，「几级弹打几级甲」的对照不再靠手指遮挡下的记忆；再点同格解锁。
   不给格挂 role/tabindex：格值自含（面纱不承载独占信息），锁定是纯引导增强，
   49 个 tabindex 停留点反而毁掉表格的键盘扫读流 */
const lock = reactive({ p: null, a: null })
function toggleLock(row, ci) {
  if (lock.p === row.p && lock.a === ci) { lock.p = null; lock.a = null }
  else { lock.p = row.p; lock.a = ci }
}

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

const MX_NOTE = '对角线（弹等级 = 甲等级）为 50% 减半线，即「同级甲弹门槛」。低于对角线一律 0%（护甲破碎前不掉血），高于对角线一级 75%、两级及以上全额。7 级穿透弹为全游戏上限，仅 .338 AP（AWM）与 .50 BMG SLAP（M82）两款，可对 6 级甲保持 75% 通过率。点击任意格可锁定该行×列的对照高亮（再点同格解锁），触屏查值同样可用。'
</script>

<template>
  <CollapseCol :open="open" label="伤害通过率矩阵" note="0 / 50 / 75 / 100%" @toggle="$emit('toggle')">
    <div class="matrix-wrap">
      <table class="matrix">
        <thead>
          <tr>
            <th class="rw">弹 ↓ / 甲 →</th>
            <th v-for="a in 7" :key="'h' + a" :class="{ 'lk-h': lock.a === a - 1 }">{{ a - 1 === 0 ? '无甲' : (a - 1) + ' 级' }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="row in rows" :key="'p' + row.p" :class="{ 'lk-row': lock.p === row.p }">
            <th class="rw"><PenBadge :p="row.p" /></th>
            <td
              v-for="(cell, ci) in row.cells"
              :key="ci"
              :class="[cell.cls, { 'lk-col': lock.a === ci, lk: lock.p === row.p && lock.a === ci }]"
              @click="toggleLock(row, ci)"
            >
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
  cursor: pointer; /* 格可点锁定（点击=切换，非导航跳转）：光标语义与行为一致，
                      桌面查值时的第一手可供性，不依赖 MX_NOTE 文字说明 */
}
.matrix td .pc {
  display: block;
  font-size: var(--fs-xs);
  font-weight: 600;
}
/* 通过率语义色：绿=全额 / 青=衰减 · 减半 / 红=仅碎甲（取自 base.css 反馈色；
   75/50 同用 --accent 仅底色带 11%/8% 分层——初版琥珀已全站弃用，注释同步纠偏防照注改色） */
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
/* 查值十字引导：悬停行内任一格或行头 → 整行面纱（原单格 hover 升级为行级，td:hover
   必然伴随 tr:hover）；列向走 :has() 渐进增强——悬停列头或列内任一格点亮整列，
   7×7 矩阵「3 级弹打 4 级甲」这类交叉查值不再纯靠眼睛横竖对齐。
   面纱不承载独占信息（格内自含数值与文案），触屏无损失；不支持 :has 的环境
   退回行级高亮，功能完整（@supports 特性检测，老浏览器不降级） */
.matrix tbody tr:hover td::after { opacity: 1; }
@supports selector(:has(*)) {
  .matrix:has(thead th:nth-child(2):hover) tbody td:nth-child(2)::after,
  .matrix:has(tbody td:nth-child(2):hover) tbody td:nth-child(2)::after,
  .matrix:has(thead th:nth-child(3):hover) tbody td:nth-child(3)::after,
  .matrix:has(tbody td:nth-child(3):hover) tbody td:nth-child(3)::after,
  .matrix:has(thead th:nth-child(4):hover) tbody td:nth-child(4)::after,
  .matrix:has(tbody td:nth-child(4):hover) tbody td:nth-child(4)::after,
  .matrix:has(thead th:nth-child(5):hover) tbody td:nth-child(5)::after,
  .matrix:has(tbody td:nth-child(5):hover) tbody td:nth-child(5)::after,
  .matrix:has(thead th:nth-child(6):hover) tbody td:nth-child(6)::after,
  .matrix:has(tbody td:nth-child(6):hover) tbody td:nth-child(6)::after,
  .matrix:has(thead th:nth-child(7):hover) tbody td:nth-child(7)::after,
  .matrix:has(tbody td:nth-child(7):hover) tbody td:nth-child(7)::after,
  .matrix:has(thead th:nth-child(8):hover) tbody td:nth-child(8)::after,
  .matrix:has(tbody td:nth-child(8):hover) tbody td:nth-child(8)::after { opacity: 1; }
}
/* 锁定十字（点击格触发，见 script lock）：行/列面纱与 hover 共用 ::after（同为
   --lift 引导面，两态可叠加不冲突）；交叉点格描边取 --accent-dim——与 .diag
   同值同语言，锁定点恰在对角线上时同属性同值、零覆盖冲突 */
.matrix tbody tr.lk-row td::after { opacity: 1; }
.matrix td.lk-col::after { opacity: 1; }
.matrix td.lk { box-shadow: inset 0 0 0 1px var(--accent-dim); }
/* 锁定列头点亮：faint→dim 提一档 + 底缘 2px --accent-dim 指示条——列轴的
   「几级甲」标签本身成立，是触屏查值时唯一常驻的列上下文（行上下文有 sticky 行头） */
.matrix thead th.lk-h {
  color: var(--dim);
  box-shadow: inset 0 -2px 0 var(--accent-dim);
}
/* 悬停列头点亮（hover 十字的列轴反馈）：悬停某列（列头或列内任一格）时该列头同步
   提亮——列头是交叉查值时唯一常驻的「几级甲」文字锚点，格子面纱亮了而列头恒暗会
   迫使用户数列数对位。配方与锁定态 .lk-h 完全同值（同轴同语言，两态叠加无覆盖冲突；
   只改 color/box-shadow 状态属性、零过渡零位移）。行头是 PenBadge 等级色标、无暗字
   可提，锁定注释已声明徽章不动色，此处同理不加 */
@supports selector(:has(*)) {
  .matrix:has(thead th:nth-child(2):hover) thead th:nth-child(2),
  .matrix:has(tbody td:nth-child(2):hover) thead th:nth-child(2),
  .matrix:has(thead th:nth-child(3):hover) thead th:nth-child(3),
  .matrix:has(tbody td:nth-child(3):hover) thead th:nth-child(3),
  .matrix:has(thead th:nth-child(4):hover) thead th:nth-child(4),
  .matrix:has(tbody td:nth-child(4):hover) thead th:nth-child(4),
  .matrix:has(thead th:nth-child(5):hover) thead th:nth-child(5),
  .matrix:has(tbody td:nth-child(5):hover) thead th:nth-child(5),
  .matrix:has(thead th:nth-child(6):hover) thead th:nth-child(6),
  .matrix:has(tbody td:nth-child(6):hover) thead th:nth-child(6),
  .matrix:has(thead th:nth-child(7):hover) thead th:nth-child(7),
  .matrix:has(tbody td:nth-child(7):hover) thead th:nth-child(7),
  .matrix:has(thead th:nth-child(8):hover) thead th:nth-child(8),
  .matrix:has(tbody td:nth-child(8):hover) thead th:nth-child(8) {
    color: var(--dim);
    box-shadow: inset 0 -2px 0 var(--accent-dim);
  }
}
/* 锁定行头点亮：与列头 lk-h 同配方、轴向对称（列头底缘 / 行头右缘）——锁定十字
   两轴反馈成对成立；行面纱 --lift 仅 6% 白且与 hover 同视觉，鼠标移开后行轴
   「当前几级弹」的锚光靠面纱太弱，徽章本身不动色（等级语义色不被锁定态覆盖） */
.matrix tbody tr.lk-row th.rw {
  box-shadow: inset -2px 0 0 var(--accent-dim);
}
/* （原此处有 :deep(.pen) margin-right:7px——行头 th.rw 内徽章是唯一子节点，
   无后续内容、margin 无视觉只虚占 7px 列宽，删） */
/* ≤680 行头（穿透等级列）吸附左侧：表 min-width 520px 在该断点以下必然横滚，
   向右滑读护甲列时「当前几级弹」的行上下文随滚走。底取不透明 --card 盖住下滑过的
   格块（本表格块带语义底色，透底会串色），分界线与格块描边同语言 */
@media (max-width: 680px) {
  .matrix th.rw {
    position: sticky;
    left: 0;
    z-index: 1;
    background: var(--card);
    box-shadow: inset -1px 0 0 var(--line2);
  }
}
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
