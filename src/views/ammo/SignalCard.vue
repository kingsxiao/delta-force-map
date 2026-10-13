<script setup>
/* SignalCard — 买入信号主打卡：弹名 / 买入价 / 目标卖价（税后到手）/ 能赚多少；
   买入卡带数量档位（100 / 500 / 1000 发或自定义）与总额试算。
   卡内走势图降为中性纹理（--spark-line/--spark-fill 局部覆盖），
   --ok 绿只留给左边框与「预赚 / 发」大数字，形成唯一英雄焦点 */
import { ref } from 'vue'
import Sparkline from './Sparkline.vue'

const props = defineProps({
  item: { type: Object, required: true },
  kind: { type: String, default: 'buy' }, // buy | sell
})

const qty = ref(100)

const fmt = (n) => (Number.isFinite(n) ? Math.round(n).toLocaleString('zh-CN') : '—')
const pct = (n) => (Number.isFinite(n) ? `+${(n * 100).toFixed(1)}%` : '—')
// 品级色沿用 base.css --lv* 语义变量（2 绿 ~ 6 红）
const gradeVar = (g) => (g >= 2 && g <= 6 ? `var(--lv${g})` : 'var(--faint)')
</script>

<template>
  <article class="sig-card" :class="kind">
    <header class="sc-head">
      <span class="sc-dot" :style="{ background: gradeVar(item.grade) }" aria-hidden="true"></span>
      <h4 class="sc-name">{{ item.name }}</h4>
      <span class="sc-rank" :title="`当前价处近7天 ${Math.round(item.rank * 100)}% 分位`">
        7天分位 {{ Math.round(item.rank * 100) }}%
      </span>
    </header>

    <Sparkline :curve="item.curve" :width="200" :height="40" class="sc-spark" />

    <!-- 买入卡：买入价 / 目标卖 / 每发利润 / 收益率 + 数量试算 -->
    <template v-if="kind === 'buy'">
      <div class="sc-grid">
        <div class="sc-cell">
          <span class="sc-k">买入价 ≤</span>
          <span class="sc-v strong">{{ fmt(item.current) }}</span>
        </div>
        <div class="sc-cell">
          <span class="sc-k">挂卖价</span>
          <span class="sc-v">{{ fmt(item.targetSell) }}</span>
        </div>
        <div class="sc-cell">
          <span class="sc-k">税后到手</span>
          <span class="sc-v">{{ fmt(item.netSell) }}</span>
        </div>
        <div class="sc-cell hero">
          <span class="sc-k">预赚 / 发</span>
          <span class="sc-v profit">+{{ fmt(item.profitPerRound) }}</span>
          <span class="sc-pct">{{ pct(item.profitPct) }}</span>
        </div>
      </div>

      <div class="sc-qty">
        <span class="sc-k">数量</span>
        <button
          v-for="n in [100, 500, 1000]" :key="n"
          class="qty-chip" :class="{ on: qty === n }" @click="qty = n"
        >{{ n }}</button>
        <input v-model.number="qty" class="qty-in" type="number" min="1" aria-label="自定义数量" />
      </div>
      <div class="sc-totals">
        <span>总投入 <b>{{ fmt(item.current * qty) }}</b></span>
        <span>税后到手 <b>{{ fmt(item.netSell * qty) }}</b></span>
        <span class="tot-profit">总利润 +{{ fmt(item.profitPerRound * qty) }}（{{ pct(item.profitPct) }}）</span>
      </div>

      <footer class="sc-foot">
        什么时候卖：价格回到 <b>{{ fmt(item.targetSell) }}</b>（7 天 75 分位）即挂卖；
        乐观目标 {{ fmt(item.netHigh) }}（7 天高点税后）。税率 {{ (item.taxRate * 100).toFixed(0) }}%。
      </footer>
    </template>

    <!-- 卖出卡：当前价 / 分位 / 建议 -->
    <template v-else>
      <div class="sc-grid">
        <div class="sc-cell">
          <span class="sc-k">当前价</span>
          <span class="sc-v strong">{{ fmt(item.current) }}</span>
        </div>
        <div class="sc-cell">
          <span class="sc-k">7天低点</span>
          <span class="sc-v">{{ fmt(item.weekLow) }}</span>
        </div>
        <div class="sc-cell">
          <span class="sc-k">7天高点</span>
          <span class="sc-v">{{ fmt(item.weekHigh) }}</span>
        </div>
        <div class="sc-cell hero">
          <span class="sc-k">操作</span>
          <span class="sc-v sell">立即挂卖</span>
        </div>
      </div>
      <footer class="sc-foot">现价处 7 天 {{ Math.round(item.rank * 100) }}% 高位，回落风险大于继续上行。</footer>
    </template>
  </article>
</template>

<style scoped>
.sig-card {
  background: var(--card);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 16px 18px;
  display: flex;
  flex-direction: column;
  gap: 12px;
  transition: border-color var(--t-med), transform var(--t-med);
}
.sig-card.buy { border-left: 3px solid var(--ok, #34d399); }
.sig-card.sell { border-left: 3px solid var(--danger, #f87171); }
.sig-card:hover { border-color: var(--line-hover); transform: translateY(-2px); }

.sc-head { display: flex; align-items: center; gap: 8px; }
.sc-dot { width: 8px; height: 8px; flex: none; transform: rotate(45deg); }
.sc-name {
  font-size: var(--fs-md);
  font-weight: 700;
  color: var(--tx-strong);
  margin: 0;
  flex: 1;
  min-width: 0;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.sc-rank { font-family: var(--mono); font-size: var(--fs-2xs); color: var(--faint); white-space: nowrap; }

/* 卡内走势满宽自适应（viewBox 5:1）；颜色降为中性纹理，把绿色焦点让给预赚数字 */
.sc-spark {
  --spark-line: var(--dim);
  --spark-fill: var(--dim);
  display: block; width: 100%; height: auto;
}

.sc-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 10px;
}
.sc-cell { display: flex; flex-direction: column; gap: 2px; }
.sc-k { font-family: var(--mono); font-size: var(--fs-2xs); color: var(--faint); letter-spacing: .08em; }
.sc-v { font-family: var(--mono); font-size: var(--fs-md); color: var(--tx); font-variant-numeric: tabular-nums; }
.sc-v.strong { color: var(--tx-strong); font-weight: 700; }
.sc-v.profit { color: var(--ok, #34d399); font-weight: 700; font-size: var(--fs-lg); }
.sc-v.sell { color: var(--danger, #f87171); font-weight: 700; }
.sc-pct { font-family: var(--mono); font-size: var(--fs-2xs); color: var(--ok, #34d399); }

.sc-qty { display: flex; align-items: center; flex-wrap: wrap; gap: 6px; }
.qty-chip {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  color: var(--dim); font-family: var(--mono); font-size: var(--fs-2xs);
  padding: 2px 10px; cursor: pointer;
}
.qty-chip.on { background: var(--card2); color: var(--accent); border-color: var(--line-hover); }
.qty-in {
  width: 76px; background: var(--card); border: 1px solid var(--line); border-radius: var(--radius);
  color: var(--tx); font-family: var(--mono); font-size: var(--fs-xs); padding: 3px 8px;
}
.qty-in:focus { outline: none; border-color: var(--accent-dim); }
.sc-totals {
  display: flex; flex-wrap: wrap; gap: var(--sp-4);
  border-top: 1px dashed var(--line2); padding-top: 10px;
  font-size: var(--fs-xs); color: var(--dim);
}
.sc-totals b { font-family: var(--mono); color: var(--tx-strong); }
.tot-profit { color: var(--ok, #34d399); font-family: var(--mono); }

.sc-foot {
  font-size: var(--fs-xs);
  color: var(--dim);
  line-height: 1.7;
  border-top: 1px dashed var(--line2);
  padding-top: 10px;
}
.sc-foot b { color: var(--tx-strong); }

@media (max-width: 640px) {
  .sc-grid { grid-template-columns: repeat(2, 1fr); }
}
</style>
