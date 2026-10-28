<script setup>
// 弹药库单口径折叠列（legacy renderAmmo L855-916 的组件化）：
// "参考单发"= 口径基准枪面板 × 弹药系数（四舍五入到 0.1）；
// 备注列聚合弹药 note / est 与口径 est。open 状态由父组件持有（初始全收起，§6.3；
// 与 legacy renderAmmo 仅装配一次、筛选切换不重置的口径一致）。
// 「现价·7 天分位」列联动行情页（TtkView 一次性拉取 market.json 传入 prices）：
// 按 ammo-market-alias 映射查现价，点击跳 /ammo?q=弹名；无映射 / 行情不可用显「—」。
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import { GUNS } from '../../data/ttk/guns.js'
import { ttkAmmoMarketName } from '../../data/ttk/ammo-market-alias.js'
import { fmtCoef } from './format.js'
import CollapseCol from '../../components/CollapseCol.vue'
import PenBadge from './PenBadge.vue'

const props = defineProps({
  calKey: { type: String, required: true },
  cal: { type: Object, required: true },
  open: { type: Boolean, default: true },
  // 行情价格上下文（TtkView 传入）：{ byName: {弹名→行情条目}, ok: 快照是否可用 }
  prices: { type: Object, default: null },
})

defineEmits(['toggle'])

const router = useRouter()

const gunsOf = computed(() => {
  const names = GUNS.filter((g) => g.cal === props.calKey).map((g) => g.zh)
  /* 头注长枪名列表截断：CollapseCol 的 .col-note 不换行，9x19（9 把）/7.62×51（9 把）
     的全量列表在窄屏会被裁。总数「共 N 把」前置、枪名列表放尾部交给省略号收口——
     总数恒在裁剪区之前（「前 3 把 + 等 N 把」的尾部总数写法 390px 下仍会截掉，
     如 .45「大口径手枪弹 · 5 弹 · 维克托 / SMG-45 / 汤姆逊 等 4 把」298 > 286px） */
  return names.length > 3
    ? '共 ' + names.length + ' 把 · ' + names.join(' / ')
    : names.join(' / ')
})

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

/* 行情条目（无映射 / 行情不可用 → null，模板显「—」） */
function marketOf(am) {
  if (!props.prices?.ok) return null
  const name = ttkAmmoMarketName(props.calKey, am.n)
  return name ? props.prices.byName[name] ?? null : null
}
/* 现价·7 天分位 短串：分位缺失（数据不足）只显现价 */
function priceText(i) {
  const cur = Math.round(i.current).toLocaleString('zh-CN')
  return i.rank == null ? cur : cur + ' · ' + Math.round(i.rank * 100) + '%'
}
function gotoMarket(am) {
  const name = ttkAmmoMarketName(props.calKey, am.n)
  if (name) router.push({ path: '/ammo', query: { q: name } })
}
</script>

<template>
  <CollapseCol :open="open" :label="cal.label" :note="countText" @toggle="$emit('toggle')">
    <div class="tbl-wrap">
      <table class="tbl">
        <thead>
          <tr>
            <th>弹药</th><th>穿透</th><th class="num">肉伤系数</th><th class="num">甲伤系数</th><th class="num">参考单发（肉/甲）</th><th class="num">现价·7天分位</th><th>备注</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="am in cal.ammo" :key="am.n" class="data-row">
            <td class="strong">{{ am.n }}</td>
            <td><PenBadge :p="am.pen" /></td>
            <td class="mono num">{{ fmtCoef(am.flesh) }}</td>
            <td class="mono num">{{ fmtCoef(am.amult) }}</td>
            <td class="mono num">{{ refShot(am) }}</td>
            <td class="num">
              <!-- 文本链按钮（§5.3 无底无边框）：现价即入口，跳行情页搜该弹。
                   aria-label：可见名只有「现价 · 分位」数字串，title 仅鼠标可见——
                   触屏与读屏用户都需要一个含弹名的可读名 -->
              <button v-if="marketOf(am)" type="button" class="mp" :title="'去行情页看 ' + ttkAmmoMarketName(calKey, am.n) + ' 走势'" :aria-label="ttkAmmoMarketName(calKey, am.n) + ' 现价与行情走势'" @click="gotoMarket(am)">{{ priceText(marketOf(am)) }}</button>
              <template v-else>—</template>
            </td>
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
.tbl { min-width: 720px; }
.cal-note {
  font-size: var(--fs-xs);
  color: var(--faint);
  padding: 0 var(--sp-4) var(--sp-2);
}
/* 现价文本链（跳行情页）：等宽数字 + accent，hover/active 下划线（规格同 .ammo-toggle）。
   触控垫层：垂直 padding + 等量负 margin——外框占位与文字位置都不变（表格对齐不动），
   命中区从一行文字高（~20px）扩满整行（表格行密度下 44px 原则的可达上限） */
.mp {
  border: 0;
  background: none;
  padding: 9px 0;
  margin: -9px 0;
  font-family: var(--mono);
  font-size: var(--fs-xs);
  letter-spacing: .02em;
  color: var(--accent);
  cursor: pointer;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.mp:hover,
.mp:active { text-decoration: underline; }
/* 触屏垫层再外延（同 RankRow .d-mp / TtkView .ammo-toggle 手法）：9px 垫层后命中区
   约 38px 仍低于 44px 原则，hover:none 下伪元素上下再外延 5px 到位；左右不扩——
   单元格左右各有 10px td padding，外扩会吞掉相邻列的点击。伪元素只承接点击不绘制 */
@media (hover: none) {
  .mp { position: relative; }
  .mp::before {
    content: "";
    position: absolute;
    left: 0;
    right: 0;
    top: -5px;
    bottom: -5px;
  }
}

/* ≤820 首列（弹药名 = 行主键）吸附左侧：表 min-width 720px 在该断点以下必然横滚，
   滚到右侧「现价·分位」列时行主键滚出视口即失去查值上下文（「移动端查值读数」思路：
   读数锚点固定，不做贴指针浮层）。首列自身须不透明底才能盖住下滑过的单元格；
   斑马纹 / 行 hover 是半透明白，直接平涂会吃掉行状态——用「同值渐变层叠不透明底」
   逐态复刻，hover 写在 zebra 之后（覆盖顺序与 base.css 的 tr 级源序一致） */
@media (max-width: 820px) {
  .tbl th:first-child,
  .tbl td:first-child {
    position: sticky;
    left: 0;
    z-index: 1;
    box-shadow: inset -1px 0 0 var(--line2); /* 分界线与 .tbl 行线同语言，滚动时与滑过的格块分层 */
  }
  .tbl td:first-child { background: var(--card); }
  .tbl tbody tr:nth-child(even of :where(.data-row)) td:first-child {
    background-color: var(--card);
    background-image: linear-gradient(var(--zebra), var(--zebra));
  }
  .tbl tbody tr:hover td:first-child {
    background-color: var(--card);
    background-image: linear-gradient(var(--row-hover), var(--row-hover));
  }
}
</style>
