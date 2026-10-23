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
     的全量列表在窄屏会被容器 overflow 硬裁成半截字；收成前 4 把 + 总数 */
  return names.length > 4
    ? names.slice(0, 4).join(' / ') + ' 等 ' + names.length + ' 把'
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
              <!-- 文本链按钮（§5.3 无底无边框）：现价即入口，跳行情页搜该弹 -->
              <button v-if="marketOf(am)" type="button" class="mp" :title="'去行情页看 ' + ttkAmmoMarketName(calKey, am.n) + ' 走势'" @click="gotoMarket(am)">{{ priceText(marketOf(am)) }}</button>
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
/* 现价文本链（跳行情页）：等宽数字 + accent，hover/active 下划线（规格同 .ammo-toggle） */
.mp {
  border: 0;
  background: none;
  padding: 0;
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
</style>
