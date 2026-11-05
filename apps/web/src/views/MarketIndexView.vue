<script setup>
/* MarketIndexView — 市场指数（复刻自 moligod「市场指数」，数据口径自研）
   数据：public/market/index.json（server/market/tradehouse.mjs 落盘）：
     · 五大市场（子弹/配件/枪械/物品/防具）+ 总览指数：level 以「篮子内
       物品昨日均价合计 = 1000」归一，24h 涨跌幅 = level/1000 − 1；篮子 =
       现价与昨日均价双全的物品（缺价如实剔除）
     · history：本服务自积累的小时级指数点（首次部署从零开始，historySince
       如实标注起算时点）；子市场 = 上游 subcategory 分层
     · prediction：集市物品预测（上游 one-flow-market-prediction，2 项，
       max_sell_profit = 预期最高卖出利润）
   与 moligod 指数绝对值不可比（它的基期是自设历史锚点，我们是昨日均价
   锚 + 自积累曲线）；方向与相对强弱可比。 */
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import SkeletonView from '../components/SkeletonView.vue'
import PriceChart from './ammo/PriceChart.vue'
import Sparkline from './ammo/Sparkline.vue'
import { useSnapshotFeed } from '../composables/useSnapshotFeed'
import { fmt, pct } from '../utils/format.js'
import { picThumb } from '@shared/js/marketMeta.js'

let prevTitle = ''

const {
  market, loadState, loadError, refreshing,
  load,
} = useSnapshotFeed(`${import.meta.env.BASE_URL}market/index.json`, {
  events: ['tradehouse'],
  // 本快照无 items 字段（市场在 markets、篮子在 all），默认 accept 会误判空态
  accept: (j) => Array.isArray(j?.markets) && j.markets.length > 0,
  syntaxError: '市场指数数据格式异常，请稍后重试',
  successTip: false,
})

const items = computed(() => market.value?.markets || [])
const all = computed(() => market.value?.all || null)

/* 历史 → 图表 curve（[[tsKey, value]]，时间升序；history 本就按版本升序） */
const history = computed(() => market.value?.history || [])
const curveOf = (id) => history.value
  .filter((p) => Number.isFinite(p[id]))
  .map((p) => [p.t, p[id]])
const allCurve = computed(() => curveOf('all'))
const hasChart = computed(() => allCurve.value.length >= 2)

/* 更新时刻（12 位版本 → 北京墙钟 MM-DD HH:mm） */
const updatedLabel = computed(() => {
  const v = String(market.value?.version || '')
  return v.length === 12 ? `${v.slice(4, 6)}-${v.slice(6, 8)} ${v.slice(8, 10)}:${v.slice(10, 12)}` : ''
})

/* 子市场查看：选中大市场 → 其 subs 表格（数据就绪 / 选中项消失时落到第一个） */
const activeMarket = ref('')
watch(items, (list) => {
  const ids = list.map((m) => m.id)
  if (!ids.length) return
  if (!ids.includes(activeMarket.value)) activeMarket.value = ids[0]
}, { immediate: true })
const active = computed(() => items.value.find((m) => m.id === activeMarket.value) || null)

/* 涨跌语义色（与全站一致：ok=好=涨、danger=跌；0 走 dim） */
const chgCls = (c) => (c == null ? 'dim' : c > 0 ? 'up' : c < 0 ? 'down' : 'dim')

const prediction = computed(() => market.value?.prediction || [])

onMounted(() => {
  prevTitle = document.title
  document.title = '三角洲行动 · 市场指数'
})
onBeforeUnmount(() => {
  document.title = prevTitle
})
</script>

<template>
  <div class="wrap page">
    <header class="compact-head">
      <h1>市场指数</h1>
      <p v-if="market" class="meta" :title="`数据版本 ${market.version} · 口径 ${market.anchor}`">
        全市场 {{ market.stats.priced }} 件有价 · 更新于 {{ updatedLabel }} · 指数自 {{ market.historySince ?? '—' }} 起算
      </p>
    </header>

    <!-- 口径说明（如实）：锚定昨日均价合计，与 moligod 绝对值不可比 -->
    <p class="state-tip">
      口径：篮子 = 现价与昨日均价双全的物品，<code>指数 = 1000 × Σ现价 / Σ昨日均价</code>（即昨日均价合计 = 1000）；
      曲线为本站自积累（{{ market?.history?.length ?? 0 }} 档），绝对值与其它站点不可比，方向与相对强弱可比。
    </p>

    <Transition name="swap" mode="out-in">
      <div v-if="loadState === 'loading'" key="loading" class="state-root sk-hold">
        <SkeletonView variant="hero" />
      </div>
      <div v-else-if="loadState === 'empty'" key="empty" class="state-root">
        <div class="state-card">
          <p>还没有市场指数数据。</p>
          <p class="dim">快照正在准备中，稍后再来看看。</p>
          <button class="retry" :disabled="refreshing" @click="load()">重试</button>
        </div>
      </div>
      <div v-else-if="loadState === 'error'" key="error" class="state-root">
        <div class="state-card">
          <p>市场指数加载失败：{{ loadError }}</p>
          <button class="retry" :disabled="refreshing" @click="load()">重试</button>
        </div>
      </div>
      <div v-else key="ready" class="state-root">
        <!-- 总览：大数字 + 全市场历史曲线 -->
        <section v-if="all" class="hero" aria-label="全市场指数总览">
          <div class="hero-top">
            <p class="hero-kicker"><i class="hero-diamond" aria-hidden="true"></i>全市场指数</p>
            <span class="tag">篮子 {{ all.universe }} 件</span>
          </div>
          <div class="all-row">
            <div class="all-num">
              <p class="all-level">{{ all.level?.toFixed(1) ?? '—' }}</p>
              <p class="all-chg" :class="chgCls(all.change24h)">{{ pct(all.change24h) }} <span class="all-chg-cap">24h</span></p>
            </div>
            <div class="all-chart">
              <PriceChart v-if="hasChart" :curve="allCurve" :current="all.level" />
              <p v-else class="dim chart-wait">曲线积累中（本站指数历史从上线开始记录，当前 {{ allCurve.length }} 档）——各市场卡内的迷你走势先看起来。</p>
            </div>
          </div>
        </section>

        <!-- 五大市场卡：level + 24h + 迷你曲线；点选切下方子市场表 -->
        <section class="mk-grid" aria-label="分市场指数">
          <button
            v-for="m in items" :key="m.id"
            class="mk-card" type="button"
            :class="{ on: activeMarket === m.id }"
            @click="activeMarket = m.id"
          >
            <span class="mk-head">
              <span class="mk-label">{{ m.label }}</span>
              <span class="mk-univ dim">{{ m.universe }} 件</span>
            </span>
            <span class="mk-level">{{ m.level?.toFixed(1) ?? '—' }}</span>
            <span class="mk-foot">
              <span class="mk-chg" :class="chgCls(m.change24h)">{{ pct(m.change24h) }}</span>
              <Sparkline :curve="curveOf(m.id)" :width="96" :height="26" :end-color="m.change24h > 0 ? 'var(--ok)' : 'var(--danger)'" />
            </span>
          </button>
        </section>

        <!-- 选中市场的子市场明细 -->
        <section v-if="active" class="block" aria-label="子市场指数">
          <h2 class="blk-title">{{ active.label }} · 子市场</h2>
          <div class="tbl-scroll">
            <table class="tbl">
              <thead>
                <tr>
                  <th>子市场</th>
                  <th class="num">篮子</th>
                  <th class="num">指数</th>
                  <th class="num">24h</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="s in active.subs" :key="s.id">
                  <td>{{ s.label }}</td>
                  <td class="num dim">{{ s.universe }}</td>
                  <td class="num">{{ s.level?.toFixed(1) ?? '—' }}</td>
                  <td class="num" :class="chgCls(s.change24h)">{{ pct(s.change24h) }}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="dim sub-note">子市场级历史点与主市场同批积累；上线初期曲线可能只有 1 档。</p>
        </section>

        <!-- 集市物品预测（上游口径，如实标注） -->
        <section v-if="prediction.length" class="block" aria-label="集市物品预测">
          <h2 class="blk-title">集市物品预测</h2>
          <div class="pred-grid">
            <div v-for="p in prediction" :key="p.objectId" class="pred-card">
              <img v-if="p.pic" class="pred-ic" :src="picThumb(p.pic, 96)" alt="" loading="lazy" decoding="async">
              <div class="pred-main">
                <p class="pred-name">{{ p.name }}</p>
                <p class="pred-sub dim">当前价 {{ fmt(p.current) }}</p>
              </div>
              <div class="pred-profit">
                <p class="pred-num up">+{{ fmt(p.maxSellProfit) }}</p>
                <p class="pred-cap dim">最高利润</p>
              </div>
            </div>
          </div>
          <p class="dim sub-note">预测为上游（moligod）口径透传：按其模型预估的低买高卖利润，非本站计算，不构成任何建议。</p>
        </section>
      </div>
    </Transition>
  </div>
</template>

<style scoped>
.hero { margin-bottom: var(--sp-5); }
.hero-top { display: flex; align-items: center; gap: var(--sp-3); margin-bottom: var(--sp-2); }
.hero-kicker { display: flex; align-items: center; gap: 8px; font-size: var(--fs-sm); color: var(--dim); letter-spacing: .08em; }
.hero-diamond { width: 7px; height: 7px; background: var(--accent); transform: rotate(45deg); }
.all-row { display: grid; grid-template-columns: 220px 1fr; gap: var(--sp-5); align-items: center; }
.all-level { margin: 0; font-family: var(--mono); font-size: 44px; font-weight: 700; color: var(--tx-strong); line-height: 1.1; font-variant-numeric: tabular-nums; }
.all-chg { margin: 4px 0 0; font-family: var(--mono); font-size: var(--fs-lg); font-weight: 700; }
.all-chg-cap { font-size: var(--fs-2xs); color: var(--faint); letter-spacing: .1em; }
.up { color: var(--ok); }
.down { color: var(--danger); }
.dim { color: var(--faint); }
.chart-wait { padding: var(--sp-6) var(--sp-4); border: 1px dashed var(--line); border-radius: var(--radius-lg); text-align: center; }

.mk-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: var(--sp-3); margin-bottom: var(--sp-5); }
.mk-card {
  display: flex; flex-direction: column; gap: 6px; text-align: left;
  padding: var(--sp-4); background: var(--card); border: 1px solid var(--line);
  border-radius: var(--radius-lg); cursor: pointer; color: inherit;
  transition: border-color var(--t-fast) var(--ease);
}
.mk-card:hover { border-color: var(--line-hover); }
.mk-card.on { border-color: var(--accent); }
.mk-head { display: flex; justify-content: space-between; align-items: baseline; }
.mk-label { font-size: var(--fs-md); color: var(--tx); font-weight: 600; }
.mk-univ { font-size: var(--fs-2xs); }
.mk-level { font-family: var(--mono); font-size: var(--fs-xl); font-weight: 700; color: var(--tx-strong); font-variant-numeric: tabular-nums; }
.mk-foot { display: flex; justify-content: space-between; align-items: center; gap: var(--sp-2); }
.mk-chg { font-family: var(--mono); font-size: var(--fs-sm); font-weight: 600; }

.blk-title { font-size: var(--fs-md); color: var(--tx); margin: 0 0 var(--sp-3); }
.block { margin-bottom: var(--sp-5); }
.sub-note { font-size: var(--fs-xs); margin: var(--sp-2) 0 0; }

.pred-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: var(--sp-3); }
.pred-card {
  display: flex; align-items: center; gap: var(--sp-3);
  padding: var(--sp-3) var(--sp-4); background: var(--card);
  border: 1px solid var(--line); border-radius: var(--radius-lg);
}
.pred-ic { width: 44px; height: 44px; object-fit: contain; flex: none; }
.pred-main { flex: 1; min-width: 0; }
.pred-name { margin: 0; color: var(--tx); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.pred-sub { margin: 2px 0 0; font-size: var(--fs-sm); }
.pred-profit { text-align: right; }
.pred-num { margin: 0; font-family: var(--mono); font-weight: 700; }
.pred-cap { margin: 2px 0 0; font-size: var(--fs-2xs); }

@media (max-width: 720px) {
  .all-row { grid-template-columns: 1fr; }
  .all-chart { min-width: 0; }
}
@media (prefers-reduced-motion: reduce) {
  .mk-card { transition: none; }
}
</style>
