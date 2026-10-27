<script setup>
/* MarketRadarView — 全品类异动雷达（子弹以外的钥匙/护甲/配件/物资）
   数据：public/market/radar.json（scripts/market/radar.mjs 落盘）
   口径与子弹页一致（scripts/ammo/analyze.mjs 分位数回归）；榜单来自 kkrb
   涨幅榜 Top10，曲线主源 moligod，双源中位偏差 >15% 压制信号（anomaly）。
   刷新：同源 SSE（serve 部署，radar 事件静默重拉；端点判定与子弹页共用
   shared/js/liveChannel.js）+ 60s 轮询兜底；数据节奏 = 服务端雷达
   循环（默认 10 分钟，radar:monitor 常驻时同口径）。 */
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import Sparkline from './ammo/Sparkline.vue'
import PriceChart from './ammo/PriceChart.vue'
import SkeletonView from '../components/SkeletonView.vue'
import { imgReady, hideImg } from '../composables/imgReady'
import { formatVersionLabel, picThumb } from '@shared/js/marketMeta.js'
import { liveChannelUrl, isLocalHttpHost, createLiveChannel } from '@shared/js/liveChannel.js'

const market = ref(null)
const loadState = ref('loading') // loading | ready | empty | error
const loadError = ref('')
const refreshing = ref(false)
const refreshTip = ref('')
const expanded = ref(null)
const pageRef = ref(null)
const searchRef = ref(null)

/* BASE_URL 前缀：子路径静态托管（BASE_URL 非 "/"）下不 404（同子弹页口径） */
const DATA_URL = `${import.meta.env.BASE_URL}market/radar.json`
const POLL_MS = 60 * 1000
let pollTimer = null
let prevTitle = '' // 路由标题：进入存默认值，卸载还原（模式同 AmmoMarketView）

/* 请求序号：SSE 事件 / 轮询 / 手动刷新并发打同一 URL 时只认最新一次的响应，
   先发慢到的旧快照不覆盖新快照（fetch 不取消、响应落地即丢弃） */
let loadSeq = 0

async function load({ silent = false } = {}) {
  const seq = ++loadSeq
  if (silent) refreshing.value = true
  try {
    const res = await fetch(DATA_URL, { cache: 'no-store' })
    if (seq !== loadSeq) return
    if (res.ok) {
      const j = await res.json()
      if (seq !== loadSeq) return
      if (Array.isArray(j.items) && j.items.length) {
        market.value = j
        loadState.value = 'ready'
      } else {
        loadState.value = 'empty'
      }
      refreshTip.value = ''
    } else if (!silent) {
      loadError.value = `HTTP ${res.status}`
      loadState.value = 'error'
    }
  } catch (e) {
    if (seq !== loadSeq) return
    if (silent) {
      refreshTip.value = '刷新失败，仍显示之前的数据'
    } else {
      loadError.value = e instanceof SyntaxError
        ? '雷达数据格式异常，请稍后重试'
        : e.message
      loadState.value = 'error'
    }
  } finally {
    if (seq === loadSeq) refreshing.value = false
  }
}

/* ---------- 数据时效 ---------- */
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
const versionLabel = computed(() => formatVersionLabel(market.value?.version))
/* 雷达节奏：monitor 默认 30min 一轮、榜单约每小时滚动 → 90min 变灰 / 4h 过期提示 */
const STALE_DOT_MIN = 90
const STALE_TIP_MIN = 240

/* ---------- 展示工具 ---------- */
const fmt = (n) => (Number.isFinite(n) ? Math.round(n).toLocaleString('zh-CN') : '—')
const pct = (n) => (Number.isFinite(n) ? `${n >= 0 ? '+' : ''}${(n * 100).toFixed(1)}%` : '—')
const SIGNAL_META = {
  BUY: { label: '买入', cls: 'buy' },
  WATCH: { label: '关注', cls: 'watch' },
  SELL: { label: '卖出', cls: 'sell' },
  WAIT: { label: '观望', cls: 'wait' },
}
const CATEGORY_LABEL = { props: '物资', protect: '护甲', gun: '枪械', acc: '配件', ammo: '子弹' }
const categoryLabel = (c) => CATEGORY_LABEL[c] || c || '—'
const gradeVar = (g) => (g >= 2 && g <= 6 ? `var(--lv${g})` : 'var(--faint)')
/* 图标到位/失败的事件处理三页共享（composables/imgReady.js）；占位底与淡入样式见 motion.css */
/* 双源列两种取值混排：有偏差 → 中位偏差百分比；重叠不足（<24h）无偏差 → 重叠
   小时数。原先无数据行显示「样本 0」无单位不自明，且解释只在 hover title 里
   （触屏够不着）——带 h 单位自明，口径另在列头 title 与页脚 src-note 常驻说明 */
const crossLabel = (i) =>
  i.crossDev == null ? `重叠 ${i.crossOverlap ?? 0}h` : `${(i.crossDev * 100).toFixed(1)}%`

/* ---------- 筛选与排序 ---------- */
const SIGNALS = [
  { v: 'all', label: '全部' },
  { v: 'BUY', label: '买入', dot: 'var(--ok)' },
  { v: 'WATCH', label: '关注', dot: 'var(--info)' },
  { v: 'SELL', label: '卖出', dot: 'var(--danger)' },
  { v: 'WAIT', label: '观望', dot: 'var(--faint)' },
  { v: 'anomaly', label: '双源异常', dot: 'var(--warn)' },
]
const SORTS = [
  { v: 'hiRank', label: '榜单名次' },
  { v: 'profit', label: '预期利润' },
  { v: 'rank', label: '价格分位' },
  { v: 'price', label: '当前价格' },
]
const SORT_DIR = { hiRank: 'asc', profit: 'desc', rank: 'asc', price: 'desc' }
const state = reactive({ signal: 'all', q: '', sort: 'hiRank', dir: 'asc' })

function onSort(v) {
  if (v !== state.sort) {
    state.sort = v
    state.dir = SORT_DIR[v]
  } else {
    state.dir = state.dir === 'asc' ? 'desc' : 'asc'
  }
}
/* 行键盘开关（同 AmmoMarketView.onRowKeydown）：Space 也能展开，preventDefault
   吞掉其页面滚动默认行为；焦点落在子元素时不代触发 */
function onRowKeydown(e, name) {
  if (e.target !== e.currentTarget) return
  e.preventDefault()
  expanded.value = expanded.value === name ? null : name
}
function clearFilters() {
  state.signal = 'all'
  state.q = ''
}
/* 搜索清除（模式同 AmmoMarketView.clearSearch）：清词后焦点回搜索框，键盘流不断 */
function clearSearch() {
  state.q = ''
  searchRef.value?.focus({ preventScroll: true })
}

const items = computed(() => market.value?.items || [])
const filtered = computed(() => {
  let list = items.value
  if (state.signal === 'anomaly') list = list.filter((i) => i.anomaly)
  else if (state.signal !== 'all') list = list.filter((i) => i.signal === state.signal)
  if (state.q.trim()) {
    const q = state.q.trim().toLowerCase()
    list = list.filter((i) => i.name.toLowerCase().includes(q))
  }
  const num = (x) => (Number.isFinite(x) ? x : state.dir === 'asc' ? Infinity : -Infinity)
  const m = state.dir === 'asc' ? 1 : -1
  const sorters = {
    hiRank: (a, b) => (num(a.hiRank) - num(b.hiRank)) * m, // 无名次行走 num 的方向感知哨兵，固定 99 会让 desc 把它排最前
    profit: (a, b) => (num(a.profitPerRound) - num(b.profitPerRound)) * m,
    rank: (a, b) => (num(a.rank) - num(b.rank)) * m,
    price: (a, b) => (num(a.current) - num(b.current)) * m,
  }
  return [...list].sort(sorters[state.sort] || sorters.hiRank)
})

const stats = computed(() => {
  const c = { BUY: 0, SELL: 0, WATCH: 0, WAIT: 0, anomaly: 0 } // 缺 WAIT 键会让观望 chip 计数空白
  for (const i of items.value) {
    if (c[i.signal] != null) c[i.signal]++
    if (i.anomaly) c.anomaly++
  }
  return c
})

/* ---------- 实时通道（同源 SSE，serve 部署形态）：先探测 /health 再连
   /events，收到 radar 事件静默重拉。断开不再永久放弃——带退避重探
   /health（30s→2min），服务端部署重启后自动回到实时推送。本地 dev 探
   不到保持「未连接」继续重探（60s 轮询兜底）；非本地且从未连上判
   「不适用」——纯静态托管退回轮询不打无效流量（重连助手与子弹页共用
   shared/js/liveChannel.js） ---------- */
const LIVE_SSE_URL = liveChannelUrl(location)
const liveChannel = ref('off') // off(环境不适用) | connecting | on | down
let live = null
const liveTip = computed(
  () => ({
    on: '实时推送已连接，异动自动送达',
    down: '实时推送已断开，自动重连中；期间每 60 秒自动刷新',
    connecting: '实时推送连接中…',
  }[liveChannel.value] || '')
)
function connectLive() {
  if (!LIVE_SSE_URL) return
  live = createLiveChannel({
    url: LIVE_SSE_URL,
    events: ['radar'],
    isLocal: () => isLocalHttpHost(location),
    onState: (s) => { liveChannel.value = s },
    onEvent: (t) => { if (t === 'radar') load({ silent: true }) },
  })
  live.start()
}

function onVisibility() {
  if (document.hidden) return
  nowTs.value = Date.now() // 顺带校正数据年龄
  load({ silent: true }) // 挂后台期间跳过的轮询在恢复可见时立即补一次
}

onMounted(() => {
  prevTitle = document.title
  document.title = '三角洲行动 · 全品类异动雷达'
  load()
  connectLive()
  pollTimer = setInterval(() => {
    if (document.hidden) return // 后台标签不空耗请求，恢复可见时补拉
    nowTs.value = Date.now()
    load({ silent: true })
  }, POLL_MS)
  document.addEventListener('visibilitychange', onVisibility)
})
onBeforeUnmount(() => {
  document.removeEventListener('visibilitychange', onVisibility)
  document.title = prevTitle
  if (pollTimer) clearInterval(pollTimer)
  if (live) live.stop()
})
</script>

<template>
  <div ref="pageRef" class="wrap page">
    <!-- 页头（紧凑单行，走 base.css .compact-head；数据过期提示在下方 stale-tip） -->
    <header class="compact-head">
      <h1>全品类异动雷达 <span class="live-dot" :class="{ stale: ageMin !== null && ageMin > STALE_DOT_MIN }" aria-hidden="true"></span></h1>
      <p v-if="market" class="meta" :title="`数据版本 ${versionLabel}${liveTip ? ' · ' + liveTip : ''}`">
        全品类涨幅榜 + 双源曲线交叉
      </p>
    </header>

    <!-- 过期提示条：淡入淡出（MOTION.md §3-F 提示行统一口径，条件消除时同样淡出） -->
    <Transition name="swap">
      <p v-if="ageMin !== null && ageMin > STALE_TIP_MIN" class="state-tip stale-tip" role="status">
        数据已 {{ ageLabel }} 未更新（榜单约每小时滚动），可稍后回来查看。
      </p>
    </Transition>
    <!-- 四态互切（loading/empty/error/ready，MOTION.md §4）：首载骨架→内容、空/错态
         进场统一 swap 淡入淡出（进场带 6px 上移、离场只淡出）；ready 是多兄弟节点，
         须各包单根 div 才能进 <Transition>；.state-card 类名留在内部（smoke.mjs 依赖） -->
    <Transition name="swap" mode="out-in">
      <div v-if="loadState === 'loading'" key="loading" class="sk-hold">
        <SkeletonView variant="table" :rows="10" />
      </div>
      <div v-else-if="loadState === 'empty'" key="empty" class="state-root">
        <div class="state-card">
          <p>还没有雷达数据。</p>
          <p class="dim">雷达快照正在准备中，稍后再来看看。</p>
          <button class="retry" @click="load()">重试</button>
        </div>
      </div>
      <div v-else-if="loadState === 'error'" key="error" class="state-root">
        <div class="state-card">
          <p>雷达数据加载失败：{{ loadError }}</p>
          <button class="retry" @click="load()">重试</button>
        </div>
      </div>
      <div v-else key="ready" class="state-root">
        <!-- 控制条 -->
        <div class="ctl-bar">
          <div class="chips" role="group" aria-label="信号筛选">
            <button
              v-for="s in SIGNALS" :key="s.v"
              class="chip" :class="{ on: state.signal === s.v }"
              :aria-pressed="state.signal === s.v"
              @click="state.signal = s.v"
            >
              <i v-if="s.dot" class="chip-dot" :style="{ background: s.dot }"></i>{{ s.label }}
              <span class="chip-n">{{
                s.v === 'all' ? items.length : s.v === 'anomaly' ? stats.anomaly : stats[s.v]
              }}</span>
            </button>
          </div>
          <span class="search-wrap">
            <input
              ref="searchRef" v-model.trim="state.q" class="search" :class="{ hasq: state.q }"
              type="search" placeholder="搜索物品" aria-label="搜索物品"
            >
            <button v-if="state.q" class="search-clear" aria-label="清除搜索" title="清除搜索" @click="clearSearch">✕</button>
          </span>
          <div class="chips" role="group" aria-label="排序">
            <button
              v-for="s in SORTS" :key="s.v"
              class="chip" :class="{ on: state.sort === s.v }"
              :aria-pressed="state.sort === s.v"
              @click="onSort(s.v)"
              >{{ s.label }}<svg v-if="state.sort === s.v" class="dir" viewBox="0 0 16 16" aria-hidden="true"><path v-if="state.dir === 'desc'" d="M8 3.5v9M4.5 9 8 12.5 11.5 9" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/><path v-else d="M8 12.5v-9M4.5 7 8 3.5 11.5 7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
          </div>
          <!-- 刷新中：绝不回骨架/遮罩（MOTION.md §3-F），chip 禁用 + 文案切换 + 内联小环；
               小环是「进行中」进度语义，RM 下按例外保留 -->
          <button class="chip refresh" :disabled="refreshing" title="重新拉取最新快照" @click="load({ silent: true })">{{ refreshing ? '刷新中' : '刷新' }}<i v-if="refreshing" class="mini-spin" aria-hidden="true"></i></button>
        </div>
        <!-- 刷新失败提示条：淡入淡出（MOTION.md §3-F），成功拉取后条件消除同样淡出 -->
        <Transition name="swap">
          <p v-if="refreshTip" class="refresh-tip warn" role="status">{{ refreshTip }}</p>
        </Transition>

        <!-- 榜单表 -->
        <div class="tbl-scroll">
          <table class="tbl">
            <thead>
              <tr>
                <th class="num" title="kkrb 涨幅榜名次">#</th>
                <th>物品</th>
                <th class="num">现价</th>
                <th>信号</th>
                <th class="num">预赚 / 件</th>
                <th class="num">7天分位</th>
                <th class="num c-range">周区间</th>
                <th>走势</th>
                <!-- 双源列头带 title：列内「百分比 / 重叠 Nh」两种取值的含义，桌面 hover 可查 -->
                <th class="num" title="两路独立曲线的中位偏差，越低越一致；无偏差数据时显示两路重叠小时数（不足 24h 不下双源结论）">双源</th>
              </tr>
            </thead>
            <tbody>
              <template v-for="i in filtered" :key="i.name">
                <tr
                  class="row data-row" :class="{ open: expanded === i.name }"
                  tabindex="0"
                  :aria-expanded="expanded === i.name"
                  @click="expanded = expanded === i.name ? null : i.name"
                  @keydown.enter="onRowKeydown($event, i.name)"
                  @keydown.space="onRowKeydown($event, i.name)"
                >
                  <td class="mono dimtx num">{{ i.hiRank ?? '—' }}</td>
                  <td>
                    <span class="a-icw" aria-hidden="true">
                      <img
                        v-if="i.pic" class="a-ic"
                        :src="picThumb(i.pic, 96)" alt=""
                        width="26" height="18" loading="lazy" decoding="async"
                        @load="imgReady" @error="hideImg"
                      >
                      <i class="a-gd" :style="{ background: gradeVar(i.grade) }" :title="`品级 ${i.grade}`"></i>
                    </span>
                    <span class="a-name">{{ i.name }}</span>
                    <span class="cat-tag">{{ categoryLabel(i.category) }}</span>
                    <i class="row-chev" aria-hidden="true"><svg viewBox="0 0 16 16" width="10" height="10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 6 L8 10.5 L12.5 6"/></svg></i>
                  </td>
                  <td class="mono strong num price-cell">{{ fmt(i.current) }}</td>
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
                        <i class="rb-tick" style="left: 25%"></i>
                        <i class="rb-tick" style="left: 80%"></i>
                        <i
                          class="rb-fill"
                          :style="{ width: `${Math.round(i.rank * 100)}%` }"
                          :class="{ low: i.rank <= 0.35, high: i.rank >= 0.8 }"
                        ></i>
                      </div>
                    </div>
                  </td>
                  <td class="mono dimtx num c-range">{{ fmt(i.weekLow) }} ~ {{ fmt(i.weekHigh) }}</td>
                  <td><Sparkline :curve="i.curve" :width="130" :height="30" /></td>
                  <td class="num">
                    <span
                      class="cross" :class="{ anomaly: i.anomaly }"
                      :title="i.anomaly
                        ? `两路独立曲线在重叠 ${i.crossOverlap} 小时的中位偏差 ${crossLabel(i)}——口径分歧，信号已压制为观望`
                        : i.crossDev == null
                          ? `双路曲线重叠仅 ${i.crossOverlap ?? 0} 小时，不足 24 小时未做双源结论`
                          : `两路独立曲线的中位偏差（越低越一致）`"
                      ><!-- 双源异常标记（inline SVG）：警示三角 + 叹号，随 .cross.anomaly 染 --warn -->
                      <svg v-if="i.anomaly" class="warn-ic" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.4 14.4 13.6H1.6Z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/><path d="M8 6.2v3.2M8 11.7v.1" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>{{ crossLabel(i) }}</span>
                  </td>
                </tr>
                <!-- 展开内容从 0 高度铺开（MOTION.md §3-C 表格展开行）：<Transition name="exp">
                     开合双向都动画（过渡类与 .exp-clip 三层结构见 motion.css）。本页特例：
                     展开内容装进 sticky 视口容器 .exp-hold（inner+pad 合体，不分层——分层会把
                     中间层变成 sticky 的滚动箱、截断横滚贴边）：这个 td 跟随 .tbl 的 min-width:980，
                     移动端 900px 图表、「收起」按钮、口径说明都会被排到横滚深处首屏
                     不可见；.exp-hold 按滚动视口宽（100cqw）渲染并左贴滚动视口，
                     三者恒在可视区（数据行仍可再点收起，属兜底而非正道） -->
                <Transition name="exp">
                  <tr v-if="expanded === i.name" class="expander">
                    <td colspan="9">
                      <div class="exp-clip">
                        <div class="exp-hold">
                          <button class="exp-close" @click="expanded = null">收起</button>
                          <PriceChart :curve="i.curve" :p25="i.p25" :p75="i.p75" :current="i.current" />
                          <p class="exp-note">
                            口径：买入参考 {{ fmt(i.p25) }}（7 天 P25）/ 目标挂卖 {{ fmt(i.targetSell) }}（近 3 天 75 分位，税后到手 {{ fmt(i.netSell) }}）/
                            税率 {{ (i.taxRate * 100).toFixed(0) }}%（非子弹无税后字段，按兜底税率）。
                            <template v-if="i.anomaly">双源中位偏差 {{ crossLabel(i) }}，原始信号 {{ SIGNAL_META[i.rawSignal]?.label || i.rawSignal }} 已压制为观望。</template>
                          </p>
                        </div>
                      </div>
                    </td>
                  </tr>
                </Transition>
              </template>
            </tbody>
          </table>
          <!-- 空态提示放表外：表内 td 跟随 .tbl 的 min-width:980，文案会居中在横滚表格
               中央，移动端首屏只剩表头、按钮也点不到；改为表格兄弟 div，块级宽度取
               滚动容器内容宽，天然锚在可视区内（表头保留，宽屏观感与原行式空态一致） -->
          <div v-if="!filtered.length" class="empty-cell">
            没有符合当前筛选的物品　<button class="retry" @click="clearFilters">清除全部筛选</button>
          </div>
        </div>

        <p class="src-note">
          榜单为全品类涨幅榜 Top10（钥匙/护甲/配件/物资等，子弹走
          <router-link to="/ammo">子弹行情</router-link>页）；信号口径与子弹页一致：P25 买入 / P80 卖出 / 税后 ≥8% 才报买入。
          「双源」列为两路独立曲线的中位偏差（越低越一致）；显示「重叠 Nh」表示两路重叠不足 24 小时、未做双源结论。
          非子弹单笔金额大、流动性差，挂单深度游戏内自查。
        </p>
      </div>
    </Transition>
  </div>
</template>

<style scoped>
.page { padding-bottom: var(--sp-10); }
/* 页头走 base.css .compact-head（单行式） */

.live-dot {
  display: inline-block; width: 10px; height: 10px; border-radius: 50%;
  background: var(--ok); margin-left: 10px;
  box-shadow: 0 0 8px var(--ok);
  animation: pulse 2.2s var(--ease) infinite;
}
.live-dot.stale { background: var(--faint); box-shadow: none; animation: none; }
@keyframes pulse { 50% { opacity: .35; } }
@media (prefers-reduced-motion: reduce) { .live-dot { animation: none; } }
.meta-stale { color: var(--warn); }

.state-tip { color: var(--dim); font-size: var(--fs-md); padding: var(--sp-6) 0; }
.state-tip code { font-family: var(--mono); color: var(--accent); }
.stale-tip { color: var(--warn); }
/* 首载骨架容器（SkeletonView table 变体，MOTION.md §4）：高度兜底走全局 .sk-hold 的
   max(560px, 60vh)（motion.css，三页统一——560px 对齐 ready「控制条 + 表头 + 10 行」
   ≈590px，loading→ready 页高只增不减（验收③）；60vh 落实验收②「骨架渲染高度 ≥60vh」）。
   外距与 .ctl-bar 同节奏，ready 切换时垂直位置稳定；描边/表头/行占位由 .sk-tbl 自带 */
.sk-hold { margin: var(--sp-5) 0 var(--sp-4); }
.state-card {
  background: var(--card); border: 1px dashed var(--line2); border-radius: var(--radius);
  padding: var(--sp-6); color: var(--tx); margin: var(--sp-4) 0;
}
.state-card pre { background: var(--deep); padding: 10px 14px; border-radius: var(--radius-sm); overflow: auto; }
.state-card code { font-family: var(--mono); color: var(--accent); }
/* 空态副文案降级（同 AmmoMarketView）：模板里的 .dim 原本无对应规则，
   两行等权重渲染，主次层级塌掉 */
.state-card .dim { color: var(--faint); font-size: var(--fs-sm); }
.retry {
  background: var(--accent-bg); color: var(--accent); border: 1px solid var(--accent-dim);
  border-radius: var(--radius); padding: 6px 18px; cursor: pointer; font-size: var(--fs-sm);
  transition: background-color var(--t-med) var(--ease), transform var(--t-fast) var(--ease);
}
.retry:hover { background: var(--accent-soft); }
.retry:active { background: var(--accent-soft); transform: scale(.98); }
.retry:disabled { opacity: .45; cursor: default; }
/* 空态容器（表格兄弟 div，非 td）：宽度自适应滚动容器内容宽，居中即居中在可视区 */
.empty-cell { text-align: center; color: var(--dim); padding: var(--sp-6) 0; }

/* 控制条（榜单仅 10 行，不做吸顶机械） */
.ctl-bar {
  display: flex; flex-wrap: wrap; align-items: center; gap: var(--sp-4);
  margin: var(--sp-5) 0 var(--sp-4);
}
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chip {
  display: inline-flex; align-items: center; gap: 6px;
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  color: var(--dim); font-size: var(--fs-xs); padding: 4px 12px; cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease),
    background-color var(--t-fast) var(--ease);
}
.chip:hover,
.chip:active { color: var(--tx); border-color: var(--line-hover); }
.chip.on { color: var(--accent); border-color: var(--accent-dim); background: var(--accent-bg); }
.chip-dot { width: 6px; height: 6px; border-radius: 50%; }
.chip-n { font-family: var(--mono); color: var(--faint); }
.chip.refresh { margin-left: auto; }
.chip.refresh:disabled { opacity: .6; cursor: default; }
/* 方向标记 / 异常警示（inline SVG）：继承文字色 */
.dir { width: 10px; height: 10px; margin-left: 2px; color: var(--accent); flex: none; }
.warn-ic { width: 11px; height: 11px; margin-right: 3px; vertical-align: -1px; }
.refresh-tip { font-family: var(--mono); font-size: var(--fs-xs); margin: 0 0 var(--sp-3); }
.refresh-tip.warn { color: var(--warn); }
.search {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  color: var(--tx); font-size: var(--fs-xs); padding: 5px 14px; width: 160px;
  font-family: var(--sans); /* 表单控件不吃 body 字阶，显式声明（同 .qty-in 显式 --mono 的口径） */
  transition: border-color var(--t-fast) var(--ease);
}
/* 输入聚焦只改边框（--accent-dim），不写 outline:none——键盘聚焦的 2px --accent
   外框由 base.css 全局 :focus-visible 提供，不许在组件里抹掉 */
.search:focus { border-color: var(--accent-dim); }
/* 搜索框包装：给「✕ 清除」留绝对定位包含块（复刻子弹页 .search-wrap/.search-clear
   模式，不占布局位、不挤 chip；Firefox 的 type=search 无原生清除 UI） */
.search-wrap { position: relative; display: inline-flex; }
/* 有词时给 ✕ 让位；同时压掉 WebKit type=search 自带清除钮（避免双 ✕） */
.search.hasq { padding-right: 26px; }
.search::-webkit-search-cancel-button { display: none; }
.search-clear {
  position: absolute; right: 5px; top: 50%; transform: translateY(-50%);
  width: 18px; height: 18px; flex: none;
  display: inline-flex; align-items: center; justify-content: center;
  background: none; border: 0; border-radius: 50%;
  color: var(--faint); font-size: var(--fs-2xs); line-height: 1; cursor: pointer;
  transition: color var(--t-fast) var(--ease), background-color var(--t-fast) var(--ease);
}
.search-clear:hover,
.search-clear:active { color: var(--tx); background: var(--line); }

/* 榜单表：9 列低于 ~1000px 视口时会被 width:100% 的 auto 布局压列换行，
   给足 min-width 让 .tbl-scroll 横向滚动而不是把物品名压成竖排 */
.tbl-scroll {
  overflow-x: auto;
  border: 1px solid var(--line);
  border-radius: var(--radius);
  /* 声明 inline-size 容器：给 .exp-hold 的 100cqw 提供基准（滚动视口的内容宽，
     随断点水槽/渐隐槽自适应），展开行内容按可视宽而非 980px 表宽渲染 */
  container-type: inline-size;
}
.tbl-scroll .tbl { min-width: 980px; }
/* 窄屏横滚提示：右缘 32px 渐隐（mask 固定于滚动视口、内容从其下滚过，零 DOM、
   不挡交互）；同步 padding-right 造出等宽空槽——滚到最右时渐隐落在空槽上，
   不压「双源」列数字。阈值 1069 = 表 980 + 槽 32 + wrap 水槽 56 + 边框 2，
   此宽度以下必然横滚（media 与可滚保持一致，宽屏无痕） */
@media (max-width: 1069px) {
  .tbl-scroll {
    padding-right: 32px;
    -webkit-mask-image: linear-gradient(to right, #000 calc(100% - 32px), transparent);
    mask-image: linear-gradient(to right, #000 calc(100% - 32px), transparent);
  }
}
.row { cursor: pointer; }
/* 斑马纹交给 base.css 的 nth-child(even of .data-row) 契约：本页数据行已挂
   data-row，展开行插入不再打断奇偶，无需再按 filtered 索引自算 odd/even；
   scoped [data-v]（0,3,0）高于 base 表级规则（0,2,2），hover/open 仍需在此重声明 */
.row:hover,
.row:focus-visible { background: var(--row-hover); }
.row.open { background: var(--accent-bg); box-shadow: inset 2px 0 0 var(--accent-dim); }
.cat-tag {
  font-family: var(--mono); font-size: var(--fs-micro); color: var(--faint);
  border: 1px solid var(--line2); border-radius: var(--radius-pill);
  padding: 1px 8px; margin-left: 8px; vertical-align: 1px;
}
.a-icw {
  position: relative;
  display: inline-flex; align-items: center; justify-content: center;
  width: 28px; height: 18px; margin-right: 8px; vertical-align: middle;
}
.a-ic { width: 26px; height: 18px; object-fit: contain; } /* 加载淡入与占位底见 motion.css（imgReady） */
.a-gd {
  position: absolute; left: -4px; bottom: -3px;
  width: 6px; height: 6px; transform: rotate(45deg);
  box-shadow: 0 0 0 2px var(--card);
}
.a-name { color: var(--tx-strong); white-space: nowrap; }
.row-chev {
  display: inline-flex; align-items: center; color: var(--faint);
  margin-left: 6px;
  /* 箭头统一 --t-slow .22s（MOTION.md §3-C 收编三档并存，同 CollapseCol .chev）：
     略快于展开体 .25s，先转后铺，读作同一动作的前导；色照旧 --t-fast */
  transition: transform var(--t-slow) var(--ease), color var(--t-fast) var(--ease);
}
.row-chev svg { display: block; }
.row.open .row-chev { transform: rotate(180deg); color: var(--accent); }

.rank-cell { display: flex; align-items: center; justify-content: flex-end; gap: 8px; }
.rb-num { font-family: var(--mono); font-size: var(--fs-xs); color: var(--dim); }
.rb-num.low { color: var(--ok); }
.rb-num.high { color: var(--danger); }
.rank-bar { position: relative; width: 110px; height: 7px; background: var(--line2); border-radius: 4px; }
.rb-tick { position: absolute; top: -2px; bottom: -2px; width: 1px; background: var(--line-hover); }
.rb-fill { position: absolute; top: 0; bottom: 0; left: 0; border-radius: 4px; background: var(--faint); }
.rb-fill.low {
  background: linear-gradient(90deg, rgba(133, 181, 120, .45), var(--ok)); /* 不支持 color-mix 的引擎兜底 */
  background: linear-gradient(90deg, color-mix(in srgb, var(--ok) 45%, transparent), var(--ok));
}
.rb-fill.high {
  background: linear-gradient(90deg, rgba(217, 106, 89, .45), var(--danger)); /* 同上兜底 */
  background: linear-gradient(90deg, color-mix(in srgb, var(--danger) 45%, transparent), var(--danger));
}

.sig {
  display: inline-block; font-family: var(--mono); font-size: var(--fs-2xs);
  letter-spacing: .1em; padding: 2px 10px; border-radius: var(--radius-pill);
  border: 1px solid var(--line2); color: var(--dim); background: var(--card);
  white-space: nowrap;
}
.sig.buy {
  color: var(--ok);
  border-color: rgba(133, 181, 120, .4); /* 不支持 color-mix 的引擎兜底 */
  background: rgba(133, 181, 120, .1);
  border-color: color-mix(in srgb, var(--ok) 40%, transparent);
  background: color-mix(in srgb, var(--ok) 10%, transparent);
}
.sig.sell {
  color: var(--danger);
  border-color: rgba(217, 106, 89, .4); /* 同上兜底 */
  background: rgba(217, 106, 89, .1);
  border-color: color-mix(in srgb, var(--danger) 40%, transparent);
  background: color-mix(in srgb, var(--danger) 10%, transparent);
}
.sig.watch {
  color: var(--info);
  border-color: rgba(97, 159, 206, .4); /* 同上兜底 */
  background: rgba(97, 159, 206, .1);
  border-color: color-mix(in srgb, var(--info) 40%, transparent);
  background: color-mix(in srgb, var(--info) 10%, transparent);
}
td.profit { color: var(--ok); font-weight: 600; }
.tbl td.price-cell { font-size: var(--fs-md); color: var(--tx-strong); font-weight: 700; }

.cross { font-family: var(--mono); font-size: var(--fs-xs); color: var(--dim); cursor: help; }
.cross.anomaly { color: var(--warn); font-weight: 600; }

.expander td {
  position: relative; background: var(--card2); border-top: 1px solid var(--accent-dim);
  padding: 0; /* padding 移入 .exp-hold：随 0fr→1fr 铺开动画一并裁剪，起点是真 0 高度 */
}
/* 展开内容铺开（MOTION.md §3-C）：.exp-clip 与 .exp-* 过渡类已提升 motion.css（三页
   开合双向对齐，含 RM 兜底）；本页 .exp-hold 是 sticky 视口容器特例（inner+pad 合体，
   见模板注释），自身带 overflow:hidden + min-height:0 让 0fr 轨能压到真 0 高 */
/* 展开行视口容器：sticky 左贴滚动视口 + 宽取 100cqw（= .tbl-scroll 内容宽，border-box
   已含自身 padding）——超出会把表撑出容器、宽屏展开时平白多出横向滚动；图表/收起/
   说明不随 980px 表格横滚跑出首屏。sticky 自身是定位元素，绝对定位的 .exp-close
   直接锚它右缘。min-height:0 + overflow:hidden 让轨道能压到 0（overflow 只挂在
   sticky 元素自身：若挂在中间包裹层会把它变成 sticky 的滚动箱、截断横滚贴边）；
   不支持 cqw 的引擎整条声明被丢弃，退回旧的整格宽渲染，不比现状差 */
.exp-hold {
  position: sticky; left: 0; width: 100cqw;
  padding: 9px 10px; min-height: 0; overflow: hidden;
}
.exp-close {
  position: absolute; top: 10px; right: 10px;
  font-family: var(--mono); font-size: var(--fs-xs); color: var(--dim);
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  padding: 3px 12px; cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
}
.exp-close:hover,
.exp-close:active { color: var(--tx); border-color: var(--line-hover); }
.exp-note { color: var(--faint); font-size: var(--fs-xs); margin: 10px 2px 2px; line-height: 1.8; }

.src-note { color: var(--faint); font-size: var(--fs-xs); margin-top: var(--sp-4); line-height: 1.8; }
.src-note a { color: var(--accent); }
.src-note a:hover,
.src-note a:active { text-decoration: underline; text-underline-offset: 3px; }

@media (max-width: 680px) {
  .c-range { display: none; }
  .chip-n { display: none; }
}

/* 本页新增/收紧的微交互过渡统一在 reduce 下关闭（live-dot 的在上面自带）；
   swap/sk/exp/mini-spin/.a-ic 淡入等全局类由 motion.css 文件尾统一兜底，
   此处只管本页 scoped 项 */
@media (prefers-reduced-motion: reduce) {
  .chip, .search, .search-clear, .retry, .exp-close, .row-chev { transition: none; }
  .retry:active { transform: none; }
}
</style>
