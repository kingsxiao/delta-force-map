<script setup>
/* ============================================================
   ItemNotes — 弹种「口径脚注」组（全表展开行 / 详情页共用）
   ------------------------------------------------------------
   四段脚注自上而下：买入/挂卖口径 → 官方均价偏离 → 军需处兑换折算
   （Playbook 01「军需处倒挂」的数据面）→ 预计卖出（文案单一源
   ./etaLine.js）。原为 AmmoMarketView 展开行内联段落，详情页需要同款
   内容时抽为组件；官方均价偏离告警阈值与服务端 analyze 同款 0.15。
   ============================================================ */
import { computed } from 'vue'
import { fmt, pct } from '../../utils/format.js'
import { etaLine } from './etaLine.js'

const props = defineProps({
  item: { type: Object, required: true },
})

const OFFICIAL_DEV_WARN = 0.15
const eta = computed(() => etaLine(props.item))
</script>

<template>
  <p class="note">
    口径：买入参考 {{ fmt(item.p25) }}（7 天 P25）/ 目标挂卖 {{ fmt(item.targetSell) }}（近 3 天 75 分位，税后到手 {{ fmt(item.netSell) }}）/
    税率 {{ (item.taxRate * 100).toFixed(0) }}%。价格回到目标价即可挂卖<template v-if="item.stopLoss">，破 {{ fmt(item.stopLoss) }} 止损离场</template>；急用钱可按现价直接出。
  </p>
  <p v-if="item.official" class="note">
    官方均价 {{ fmt(item.official.avg) }}（腾讯官方约 24h 一轮的对账口径，旁路参照不进信号）：现价偏离
    <b :class="Math.abs(item.official.dev) > OFFICIAL_DEV_WARN ? 'off-bad' : ''">{{ pct(item.official.dev) }}</b>；偏离大 = 刚剧烈波动或上游口径暂漂，动手前先看曲线确认。
  </p>
  <!-- 军需处兑换折算：弹价地板参照（倒挂明显时先扫军需处） -->
  <p v-if="item.trade" class="note">
    军需处兑换折算 <b>{{ fmt(item.trade.costPerRound) }}</b>/发（{{ item.trade.materials.map((m) => `${m.count}×${m.name}`).join(' + ') }} → {{ item.trade.perCount }} 发）：
    现价 {{ fmt(item.current) }}<template v-if="item.trade.costPerRound > 0"> 高出折算价 <b>{{ pct(item.current / item.trade.costPerRound - 1) }}</b></template><template v-if="item.current / item.trade.costPerRound - 1 > 0.3">——倒挂明显，先扫军需处再倒，别直接扫交易行</template>。
  </p>
  <p v-if="eta" class="note eta">
    <b>预计卖出</b>：{{ eta }}（历史统计，不代表未来）。
  </p>
</template>

<style scoped>
.note { color: var(--faint); font-size: var(--fs-xs); margin: 10px 2px 2px; line-height: 1.8; }
.note b { color: var(--dim); }
/* 官方均价偏离超阈值的数值：danger 实感（数据可疑语义） */
.note b.off-bad { color: var(--danger); }
/* 预计卖出脚注：--accent 预测语义由 b 着色承担 */
.note.eta { color: var(--dim); }
.note.eta b { color: var(--accent); }
</style>
