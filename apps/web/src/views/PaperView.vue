<script setup>
/* PaperView — 子弹模拟盘（复刻自 moligod「子弹模拟盘」的本地化版本）
   moligod 的模拟盘要登录存云端；我们做纯本地：本金 / 持仓 / 成交记录全存
   localStorage（key df-paper-account-v1），价格与税率实时吃子弹行情快照
   （market.json，逐弹自带 taxRate）。成交口径（如实标注在页脚）：
     · 买入 = 现价 × 数量（现金足额扣减）
     · 卖出 = 现价 × 数量 × (1 − taxRate)（模拟挂单即时成交，无滑点无深度）
     · 浮盈按均价成本法；权益 = 现金 + Σ 持仓 × 现价
   纯练习工具：快照价非真实成交价，历史统计不代表未来。 */
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import SkeletonView from '../components/SkeletonView.vue'
import Sparkline from './ammo/Sparkline.vue'
import { useSnapshotFeed } from '../composables/useSnapshotFeed'
import { fmt, fmtSigned, pct, SIGNAL_META, gradeVar } from '../utils/format.js'

let prevTitle = ''
const INITIAL_CASH = 10_000_000
const STORE_KEY = 'df-paper-account-v1'
const TRADES_CAP = 200
const EQUITY_CAP = 720

/* ---------- 行情快照（价格 + 税率 + 信号语境） ---------- */
const {
  market, loadState, loadError, refreshing,
  load,
} = useSnapshotFeed(`${import.meta.env.BASE_URL}ammo/market.json`, {
  events: ['market'],
  syntaxError: '行情数据格式异常，请稍后重试',
  successTip: false,
})
const bullets = computed(() => market.value?.items || [])
const priceOf = (name) => bullets.value.find((b) => b.name === name)?.current ?? null
const taxOf = (name) => bullets.value.find((b) => b.name === name)?.taxRate ?? 0.15

/* ---------- 本地账户（load 一次性读入，之后全内存 + 防抖落盘） ---------- */
function freshAccount() {
  return { cash: INITIAL_CASH, positions: {}, trades: [], equity: [] }
}
function loadAccount() {
  try {
    const j = JSON.parse(localStorage.getItem(STORE_KEY))
    if (j && Number.isFinite(j.cash) && typeof j.positions === 'object') {
      return { ...freshAccount(), ...j }
    }
  } catch { /* 损坏档按新户处理 */ }
  return freshAccount()
}
const acc = ref(loadAccount())
let saveTimer = null
function persist() {
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify(acc.value))
    } catch { /* 存储满 / 隐私模式：内存态继续用，下次操作再试 */ }
  }, 300)
}
watch(acc, persist, { deep: true })

/* ---------- 成交引擎（返回错误文案或 null） ---------- */
const tip = ref('')
const tipKind = ref('ok')
let tipTimer = null
function echo(msg, kind = 'ok') {
  tip.value = msg
  tipKind.value = kind
  if (tipTimer) clearTimeout(tipTimer)
  tipTimer = setTimeout(() => { tip.value = '' }, 3200)
}

function buy(name, qty) {
  qty = Math.floor(Number(qty))
  const price = priceOf(name)
  if (!(qty > 0)) return echo('数量必须是正整数', 'warn')
  if (!(price > 0)) return echo('该弹暂无现价', 'warn')
  const cost = price * qty
  if (cost > acc.value.cash) return echo('现金不足', 'warn')
  acc.value.cash -= cost
  const pos = acc.value.positions[name] || { qty: 0, cost: 0 }
  pos.qty += qty
  pos.cost += cost
  acc.value.positions[name] = pos
  acc.value.trades.unshift({ t: Date.now(), ver: market.value?.version || '', side: 'BUY', name, qty, price, amount: cost })
  acc.value.trades.length = Math.min(acc.value.trades.length, TRADES_CAP)
  echo(`买入 ${name} ×${qty}，花费 ${fmt(cost)}`)
  recordEquity()
}
function sell(name, qty) {
  qty = Math.floor(Number(qty))
  const pos = acc.value.positions[name]
  const price = priceOf(name)
  if (!(qty > 0)) return echo('数量必须是正整数', 'warn')
  if (!pos || pos.qty <= 0) return echo('没有持仓', 'warn')
  if (qty > pos.qty) return echo(`持仓只有 ${pos.qty}`, 'warn')
  if (!(price > 0)) return echo('该弹暂无现价', 'warn')
  const tax = taxOf(name)
  const avg = pos.cost / pos.qty
  const proceeds = price * qty * (1 - tax)
  const pnl = proceeds - avg * qty
  acc.value.cash += proceeds
  pos.qty -= qty
  pos.cost -= avg * qty
  if (pos.qty <= 0) delete acc.value.positions[name]
  acc.value.trades.unshift({ t: Date.now(), ver: market.value?.version || '', side: 'SELL', name, qty, price, amount: proceeds, pnl, tax })
  acc.value.trades.length = Math.min(acc.value.trades.length, TRADES_CAP)
  echo(`卖出 ${name} ×${qty}，到手 ${fmt(proceeds)}（税 ${pct(tax)}），${fmtSigned(pnl)}`, pnl >= 0 ? 'ok' : 'warn')
  recordEquity()
}
function sellAll(name) {
  const pos = acc.value.positions[name]
  if (pos) sell(name, pos.qty)
}

/* ---------- 权益与统计 ---------- */
const positions = computed(() =>
  Object.entries(acc.value.positions).map(([name, p]) => {
    const price = priceOf(name)
    const avg = p.qty > 0 ? p.cost / p.qty : 0
    const value = Number.isFinite(price) && price > 0 ? price * p.qty : p.cost // 无价兜底按成本计（如实）
    return { name, qty: p.qty, avg, price, value, pnl: value - p.cost, pnlPct: p.cost > 0 ? (value - p.cost) / p.cost : null }
  }),
)
const positionValue = computed(() => positions.value.reduce((s, p) => s + p.value, 0))
const equity = computed(() => acc.value.cash + positionValue.value)
const totalPnl = computed(() => equity.value - INITIAL_CASH)
const totalPnlPct = computed(() => totalPnl.value / INITIAL_CASH)
const realized = computed(() => acc.value.trades.reduce((s, t) => s + (Number.isFinite(t.pnl) ? t.pnl : 0), 0))
const eqCurve = computed(() => acc.value.equity.map((p) => [p.t, p.v]).slice(-168))
function recordEquity() {
  const v = acc.value.cash + positions.value.reduce((s, p) => s + p.value, 0)
  const t = market.value?.version || String(Date.now())
  const pt = { t, v: Math.round(v) }
  const list = acc.value.equity.slice()
  const idx = list.findIndex((p) => p.t === t)
  if (idx >= 0) list[idx] = pt
  else list.push(pt)
  while (list.length > EQUITY_CAP) list.shift()
  acc.value.equity = list
}
/* 快照版本前进（轮询/SSE 刷新到新价）也记一个权益点（首次加载 market 就绪时） */
watch(market, (m) => {
  if (m) recordEquity()
})

/* ---------- 行展开交易面板（同弹药页 grid-rows 铺开口径） ---------- */
const expanded = ref(null)
const qtyInput = ref({})
const qOf = (name) => qtyInput.value[name] ?? ''
function setQ(name, v) {
  qtyInput.value = { ...qtyInput.value, [name]: v }
}
function toggle(name) {
  expanded.value = expanded.value === name ? null : name
}
function onRowKeydown(e, name) {
  if (e.target !== e.currentTarget) return
  e.preventDefault()
  toggle(name)
}

/* 排序：信号优先（BUY→SELL→WATCH→WAIT）再按现价降序，找标的动线最短 */
const ORDER = { BUY: 0, SELL: 1, WATCH: 2, WAIT: 3 }
const sortedBullets = computed(() =>
  [...bullets.value].sort((a, b) => (ORDER[a.signal] ?? 9) - (ORDER[b.signal] ?? 9) || (b.current || 0) - (a.current || 0)),
)

/* ---------- 重置（两步确认，防误触清档） ---------- */
const resetArmed = ref(false)
let resetTimer = null
function resetAccount() {
  if (!resetArmed.value) {
    resetArmed.value = true
    if (resetTimer) clearTimeout(resetTimer)
    resetTimer = setTimeout(() => { resetArmed.value = false }, 3000)
    return
  }
  acc.value = freshAccount()
  resetArmed.value = false
  echo('已重置为新账户（本金 10,000,000）')
}

const fmtTime = (t) => {
  const d = new Date(t)
  const p = (n) => String(n).padStart(2, '0')
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
}
/* 税率展示：不带符号的整数百分比（pct() 的 +15.0% 口径是给涨跌用的） */
const taxLabel = (r) => (Number.isFinite(r) ? `${Math.round(r * 100)}%` : '—')

onMounted(() => {
  prevTitle = document.title
  document.title = '三角洲行动 · 子弹模拟盘'
})
onBeforeUnmount(() => {
  document.title = prevTitle
  if (saveTimer) clearTimeout(saveTimer)
  if (tipTimer) clearTimeout(tipTimer)
  if (resetTimer) clearTimeout(resetTimer)
})
</script>

<template>
  <div class="wrap page">
    <header class="compact-head">
      <h1>子弹模拟盘</h1>
      <p class="meta">本地纸面交易 · 本金 {{ fmt(INITIAL_CASH) }} · 数据存本机（不上云、不用登录）</p>
    </header>

    <!-- 操作回声 -->
    <Transition name="swap">
      <p v-if="tip" class="state-tip" :class="{ warn: tipKind === 'warn' }" role="status">{{ tip }}</p>
    </Transition>

    <Transition name="swap" mode="out-in">
      <div v-if="loadState === 'loading'" key="loading" class="state-root sk-hold">
        <SkeletonView variant="hero" />
      </div>
      <div v-else-if="loadState === 'error'" key="error" class="state-root">
        <div class="state-card">
          <p>行情加载失败：{{ loadError }}</p>
          <button class="retry" :disabled="refreshing" @click="load()">重试</button>
        </div>
      </div>
      <div v-else key="ready" class="state-root">
        <!-- 账户总览 -->
        <section class="hero" aria-label="账户总览">
          <div class="hero-top">
            <p class="hero-kicker"><i class="hero-diamond" aria-hidden="true"></i>账户总览</p>
            <button class="reset" type="button" :class="{ armed: resetArmed }" @click="resetAccount">
              {{ resetArmed ? '再点一次确认重置' : '重置账户' }}
            </button>
          </div>
          <div class="acc-grid">
            <div class="acc-main">
              <p class="acc-label dim">总权益</p>
              <p class="acc-equity" :class="{ loss: totalPnl < 0 }">{{ fmt(equity) }}</p>
              <p class="acc-pnl" :class="totalPnl >= 0 ? 'up' : 'down'">
                {{ fmtSigned(totalPnl) }}（{{ pct(totalPnlPct) }}）
              </p>
            </div>
            <div class="acc-stats">
              <div class="acc-stat"><p class="dim acc-label">现金</p><p class="acc-v">{{ fmt(acc.cash) }}</p></div>
              <div class="acc-stat"><p class="dim acc-label">持仓市值</p><p class="acc-v">{{ fmt(positionValue) }}</p></div>
              <div class="acc-stat"><p class="dim acc-label">已实现盈亏</p><p class="acc-v" :class="realized >= 0 ? 'up' : 'down'">{{ fmtSigned(realized) }}</p></div>
              <div class="acc-stat">
                <p class="dim acc-label">权益曲线</p>
                <Sparkline :curve="eqCurve" :width="120" :height="30" :end-color="totalPnl >= 0 ? 'var(--ok)' : 'var(--danger)'" />
              </div>
            </div>
          </div>
        </section>

        <!-- 标的表：点行展开交易面板 -->
        <section class="block" aria-label="标的与交易">
          <h2 class="blk-title">标的（{{ sortedBullets.length }} 种弹药 · 点行展开交易）</h2>
          <div class="tbl-scroll">
            <table class="tbl">
              <thead>
                <tr>
                  <th>弹药</th>
                  <th class="num">品级</th>
                  <th class="num">现价</th>
                  <th class="num">税</th>
                  <th class="num">信号</th>
                  <th class="num">我的持仓</th>
                </tr>
              </thead>
              <tbody>
                <template v-for="b in sortedBullets" :key="b.name">
                  <tr class="row-click" tabindex="0" :aria-expanded="expanded === b.name" @click="toggle(b.name)" @keydown="onRowKeydown($event, b.name)">
                    <td>
                      <span class="it-cell">
                        <span class="icw" :style="{ '--gd': gradeVar(b.grade) }">
                          <img v-if="b.pic" class="ic" :src="b.pic" alt="" loading="lazy" decoding="async">
                        </span>
                        <span class="it-title">{{ b.name }}</span>
                      </span>
                    </td>
                    <td class="num"><span class="grade-dot" :style="{ color: gradeVar(b.grade) }">{{ b.grade ?? '—' }}</span></td>
                    <td class="num strong">{{ fmt(b.current) }}</td>
                    <td class="num dim">{{ taxLabel(b.taxRate) }}</td>
                    <td class="num"><span class="sig" :class="SIGNAL_META[b.signal]?.cls || 'wait'">{{ SIGNAL_META[b.signal]?.label || '观望' }}</span></td>
                    <td class="num dim">
                      <template v-if="acc.positions[b.name]">{{ acc.positions[b.name].qty.toLocaleString('zh-CN') }} 发</template>
                      <template v-else>—</template>
                    </td>
                  </tr>
                  <tr v-if="expanded === b.name" class="expander">
                    <td colspan="6">
                      <div class="exp-clip">
                        <div class="trade-panel">
                          <label class="qty-wrap">
                            数量（发）
                            <input
                              class="qty" type="number" min="1" step="1" inputmode="numeric"
                              :value="qOf(b.name)" placeholder="如 1000"
                              @input="setQ(b.name, $event.target.value)" @click.stop
                            >
                          </label>
                          <button class="t-btn buy" type="button" @click.stop="buy(b.name, qOf(b.name) || 0)">买入</button>
                          <button class="t-btn sell" type="button" @click.stop="sell(b.name, qOf(b.name) || 0)">卖出</button>
                          <button class="t-btn" type="button" @click.stop="sellAll(b.name)">清仓</button>
                          <span class="dim tp-hint">
                            买 1 发 = {{ fmt(b.current) }}；卖 1 发税后 = {{ fmt((b.current || 0) * (1 - (b.taxRate ?? 0.15))) }}
                            <template v-if="acc.positions[b.name]"> · 持仓 {{ acc.positions[b.name].qty.toLocaleString('zh-CN') }} 发 @ 均 {{ fmt(acc.positions[b.name].cost / acc.positions[b.name].qty) }}</template>
                          </span>
                        </div>
                      </div>
                    </td>
                  </tr>
                </template>
              </tbody>
            </table>
          </div>
        </section>

        <!-- 持仓明细 -->
        <section v-if="positions.length" class="block" aria-label="持仓明细">
          <h2 class="blk-title">持仓（{{ positions.length }}）</h2>
          <div class="tbl-scroll">
            <table class="tbl">
              <thead>
                <tr>
                  <th>弹药</th>
                  <th class="num">数量</th>
                  <th class="num">均价成本</th>
                  <th class="num">现价</th>
                  <th class="num">市值</th>
                  <th class="num">浮盈</th>
                  <th class="num">浮盈率</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="p in positions" :key="p.name">
                  <td>{{ p.name }}</td>
                  <td class="num">{{ p.qty.toLocaleString('zh-CN') }}</td>
                  <td class="num dim">{{ fmt(p.avg) }}</td>
                  <td class="num">{{ fmt(p.price) }}</td>
                  <td class="num strong">{{ fmt(p.value) }}</td>
                  <td class="num" :class="p.pnl >= 0 ? 'up' : 'down'">{{ fmtSigned(p.pnl) }}</td>
                  <td class="num" :class="p.pnl >= 0 ? 'up' : 'down'">{{ pct(p.pnlPct) }}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <!-- 成交记录 -->
        <section v-if="acc.trades.length" class="block" aria-label="成交记录">
          <h2 class="blk-title">成交记录（最近 {{ acc.trades.length }} 笔）</h2>
          <div class="tbl-scroll">
            <table class="tbl">
              <thead>
                <tr>
                  <th>时间</th>
                  <th>方向</th>
                  <th>弹药</th>
                  <th class="num">数量</th>
                  <th class="num">价格</th>
                  <th class="num">金额</th>
                  <th class="num">盈亏</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="(t, i) in acc.trades" :key="t.t + '-' + i">
                  <td class="dim">{{ fmtTime(t.t) }}</td>
                  <td><span class="sig" :class="t.side === 'BUY' ? 'buy' : 'sell'">{{ t.side === 'BUY' ? '买入' : '卖出' }}</span></td>
                  <td>{{ t.name }}</td>
                  <td class="num">{{ t.qty.toLocaleString('zh-CN') }}</td>
                  <td class="num dim">{{ fmt(t.price) }}</td>
                  <td class="num">{{ fmt(t.amount) }}</td>
                  <td class="num" :class="t.pnl >= 0 ? 'up' : t.pnl < 0 ? 'down' : 'dim'">{{ Number.isFinite(t.pnl) ? fmtSigned(t.pnl) : '—' }}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <p class="dim foot-note">
          模拟成交基于行情快照现价：买入按现价全额、卖出按现价 × (1 − 税率)，无滑点、无挂单深度；
          快照本身分钟级滞后。纯练习工具，历史统计不代表未来，不构成任何建议。
        </p>
      </div>
    </Transition>
  </div>
</template>

<style scoped>
.hero { margin-bottom: var(--sp-5); }
.hero-top { display: flex; align-items: center; justify-content: space-between; gap: var(--sp-3); margin-bottom: var(--sp-2); }
.hero-kicker { display: flex; align-items: center; gap: 8px; font-size: var(--fs-sm); color: var(--dim); letter-spacing: .08em; margin: 0; }
.hero-diamond { width: 7px; height: 7px; background: var(--accent); transform: rotate(45deg); }
.acc-grid { display: grid; grid-template-columns: 240px 1fr; gap: var(--sp-5); align-items: center; }
.acc-label { margin: 0 0 4px; font-size: var(--fs-xs); letter-spacing: .08em; }
.acc-equity { margin: 0; font-family: var(--mono); font-size: 38px; font-weight: 700; color: var(--tx-strong); line-height: 1.15; font-variant-numeric: tabular-nums; }
.acc-pnl { margin: 4px 0 0; font-family: var(--mono); font-size: var(--fs-md); font-weight: 600; }
.acc-stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: var(--sp-4); }
.acc-v { margin: 0; font-family: var(--mono); font-size: var(--fs-lg); color: var(--tx); font-variant-numeric: tabular-nums; }
.up { color: var(--ok); }
.down { color: var(--danger); }
.dim { color: var(--faint); }
.loss { color: var(--danger); }
.reset {
  padding: 6px 12px; background: none; border: 1px solid var(--line); border-radius: var(--radius);
  color: var(--dim); font-size: var(--fs-xs); cursor: pointer;
}
.reset:hover { color: var(--tx); border-color: var(--line-hover); }
.reset.armed { color: var(--danger); border-color: var(--danger); }

.block { margin-bottom: var(--sp-5); }
.blk-title { font-size: var(--fs-md); color: var(--tx); margin: 0 0 var(--sp-3); }
.row-click { cursor: pointer; }
.row-click:hover .it-title { color: var(--tx-strong); }

/* 展开交易面板：grid-rows 0fr→1fr 铺开（motion.css .exp-clip 同族口径） */
.expander td { padding: 0; border-top: 0; }
.exp-clip { display: grid; grid-template-rows: 0fr; }
tr.expander .exp-clip { grid-template-rows: 1fr; transition: grid-template-rows var(--t-panel) var(--ease); }
.trade-panel {
  overflow: hidden; display: flex; align-items: center; gap: var(--sp-3); flex-wrap: wrap;
  padding: var(--sp-3) var(--sp-4); margin: 0 0 var(--sp-2);
  background: var(--bg2); border: 1px solid var(--line); border-radius: var(--radius);
}
.qty-wrap { display: inline-flex; align-items: center; gap: 8px; color: var(--dim); font-size: var(--fs-sm); }
.qty {
  width: 120px; padding: 7px 10px; background: var(--card); border: 1px solid var(--line);
  border-radius: var(--radius); color: var(--tx); font-size: var(--fs-sm); font-family: var(--mono);
}
.t-btn {
  padding: 7px 14px; min-height: 36px; background: var(--card); border: 1px solid var(--line);
  border-radius: var(--radius); color: var(--tx); font-size: var(--fs-sm); cursor: pointer;
}
.t-btn:hover { border-color: var(--line-hover); }
.t-btn:active { transform: translateY(1px); }
.t-btn.buy { color: var(--ok); border-color: color-mix(in srgb, var(--ok) 40%, var(--line)); }
.t-btn.sell { color: var(--danger); border-color: color-mix(in srgb, var(--danger) 40%, var(--line)); }
.tp-hint { font-size: var(--fs-xs); }

.it-cell { display: flex; align-items: center; gap: 10px; min-width: 0; }
.icw {
  flex: none; width: 36px; height: 36px; border-radius: var(--radius-sm);
  background: var(--bg2); border: 1px solid color-mix(in srgb, var(--gd, var(--line)) 35%, transparent);
  display: inline-flex; align-items: center; justify-content: center;
}
.ic { max-width: 28px; max-height: 28px; }
.it-title { color: var(--tx); }
.strong { color: var(--tx-strong); font-weight: 600; }
.grade-dot { font-family: var(--mono); font-weight: 700; }
.sig { font-size: var(--fs-xs); padding: 2px 8px; border-radius: 999px; border: 1px solid var(--line); }
.sig.buy { color: var(--ok); border-color: color-mix(in srgb, var(--ok) 40%, var(--line)); }
.sig.sell { color: var(--danger); border-color: color-mix(in srgb, var(--danger) 40%, var(--line)); }
.sig.watch { color: var(--info); border-color: color-mix(in srgb, var(--info) 40%, var(--line)); }
.sig.wait { color: var(--faint); }
.state-tip.warn { color: var(--danger); }
.foot-note { font-size: var(--fs-xs); margin: var(--sp-3) 0 0; }

@media (max-width: 720px) {
  .acc-grid { grid-template-columns: 1fr; }
}
@media (prefers-reduced-motion: reduce) {
  tr.expander .exp-clip { transition: none; }
  .t-btn, .reset { transition: none; }
}
</style>
