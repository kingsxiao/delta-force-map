<script setup>
/* ============================================================
   AmmoMarketView — 子弹行情 · 实时监控（/ammo）
   ------------------------------------------------------------
   数据源：public/ammo/market.json（由 scripts/ammo/fetch-once.mjs 生成，
   来自 KK三角洲一图流 kkrb.net 的交易行子弹盈亏接口，约每小时更新）。
   本页为静态快照展示；后台跑 `npm run ammo:monitor` 时，出现买入/卖出
   信号会弹 macOS 系统通知（哪种子弹 / 什么价买 / 挂多少钱卖 / 预赚多少）。
   口径与 scripts/ammo/analyze.mjs 一致：7 天小时级曲线分位数回归，
   P25 以下买入、P75 以上卖出，利润为税后到手价减买入价。
   ============================================================ */
import { computed, nextTick, onMounted, onUnmounted, reactive, ref } from 'vue'
import { useReveal } from '../composables/useReveal'
import SignalCard from './ammo/SignalCard.vue'
import Sparkline from './ammo/Sparkline.vue'
import PriceChart from './ammo/PriceChart.vue'

const { observeRoot } = useReveal()

/* ---------- 数据加载（silent 静默刷新：不整页 loading，失败保留旧数据） ---------- */
const pageRef = ref(null)
const ctlRef = ref(null)
const tblRef = ref(null)
const allSecRef = ref(null)
const market = ref(null)
const loadState = ref('loading') // loading | ready | empty | error
const loadError = ref('')
const refreshing = ref(false)
const refreshTip = ref('')
const refreshTipKind = ref('ok')

let tipTimer = null
let pollTimer = null
let clockTimer = null
let ctlRO = null

async function load(opts = {}) {
  const silent = !!(opts.silent && market.value)
  if (silent) refreshing.value = true
  else loadState.value = 'loading'
  try {
    const res = await fetch(`${import.meta.env.BASE_URL}ammo/market.json?t=${Date.now()}`)
    if (res.status === 404) {
      if (silent) throw new Error('快照不存在（HTTP 404）')
      loadState.value = 'empty'
      return
    }
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = await res.json()
    if (!json || !Array.isArray(json.items)) throw new Error('数据格式异常')
    market.value = json
    loadState.value = 'ready'
    if (silent) {
      refreshTip.value = `已更新至 ${versionLabel.value}`
      refreshTipKind.value = 'ok'
      if (tipTimer) clearTimeout(tipTimer)
      tipTimer = setTimeout(() => { refreshTip.value = '' }, 4000)
    }
    await nextTick()
    observeRoot(pageRef.value)
    syncTblFade()
    mountCtlRO()
  } catch (e) {
    if (silent) {
      // 静默失败：保留旧数据，只在控制条下给一行提示，不整页报错
      refreshTip.value = '刷新失败，仍显示之前的数据'
      refreshTipKind.value = 'warn'
    } else {
      loadError.value = e instanceof SyntaxError
        ? '行情数据格式异常（public/ammo/market.json 可能未部署或被回退到页面）'
        : e.message
      loadState.value = 'error'
    }
  } finally {
    refreshing.value = false
  }
}

/* 吸顶控制条高度 → --ctl-h（写在 .page 根上供 .tbl-scroll 继承）。
   ResizeObserver 只建一次；observe 对同一元素幂等，静默轮询反复进成功路径不重建。 */
function mountCtlRO() {
  if (!ctlRef.value) return
  if (!ctlRO) {
    ctlRO = new ResizeObserver(() => {
      const h = ctlRef.value?.offsetHeight
      if (h && pageRef.value) pageRef.value.style.setProperty('--ctl-h', `${h}px`)
    })
  }
  ctlRO.observe(ctlRef.value)
}

/* 横滑渐隐提示：仅容器真溢出（can-scroll）且未滑到底（!at-end）时显示 */
const tblCanScroll = ref(false)
const tblAtEnd = ref(false)
function syncTblFade() {
  const el = tblRef.value
  if (!el) return
  tblCanScroll.value = el.scrollWidth > el.clientWidth + 2
  tblAtEnd.value = el.scrollLeft + el.clientWidth >= el.scrollWidth - 2
}

/* ---------- 数据时效（fetchedAt 距今分钟数；分钟钟每 60s 走一格，长开页面状态也诚实） ---------- */
const nowTs = ref(Date.now())
const ageMin = computed(() => {
  const t = Date.parse(market.value?.fetchedAt)
  return Number.isFinite(t) ? (nowTs.value - t) / 60000 : null
})
const ageLabel = computed(() => {
  if (ageMin.value == null) return ''
  return ageMin.value < 60
    ? `${Math.round(ageMin.value)} 分钟前`
    : `${Math.round(ageMin.value / 60)} 小时前`
})

/* 数据版本号 "2026101310" → "2026-10-13 10:00" */
const versionLabel = computed(() => {
  const v = market.value?.version
  if (!v) return '—'
  return `${v.slice(0, 4)}-${v.slice(4, 6)}-${v.slice(6, 8)} ${v.slice(8, 10)}:00`
})

/* ---------- 展示工具 ---------- */
const fmt = (n) => (Number.isFinite(n) ? Math.round(n).toLocaleString('zh-CN') : '—')
const pct = (n) => (Number.isFinite(n) ? `${n >= 0 ? '+' : ''}${(n * 100).toFixed(1)}%` : '—')
const SIGNAL_META = {
  BUY: { label: '买入', cls: 'buy' },
  WATCH: { label: '关注', cls: 'watch' },
  SELL: { label: '卖出', cls: 'sell' },
  WAIT: { label: '观望', cls: 'wait' },
}
const gradeVar = (g) => (g >= 2 && g <= 6 ? `var(--lv${g})` : 'var(--faint)')
const reduceMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches

/* ---------- 自选星标（localStorage，key=ammo-stars，存弹名数组） ---------- */
const STARS_KEY = 'ammo-stars'
function loadStars() {
  try {
    const raw = JSON.parse(localStorage.getItem(STARS_KEY))
    return new Set(Array.isArray(raw) ? raw.filter((n) => typeof n === 'string') : [])
  } catch {
    return new Set()
  }
}
const stars = ref(loadStars())
function toggleStar(name) {
  const next = new Set(stars.value)
  if (next.has(name)) next.delete(name)
  else next.add(name)
  stars.value = next
  try {
    localStorage.setItem(STARS_KEY, JSON.stringify([...next]))
  } catch {
    /* 隐私模式等写入失败时仅本次会话生效 */
  }
}

/* ---------- 筛选与排序 ---------- */
const SIGNALS = [
  { v: 'all', label: '全部' },
  { v: 'BUY', label: '买入', dot: 'var(--ok, #34d399)' },
  { v: 'WATCH', label: '关注', dot: 'var(--info, #60a5fa)' },
  { v: 'SELL', label: '卖出', dot: 'var(--danger, #f87171)' },
  { v: 'WAIT', label: '观望', dot: 'var(--faint)' },
  { v: 'star', label: '★ 自选' },
]
const SORTS = [
  { v: 'signal', label: '信号优先' },
  { v: 'profit', label: '预期利润' },
  { v: 'rank', label: '价格分位' },
  { v: 'price', label: '当前价格' },
  { v: 'pct', label: '收益率' },
]
/* 各排序键的默认方向；signal 为复合排序不参与方向切换 */
const SORT_DIR = { profit: 'desc', rank: 'asc', price: 'desc', pct: 'desc', signal: null }
const state = reactive({ signal: 'all', grade: 0, q: '', sort: 'signal', dir: null })

/* 品级选项按数据实际出现的品级生成（实测仅 3/4/5，写死 2/6 是永空死选项） */
const gradeOptions = computed(() => [
  { v: 0, label: '全部品级' },
  ...[...new Set(items.value.map((i) => i.grade))]
    .sort((a, b) => a - b)
    .map((g) => ({ v: g, label: String(g), dot: gradeVar(g) })),
])

function onSort(v) {
  if (v !== state.sort) {
    state.sort = v
    state.dir = SORT_DIR[v]
  } else if (SORT_DIR[v]) {
    state.dir = state.dir === 'asc' ? 'desc' : 'asc'
  }
}

function clearFilters() {
  state.signal = 'all'
  state.grade = 0
  state.q = ''
}

const SIGNAL_ORDER = { BUY: 0, SELL: 1, WATCH: 2, WAIT: 3 }
const items = computed(() => market.value?.items || [])
const filtered = computed(() => {
  let list = items.value
  if (state.signal === 'star') list = list.filter((i) => stars.value.has(i.name))
  else if (state.signal !== 'all') list = list.filter((i) => i.signal === state.signal)
  if (state.grade) list = list.filter((i) => i.grade === state.grade)
  if (state.q.trim()) {
    const q = state.q.trim().toLowerCase()
    list = list.filter((i) => i.name.toLowerCase().includes(q))
  }
  const num = (x) => (Number.isFinite(x) ? x : -Infinity)
  // sorters 统一「降序取向」，方向由 state.dir 的乘子在最后统一翻转
  const sorters = {
    signal: (a, b) =>
      SIGNAL_ORDER[a.signal] - SIGNAL_ORDER[b.signal] || num(b.profitPct) - num(a.profitPct),
    profit: (a, b) => num(b.profitPerRound) - num(a.profitPerRound),
    rank: (a, b) => num(b.rank) - num(a.rank),
    price: (a, b) => num(b.current) - num(a.current),
    pct: (a, b) => num(b.profitPct) - num(a.profitPct),
  }
  const pin = (a, b) => Number(stars.value.has(b.name)) - Number(stars.value.has(a.name))
  const base = sorters[state.sort]
  const m = state.dir === 'asc' ? -1 : 1
  const hasDir = !!SORT_DIR[state.sort]
  return [...list].sort((a, b) => pin(a, b) || (hasDir ? m * base(a, b) : base(a, b)))
})

/* ---------- 行展开 ---------- */
const expanded = ref(null)
const toggle = (name) => {
  expanded.value = expanded.value === name ? null : name
  if (expanded.value) scrollToExpander('nearest')
}
const scrollToExpander = (block) => {
  nextTick(() => {
    document.querySelector('tr.expander')?.scrollIntoView({
      block,
      behavior: reduceMotion() ? 'auto' : 'smooth',
    })
  })
}
/* 键盘开关行：事件源不是 tr 本身（如行内星标按钮）时不拦截，星标仍可键盘触发 */
function onRowKeydown(e, name) {
  if (e.target !== e.currentTarget) return
  e.preventDefault()
  toggle(name)
}
const onGlobalKeydown = (e) => { if (e.key === 'Escape') expanded.value = null }

/* ---------- 卖出胶囊 → 全表联动 ---------- */
function openFromSell(i) {
  state.signal = 'all'
  state.grade = 0
  state.q = i.name
  expanded.value = i.name
  scrollToExpander('center')
}
function showAllSell() {
  state.signal = 'SELL'
  nextTick(() => {
    allSecRef.value?.scrollIntoView({ block: 'start', behavior: reduceMotion() ? 'auto' : 'smooth' })
  })
}

const buyList = computed(() => items.value.filter((i) => i.signal === 'BUY').sort((a, b) => b.profitPct - a.profitPct))
const sellList = computed(() => items.value.filter((i) => i.signal === 'SELL').sort((a, b) => b.rank - a.rank))

/* ---------- 生命周期：静默轮询 + 分钟钟 + 全局监听（统一在此挂/卸） ---------- */
onMounted(() => {
  load()
  // 页面可见且已有数据时每 30 分钟静默拉一次，不整页 loading
  pollTimer = setInterval(() => {
    if (document.visibilityState === 'visible' && market.value) load({ silent: true })
  }, 30 * 60 * 1000)
  clockTimer = setInterval(() => { nowTs.value = Date.now() }, 60 * 1000)
  window.addEventListener('resize', syncTblFade)
  window.addEventListener('keydown', onGlobalKeydown)
})
onUnmounted(() => {
  clearInterval(pollTimer)
  clearInterval(clockTimer)
  if (tipTimer) clearTimeout(tipTimer)
  if (ctlRO) ctlRO.disconnect()
  window.removeEventListener('resize', syncTblFade)
  window.removeEventListener('keydown', onGlobalKeydown)
})
</script>

<template>
  <div ref="pageRef" class="wrap page">
    <!-- 页头 -->
    <header class="page-head">
      <p class="kicker">AMMO MARKET / 交易行 · 子弹行情</p>
      <h1>子弹价格监控 <span class="live-dot" :class="{ stale: ageMin !== null && ageMin > 60 }" aria-hidden="true"></span></h1>
      <p class="lede">
        88 种交易行子弹的实时价格与买卖建议：贴近 7 天低位、税后仍有利润空间的弹种给出
        <b>买入信号</b>；贴近 7 天高位给出<b>卖出信号</b>。每发预赚多少已按交易税折算。
      </p>
      <p class="meta">
        数据版本 {{ versionLabel }} · 来源 KK三角洲一图流（约每小时更新）·
        本机后台监控 <code>npm run ammo:monitor</code> 触达系统通知<span v-if="ageLabel"> ·
        更新于 <span :class="{ 'meta-stale': ageMin > 120 }">{{ ageLabel }}</span></span>
      </p>
    </header>

    <!-- 数据过期提醒（>6 小时） -->
    <p v-if="ageMin !== null && ageMin > 360" class="state-tip stale-tip" role="status">
      数据已 {{ Math.round(ageMin / 60) }} 小时未更新，价格可能已变化，可点『刷新数据』重试
    </p>

    <!-- 加载 / 空态 -->
    <p v-if="loadState === 'loading'" class="state-tip">正在加载行情…</p>
    <div v-else-if="loadState === 'empty'" class="state-card">
      <p>还没有行情数据。先运行一次抓取脚本生成快照：</p>
      <pre><code>npm run ammo:fetch</code></pre>
      <p class="dim">之后用 <code>npm run ammo:monitor</code> 挂后台监控，出现买入信号会弹系统通知。</p>
    </div>
    <div v-else-if="loadState === 'error'" class="state-card">
      <p>行情加载失败：{{ loadError }}</p>
      <button class="retry" @click="load()">重试</button>
    </div>

    <template v-if="loadState === 'ready'">
      <!-- 买入信号 -->
      <section v-if="buyList.length" class="block reveal">
        <div class="block-h">
          <span class="bht">BUY SIGNALS</span><span class="bhline"></span>
          <span class="bhc">{{ buyList.length }} 种 · 按预期收益率排序</span>
        </div>
        <div class="sig-grid">
          <SignalCard v-for="i in buyList.slice(0, 6)" :key="i.name" :item="i" kind="buy" />
        </div>
        <p v-if="buyList.length > 6" class="more-tip">其余 {{ buyList.length - 6 }} 种买入信号见下方全表（筛选「买入」）。</p>
      </section>
      <p v-else class="state-tip">
        当前没有触发买入条件的弹种（7 天低位 + 税后利润 ≥ 8%）。低位「关注」中的弹种见全表。
      </p>

      <!-- 卖出信号（简表，点击直达全表走势） -->
      <section v-if="sellList.length" class="block reveal">
        <div class="block-h">
          <span class="bht">SELL SIGNALS</span><span class="bhline"></span>
          <span class="bhc">{{ sellList.length }} 种贴近 7 天高位</span>
        </div>
        <div class="sell-strip">
          <button
            v-for="i in sellList.slice(0, 8)" :key="i.name" class="sell-chip"
            :aria-label="`${i.name}，查看 7 天走势`" @click="openFromSell(i)"
          >
            <i class="sc-i" :style="{ background: gradeVar(i.grade) }"></i>{{ i.name }}
            <b>{{ fmt(i.current) }}</b>
            <small>{{ Math.round(i.rank * 100) }}%</small>
          </button>
          <button
            v-if="sellList.length > 8" class="sell-chip more"
            aria-label="筛选全部卖出信号" @click="showAllSell"
          >+{{ sellList.length - 8 }}</button>
        </div>
      </section>

      <!-- 全量表（控制条吸顶，表容器联动粘其下方，表头 sticky） -->
      <section ref="allSecRef" class="block reveal">
        <div class="block-h">
          <span class="bht">ALL AMMO</span><span class="bhline"></span>
          <span class="bhc">{{ filtered.length }} / {{ items.length }} 种</span>
        </div>

        <!-- .tbl-zone：sticky 包含块贯穿到页尾——表容器在其中的滑动余量 = METHOD 区高度，
             页滚时表格锁定在吸顶条正下方，直到 METHOD 滚入才自然释放 -->
        <div class="tbl-zone">
          <div ref="ctlRef" class="sticky-bar ctl-sticky">
            <div class="ctl-bar">
              <div class="chips" role="group" aria-label="信号筛选">
                <button
                  v-for="s in SIGNALS" :key="s.v"
                  class="chip" :class="{ on: state.signal === s.v }"
                  :aria-pressed="state.signal === s.v"
                  @click="state.signal = s.v"
                >
                  <i v-if="s.dot" class="chip-dot" :style="{ background: s.dot }"></i>{{ s.label }}
                </button>
              </div>
              <div class="chips" role="group" aria-label="品级筛选">
                <button
                  v-for="g in gradeOptions" :key="g.v"
                  class="chip" :class="{ on: state.grade === g.v }"
                  :aria-pressed="state.grade === g.v"
                  @click="state.grade = g.v"
                >
                  <i v-if="g.dot" class="chip-dot" :style="{ background: g.dot }"></i>{{ g.label }}
                </button>
              </div>
              <input v-model.trim="state.q" class="search" type="search" placeholder="搜索弹种，如 5.56 / M995" aria-label="搜索弹种" />
              <div class="chips" role="group" aria-label="排序">
                <button
                  v-for="s in SORTS" :key="s.v"
                  class="chip" :class="{ on: state.sort === s.v }"
                  :aria-pressed="state.sort === s.v"
                  @click="onSort(s.v)"
                >{{ s.label }}<i v-if="state.sort === s.v && state.dir" class="dir">{{ state.dir === 'desc' ? '↓' : '↑' }}</i></button>
              </div>
              <button
                class="chip refresh" title="重新拉取最新快照"
                :disabled="refreshing" @click="load({ silent: true })"
              >{{ refreshing ? '刷新中…' : '刷新数据' }}</button>
            </div>
            <p v-if="refreshTip" class="refresh-tip" :class="refreshTipKind" role="status">{{ refreshTip }}</p>
          </div>

          <div
            ref="tblRef" class="tbl-scroll"
            :class="{ 'can-scroll': tblCanScroll, 'at-end': tblAtEnd }"
            @scroll="syncTblFade"
          >
            <table class="tbl">
              <thead>
                <tr>
                  <th>弹种</th>
                  <th class="num">当前价</th>
                  <th>信号</th>
                  <th class="num">税后预赚·发</th>
                  <th class="num">7天分位</th>
                  <th class="num c-range">7天区间</th>
                  <th>走势（7天）</th>
                </tr>
              </thead>
              <tbody>
                <template v-for="i in filtered" :key="i.name">
                  <tr
                    class="row" :class="{ open: expanded === i.name }"
                    tabindex="0"
                    :aria-expanded="expanded === i.name"
                    :aria-label="`${i.name}，展开 7 天价格大图`"
                    @click="toggle(i.name)"
                    @keydown.enter="onRowKeydown($event, i.name)"
                    @keydown.space="onRowKeydown($event, i.name)"
                  >
                    <td>
                      <button
                        class="star" :class="{ on: stars.has(i.name) }"
                        :aria-pressed="stars.has(i.name)"
                        :title="stars.has(i.name) ? '取消自选' : '加入自选'"
                        @click.stop="toggleStar(i.name)"
                      >★</button>
                      <span class="g-dot" :style="{ background: gradeVar(i.grade) }" aria-hidden="true"></span>
                      <span class="a-name">{{ i.name }}</span>
                      <i class="row-chev" aria-hidden="true">▾</i>
                    </td>
                    <td class="mono strong num">{{ fmt(i.current) }}</td>
                    <td>
                      <span v-if="i.rank == null" class="sig wait">数据不足</span>
                      <span v-else class="sig" :class="SIGNAL_META[i.signal].cls">{{ SIGNAL_META[i.signal].label }}</span>
                    </td>
                    <td class="mono num" :class="{ profit: i.profitPerRound > 0 }">
                      {{ i.profitPerRound > 0 ? `+${fmt(i.profitPerRound)}（${pct(i.profitPct)}）` : '—' }}
                    </td>
                    <td class="num">
                      <div class="rank-cell">
                        <span
                          class="rb-num"
                          :class="{ low: i.rank != null && i.rank <= 0.35, high: i.rank != null && i.rank >= 0.8 }"
                        >{{ i.rank == null ? '—' : `${Math.round(i.rank * 100)}%` }}</span>
                        <div v-if="i.rank != null" class="rank-bar">
                          <i
                            :style="{ width: `${Math.round(i.rank * 100)}%` }"
                            :class="{ low: i.rank <= 0.35, high: i.rank >= 0.8 }"
                          ></i>
                        </div>
                      </div>
                    </td>
                    <td class="mono dimtx num c-range">{{ fmt(i.weekLow) }} ~ {{ fmt(i.weekHigh) }}</td>
                    <td><Sparkline :curve="i.curve" :width="130" :height="30" /></td>
                  </tr>
                  <tr v-if="expanded === i.name" class="expander">
                    <td colspan="7">
                      <button class="exp-close" @click="expanded = null">收起</button>
                      <PriceChart :curve="i.curve" :p25="i.p25" :p75="i.p75" :current="i.current" />
                      <p class="exp-note">
                        口径：买入参考 {{ fmt(i.p25) }}（P25）/ 目标挂卖 {{ fmt(i.targetSell) }}（P75，税后到手 {{ fmt(i.netSell) }}）/
                        税率 {{ (i.taxRate * 100).toFixed(0) }}%。价格回到 P75 即可挂卖；急用钱可按现价直接出。
                      </p>
                    </td>
                  </tr>
                </template>
                <tr v-if="!filtered.length">
                  <td colspan="7" class="empty-cell">
                    没有符合当前筛选的弹种　<button class="empty-clear" @click="clearFilters">清除全部筛选</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <!-- 方法与免责（留在 .tbl-zone 内：为表容器 sticky 提供包含块余量） -->
          <section class="block reveal">
            <div class="block-h"><span class="bht">METHOD</span><span class="bhline"></span></div>
            <ul class="method">
              <li><b>买入条件</b>：当前价处近 7 天价格曲线 ≤ 25% 分位，且按 P75 挂卖、扣除交易税后收益率 ≥ 8%。</li>
              <li><b>卖出条件</b>：当前价处 ≥ 80% 分位（贴近 7 天高位）。</li>
              <li><b>能赚多少</b>：每发利润 = 目标挂卖价 × (1−税率) − 当前买入价；税率按上游税后价实测反推（约 15%，逐弹计算）。</li>
              <li><b>数据</b>：KK三角洲一图流（kkrb.net）交易行口径，约每小时更新一次；趋势为近 7 天每小时均价。</li>
              <li><b>提醒</b>：交易行价格受版本、活动与大盘供需影响，历史分位不代表未来走势；利润测算未计挂单时间成本。</li>
            </ul>
          </section>
        </div>
      </section>
    </template>
  </div>
</template>

<style scoped>
.page { padding-bottom: var(--sp-10); }

/* ---------- 页头（padding 走 base.css .page-head 公共规则 64/32，此处只留底缘线） ---------- */
.page-head { border-bottom: 1px solid var(--line2); }

.live-dot {
  display: inline-block; width: 10px; height: 10px; border-radius: 50%;
  background: var(--ok, #34d399); margin-left: 10px;
  box-shadow: 0 0 8px var(--ok, #34d399);
  animation: pulse 2.2s ease-in-out infinite;
}
/* 数据超 1 小时未更新：停止脉冲变灰，live 承诺降级 */
.live-dot.stale { background: var(--faint); box-shadow: none; animation: none; }
@keyframes pulse { 50% { opacity: .35; } }
@media (prefers-reduced-motion: reduce) { .live-dot { animation: none; } }
.meta-stale { color: var(--warn); }

.state-tip { color: var(--dim); font-size: var(--fs-md); padding: var(--sp-6) 0; }
.stale-tip { color: var(--warn); }
.state-card {
  background: var(--card); border: 1px dashed var(--line2); border-radius: var(--radius);
  padding: var(--sp-6); color: var(--tx); margin: var(--sp-4) 0;
}
.state-card pre { background: var(--deep); padding: 10px 14px; border-radius: var(--radius-sm); overflow: auto; }
.state-card .dim { color: var(--faint); font-size: var(--fs-sm); }
.state-card code { font-family: var(--mono); color: var(--accent); }
.retry,
.empty-clear {
  background: var(--accent-soft); color: var(--accent); border: 1px solid var(--accent-dim);
  border-radius: var(--radius-pill); padding: 6px 18px; cursor: pointer; font-size: var(--fs-sm);
}
.empty-cell { text-align: center; color: var(--dim); padding: var(--sp-6) 0; }

.sig-grid {
  display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: var(--sp-4);
}
.more-tip { color: var(--faint); font-size: var(--fs-xs); margin-top: var(--sp-3); }

/* ---------- 卖出胶囊（button 化，可点直达全表；移动端单行横滑） ---------- */
.sell-strip { display: flex; flex-wrap: wrap; gap: 8px; }
.sell-chip {
  display: inline-flex; align-items: center; gap: 7px;
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  padding: 5px 12px; font-size: var(--fs-xs); color: var(--tx); cursor: pointer;
  white-space: nowrap;
}
.sell-chip:hover { border-color: var(--line-hover); }
.sell-chip i.sc-i { width: 6px; height: 6px; transform: rotate(45deg); }
.sell-chip b { font-family: var(--mono); color: var(--tx-strong); font-weight: 600; }
.sell-chip small { font-family: var(--mono); color: var(--dim); }
.sell-chip.more { color: var(--faint); }
@media (max-width: 680px) {
  .sell-strip { flex-wrap: nowrap; overflow-x: auto; padding-bottom: 4px; }
}

/* ---------- 吸顶控制条（复用 base.css .sticky-bar，高度经 RO 写入 --ctl-h 联动表容器） ---------- */
.ctl-sticky { padding: var(--sp-2) 0; margin-bottom: var(--sp-4); }
.ctl-bar {
  display: flex; flex-wrap: wrap; align-items: center; gap: var(--sp-4);
}
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chip {
  display: inline-flex; align-items: center; gap: 6px;
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  color: var(--dim); font-size: var(--fs-xs); padding: 4px 12px; cursor: pointer;
  transition: color var(--t-fast), border-color var(--t-fast);
}
.chip:hover { color: var(--tx); border-color: var(--line-hover); }
.chip.on { color: var(--accent); border-color: var(--accent-dim); background: var(--accent-soft); }
.chip-dot { width: 6px; height: 6px; border-radius: 50%; }
.chip.refresh { margin-left: auto; }
.chip.refresh:disabled { opacity: .6; cursor: default; }
.dir { font-style: normal; margin-left: 2px; color: var(--accent); }
.refresh-tip { font-family: var(--mono); font-size: var(--fs-xs); margin-top: 6px; }
.refresh-tip.ok { color: var(--dim); }
.refresh-tip.warn { color: var(--warn); }
.search {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  color: var(--tx); font-size: var(--fs-xs); padding: 5px 14px; width: 180px;
}
.search:focus { outline: none; border-color: var(--accent-dim); }

/* ---------- 全表：容器粘在吸顶条正下方（.tbl-zone 为包含块并贯穿到 METHOD 之后，
   页滚时表格锁定，直到 METHOD 滚入视口才随包含块自然释放） ---------- */
.tbl-scroll {
  position: sticky;
  top: var(--ctl-h, 72px);
  max-height: max(50vh, calc(100vh - var(--ctl-h, 72px) - 96px));
  overflow: auto;
  border: 1px solid var(--line);
  border-radius: var(--radius);
}
/* WebKit（Safari/iOS）下 border-collapse:collapse 会让 th sticky 失效，改 separate；
   本表只用 td 底边框，separate 下无双子线问题 */
.tbl-scroll .tbl { border-collapse: separate; border-spacing: 0; }
.tbl-scroll .tbl th {
  position: sticky; top: 0; z-index: 1;
  background: var(--card2);
  border-bottom: 0;
  box-shadow: 0 1px 0 var(--line);
}
/* 右缘渐隐：仅容器真溢出且未滑到底时出现（桌面无溢出永不显示） */
.tbl-scroll::after {
  content: '';
  position: absolute; top: 0; right: 0; bottom: 0;
  width: 36px;
  background: linear-gradient(to right, transparent, var(--bg));
  pointer-events: none;
  opacity: 0;
  transition: opacity var(--t-med);
}
.tbl-scroll.can-scroll:not(.at-end)::after { opacity: 1; }

/* 移动端：控制条全量换行高达 280px+，吸顶会占视口 1/3——取消吸顶还原为常规块
   （去掉 sticky-bar 的实底/边框/阴影），表容器自身吸顶 top:0；
   表头 sticky 在内滚容器里不受影响，浏览主路径不变 */
@media (max-width: 680px) {
  .ctl-sticky {
    position: static;
    background: none;
    border-bottom: 0;
    box-shadow: none;
    padding: 0;
  }
  .tbl-scroll {
    top: 0;
    max-height: max(50vh, calc(100vh - 96px));
  }
}

.row { cursor: pointer; }
.row:focus-visible { background: var(--row-hover); }
.row.open { background: var(--accent-bg); box-shadow: inset 2px 0 0 var(--accent-dim); }
.star { background: none; border: 0; padding: 0 4px 0 0; color: var(--faint); cursor: pointer; font-size: var(--fs-xs); }
.star.on { color: var(--lv5); }
.g-dot { display: inline-block; width: 7px; height: 7px; transform: rotate(45deg); margin-right: 8px; }
.a-name { color: var(--tx-strong); }
.row-chev {
  font-style: normal; font-size: var(--fs-micro); color: var(--faint);
  display: inline-block; margin-left: 6px;
  transition: transform var(--t-fast);
}
.row.open .row-chev { transform: rotate(180deg); color: var(--accent); }

.rank-cell { display: flex; align-items: center; justify-content: flex-end; gap: 8px; }
.rb-num { font-family: var(--mono); font-size: var(--fs-2xs); color: var(--dim); }
.rb-num.low { color: var(--ok, #34d399); }
.rb-num.high { color: var(--danger, #f87171); }
.rank-bar { width: 110px; height: 8px; background: var(--line2); border-radius: 4px; overflow: hidden; }
.rank-bar i { display: block; height: 100%; background: var(--dim); border-radius: 4px; }
.rank-bar i.low { background: var(--ok, #34d399); }
.rank-bar i.high { background: var(--danger, #f87171); }
@media (max-width: 680px) {
  .c-range { display: none; }
}

.sig {
  display: inline-block; font-family: var(--mono); font-size: var(--fs-2xs);
  letter-spacing: .1em; padding: 2px 10px; border-radius: var(--radius-pill);
  border: 1px solid var(--line); color: var(--dim);
}
.sig.buy { color: var(--ok, #34d399); border-color: var(--ok, #34d399); }
.sig.sell { color: var(--danger, #f87171); border-color: var(--danger, #f87171); }
.sig.watch { color: var(--info, #60a5fa); border-color: var(--info, #60a5fa); }
td.profit { color: var(--ok, #34d399); font-weight: 600; }

.expander td { position: relative; background: var(--card2); border-top: 1px solid var(--accent-dim); }
.exp-close {
  position: absolute; top: 10px; right: 10px;
  font-family: var(--mono); font-size: var(--fs-2xs); color: var(--dim);
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  padding: 3px 12px; cursor: pointer;
}
.exp-close:hover { border-color: var(--line-hover); }
.exp-note { color: var(--faint); font-size: var(--fs-xs); margin: 10px 2px 2px; line-height: 1.8; }
.exp-note b { color: var(--dim); }

.method {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-lg);
  padding: var(--sp-4) var(--sp-5);
  list-style: none; color: var(--dim); font-size: var(--fs-sm); line-height: 1.9;
}
.method li { padding-left: 16px; position: relative; }
.method li::before { content: "◆"; position: absolute; left: 0; color: var(--accent-dim); font-size: 8px; top: 7px; }
.method b { color: var(--tx); }
</style>
