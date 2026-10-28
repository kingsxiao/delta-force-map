<script setup>
/* MarketRadarView — 全品类异动雷达（子弹以外的钥匙/护甲/配件/物资）
   数据：public/market/radar.json（scripts/market/radar.mjs 落盘）
   口径与子弹页一致（scripts/ammo/analyze.mjs 分位数回归）；榜单来自 kkrb
   涨幅榜 Top10，曲线主源 moligod，双源中位偏差 >15% 压制信号（anomaly）。
   刷新：同源 SSE（serve 部署，radar 事件按版本前进静默重拉）+ 分档轮询兜底
   （off 30min / on 5min / 其余 60s）——整条快照数据链在
   ../composables/useSnapshotFeed.js（与子弹 / 制造页共用）；数据节奏 =
   服务端雷达循环（默认 10 分钟，radar:monitor 常驻时同口径）。 */
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import Sparkline from './ammo/Sparkline.vue'
import PriceChart from './ammo/PriceChart.vue'
import SkeletonView from '../components/SkeletonView.vue'
import { imgReady, hideImg } from '../composables/imgReady'
import { useSnapshotFeed } from '../composables/useSnapshotFeed'
import { fmt, pct, SIGNAL_META, SIG_COLOR, gradeVar } from '../utils/format.js'
import { formatVersionLabel, staleness, fmtAge, picThumb } from '@shared/js/marketMeta.js'

const expanded = ref(null)
const searchRef = ref(null)
let prevTitle = '' // 路由标题：进入存默认值，卸载还原（模式同 AmmoMarketView）

/* ---------- 快照数据链（useSnapshotFeed：loadSeq 守卫 / 非 2xx throw / SSE
   版本门控 / 分档轮询 / 回前台补拉 / 卸载清理）。雷达页差异全走默认：
   items 为空 → 空态；静默保持 silent（空/错态卡片不闪骨架）；成功回声开。
   BASE_URL 前缀：子路径静态托管（BASE_URL 非 "/"）下不 404（同子弹页口径） */
const {
  market, loadState, loadError, refreshing, refreshTip, refreshTipKind,
  nowTs, liveChannel, load,
} = useSnapshotFeed(`${import.meta.env.BASE_URL}market/radar.json`, {
  events: ['radar'],
  syntaxError: '雷达数据格式异常，请稍后重试',
  onLoaded: (json, { prev }) => diffPriceFlash(prev?.items, json.items),
})

/* ---------- 价格闪变（同 AmmoMarketView.diffPriceFlash）：轮询/SSE 刷出新快照
   后 diff 新旧现价，真变了的格挂 up/down 类做一次性 0.8s 低幅度（≤14%）底色
   脉冲，900ms 后 JS 摘类。MOTION.md §3-E 禁的是整表数字滚动（翻牌=噪声），
   这里不动数字本身；底色脉冲属 §6-1 允许的状态过渡（无布局成本），只给真变
   了的格、一次性。纯静态环境快照版本不变 → diff 天然为空，不会整表乱闪 ---------- */
const priceFlash = reactive({})
let flashTimer = null
function diffPriceFlash(prevItems, nextItems) {
  if (!prevItems?.length) return // 首载无旧值可比，不闪
  const prev = new Map(prevItems.map((i) => [i.name, i.current]))
  let hit = false
  for (const it of nextItems) {
    const p = prev.get(it.name)
    if (p == null || it.current == null || it.current === p) continue
    priceFlash[it.name] = it.current > p ? 'up' : 'down'
    hit = true
  }
  if (!hit) return
  clearTimeout(flashTimer)
  flashTimer = setTimeout(() => {
    for (const k of Object.keys(priceFlash)) delete priceFlash[k]
  }, 900)
}

/* ---------- 数据时效 ---------- */
const ageMin = computed(() => {
  const t = Date.parse(market.value?.fetchedAt)
  return Number.isFinite(t) ? (nowTs.value - t) / 60000 : null
})
const ageLabel = computed(() => {
  if (ageMin.value == null) return ''
  /* <1 分钟「刚刚更新」（杜绝「0 分钟前」，口径对齐 iOS RadarView.ageText）；
     其余走 @shared/js/marketMeta.js fmtAge（与 TTK 页 / 子弹页过期提示共用，
     四舍五入取整）；stale-tip 复用本函数（>240min 才出现，不会撞「刚刚更新」分支） */
  if (ageMin.value < 1) return '刚刚更新'
  return `${fmtAge(ageMin.value)}前`
})
const versionLabel = computed(() => formatVersionLabel(market.value?.version))
/* 雷达时效（kkrb-radar+moligod 双源档，@shared/js/marketMeta.js staleness）：
   monitor 默认 30min 一轮、榜单约每小时滚动 → 90min 变灰 / 4h 过期提示 */
const thresholds = computed(() => staleness(market.value?.source))

/* ---------- 展示工具：fmt / pct / SIGNAL_META / SIG_COLOR / gradeVar 统一收编
   ../utils/format.js；CATEGORY_LABEL / crossLabel 为本页专属 ---------- */
const CATEGORY_LABEL = { props: '物资', protect: '护甲', gun: '枪械', acc: '配件', ammo: '子弹' }
const categoryLabel = (c) => CATEGORY_LABEL[c] || c || '—'
/* 图标到位/失败的事件处理三页共享（composables/imgReady.js）；占位底与淡入样式见 motion.css */
/* 双源列两种取值混排：有偏差 → 中位偏差百分比；重叠不足（<24h）无偏差 → 重叠
   小时数。原先无数据行显示「样本 0」无单位不自明，且解释只在 hover title 里
   （触屏够不着）——带 h 单位自明，口径另在列头 title 与页脚 src-note 常驻说明 */
const crossLabel = (i) =>
  i.crossDev == null ? `重叠 ${i.crossOverlap ?? 0}h` : `${(i.crossDev * 100).toFixed(1)}%`

/* ---------- 筛选与排序 ---------- */
/* Popover API 能力检测（同步、一次性，setup 期即定）：支持时模板 :title 绑定
   undefined → th 不渲染 title（hover 原生气泡与可点浮层并存是双提示）；不支持
   则 title 原样渲染兜底（hover 说明不缺席）。原先在 onMounted 里摘 DOM 属性——
   但表格在四态 Transition（out-in）的 ready 分支内，mounted 时是 loading 骨架、
   th 不在 DOM，离场过渡 250ms 后才插入，摘除时机永远赶不上（该轮遗留 bug）；
   响应式绑定让首次渲染即正确，不再做事后 DOM 修补 */
const popSupported = typeof HTMLElement !== 'undefined' && HTMLElement.prototype.hasOwnProperty('popover')

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
   /events，收到 radar 事件按版本前进静默重拉；断开带退避重探、服务端部署
   重启后自动回到实时推送（重连助手与数据链都在 useSnapshotFeed /
   shared/js/liveChannel.js）。此处只剩通道状态的文案映射 ---------- */
const liveTip = computed(
  () => ({
    on: '实时推送已连接，异动自动送达',
    down: '实时推送已断开，自动重连中；期间每 60 秒自动刷新',
    connecting: '实时推送连接中…',
  }[liveChannel.value] || '')
)

onMounted(() => {
  prevTitle = document.title
  document.title = '三角洲行动 · 全品类异动雷达'
  /* th 口径说明的 title 兜底改由 popSupported 响应式绑定（见其定义处注释），
     此处不再做事后 DOM 摘除——表格要等四态 out-in 过渡完才进 DOM，摘除赶不上 */
})
onBeforeUnmount(() => {
  document.title = prevTitle
  if (flashTimer) clearTimeout(flashTimer) // 闪变摘类定时器：不摘会在卸载后空写 ref
})
</script>

<template>
  <div class="wrap page">
    <!-- 页头（紧凑单行，走 base.css .compact-head；数据过期提示在下方 stale-tip） -->
    <header class="compact-head">
      <h1>全品类异动雷达 <span class="live-dot" :class="{ stale: ageMin !== null && ageMin > thresholds.staleDotMin }" aria-hidden="true"></span></h1>
      <p v-if="market" class="meta" :title="`数据版本 ${versionLabel}${liveTip ? ' · ' + liveTip : ''}`">
        全品类涨幅榜 + 双源曲线交叉<!-- 推送断开从「仅 title 可查」升为常驻可见（触屏够不着
             title）：断开意味着数据可能滞后、是用户需要知道的因果；on/connecting 为
             瞬时好态，不值得常驻占位 --><!-- 数据年龄同理升常驻（对齐 iOS freshness 行的常驻
             口径）：榜单约每小时滚动，「这是几时前的榜」直接决定要不要按它下单，是
             决策信息而非装饰字；版本号仍留 title（快照 id 对决策价值低，不占常驻位） -->
        <span v-if="ageLabel" class="meta-age">· 数据 {{ ageLabel }}</span>
        <span v-if="liveChannel === 'down'" class="live-down">· 实时推送已断开，60s 轮询兜底</span>
      </p>
    </header>

    <!-- 过期提示条：淡入淡出（MOTION.md §3-F 提示行统一口径，条件消除时同样淡出） -->
    <Transition name="swap">
      <p v-if="ageMin !== null && ageMin > thresholds.staleTipMin" class="state-tip stale-tip" role="status">
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
          <!-- :disabled + 文案切换防连点空转（refreshing 由 load() 无条件置位） -->
          <button class="retry" :disabled="refreshing" @click="load()">{{ refreshing ? '重试中…' : '重试' }}</button>
        </div>
      </div>
      <div v-else-if="loadState === 'error'" key="error" class="state-root">
        <div class="state-card">
          <p>雷达数据加载失败：{{ loadError }}</p>
          <button class="retry" :disabled="refreshing" @click="load()">{{ refreshing ? '重试中…' : '重试' }}</button>
        </div>
      </div>
      <div v-else key="ready" class="state-root">
        <!-- 控制条 -->
        <div class="ctl-bar">
          <div class="chips" role="group" aria-label="信号筛选">
            <button
              v-for="s in SIGNALS" :key="s.v"
              class="chip press" :class="{ on: state.signal === s.v }"
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
              class="chip press" :class="{ on: state.sort === s.v }"
              :aria-pressed="state.sort === s.v"
              @click="onSort(s.v)"
              >{{ s.label }}<!-- 方向箭头单路径 + .flip 旋转 180°（两条 path 是中心对称的，
                   换 v-if 分支只能瞬跳）；再点同一 chip 切方向时箭头转向即为「换了方向」
                   的可见回声，transform-only、RM 下瞬时 --><svg v-if="state.sort === s.v" class="dir" :class="{ flip: state.dir === 'asc' }" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 3.5v9M4.5 9 8 12.5 11.5 9" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
          </div>
          <!-- 刷新中：绝不回骨架/遮罩（MOTION.md §3-F），chip 禁用 + 文案切换 + 内联小环；
               小环是「进行中」进度语义，RM 下按例外保留 -->
          <button class="chip press refresh" :disabled="refreshing" title="重新拉取最新快照" @click="load({ silent: true })">{{ refreshing ? '刷新中…' : '刷新' }}<i v-if="refreshing" class="mini-spin" aria-hidden="true"></i></button>
        </div>
        <!-- 刷新失败/成功提示条：淡入淡出（MOTION.md §3-F），条件消除同样淡出；
             kind 由脚本侧给（warn=失败常驻 / ok=成功回声 4s 自动消失） -->
        <Transition name="swap">
          <p v-if="refreshTip" class="refresh-tip" :class="refreshTipKind" role="status">{{ refreshTip }}</p>
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
                <!-- 列头口径说明 popover 化（Popover API 渐进增强）：title 原生气泡触屏够不
                     着、延迟大、样式不受控，改为可点开 / 可 Tab 聚焦回车打开的浮层（进出场
                     @starting-style、锚定 anchor 定位，见样式区 .th-q/.th-pop）。:title 绑定
                     popSupported——支持 popover 的新浏览器绑 undefined 不渲染（否则 hover 气
                     泡与浮层构成双提示），不支持的老浏览器保留 title 兜底（见 script 注释）。
                     分位/双源是本页口径最晦涩的两列，说明优先给它们 -->
                <th class="num q-th" :title="popSupported ? undefined : '近 7 天收盘价分位：≤35% 标绿（贴近低位），≥80% 标红（贴近高位）'">7天分位<button class="th-q q-rank" type="button" popovertarget="radar-pop-rank" aria-label="7 天分位列口径说明">?</button><div popover="auto" id="radar-pop-rank" class="th-pop pop-rank">现价在近 7 天价格区间中的位置：≤35% 标绿（贴近 7 天低位、接近买入参考区），≥80% 标红（贴近高位）。条内两条刻度线为 25% / 80% 参考位，与信号口径的 P25 买入 / P80 卖出一致。</div></th>
                <th class="num c-range">周区间</th>
                <th>走势</th>
                <th class="num q-th" :title="popSupported ? undefined : '两路独立曲线的中位偏差，越低越一致；无偏差数据时显示两路重叠小时数（不足 24h 不下双源结论）'">双源<button class="th-q q-cross" type="button" popovertarget="radar-pop-cross" aria-label="双源列口径说明">?</button><div popover="auto" id="radar-pop-cross" class="th-pop pop-cross">两路独立数据源各自拟合价格曲线，取重叠时段的中位偏差：越低越一致、信号越可信；偏差过大时此格标警示色，行内信号已压制为观望。显示「重叠 Nh」表示两路重叠不足 24 小时、未下双源结论。</div></th>
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
                    <span
                      class="a-icw" aria-hidden="true"
                      :style="{ '--gd': gradeVar(i.grade) }" :title="`品级 ${i.grade}`"
                    >
                      <img
                        v-if="i.pic" class="a-ic"
                        :src="picThumb(i.pic, 96)" alt=""
                        width="26" height="18" loading="lazy" decoding="async"
                        @load="imgReady" @error="hideImg"
                      >
                    </span>
                    <span class="a-name">{{ i.name }}</span>
                    <span class="cat-tag">{{ categoryLabel(i.category) }}</span>
                    <i class="row-chev" aria-hidden="true"><svg viewBox="0 0 16 16" width="10" height="10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 6 L8 10.5 L12.5 6"/></svg></i>
                  </td>
                  <!-- price-cell 的动态类是价格闪变 up/down（diffPriceFlash 挂类、脉冲毕摘类） -->
                  <td class="mono strong num price-cell" :class="priceFlash[i.name]">{{ fmt(i.current) }}</td>
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
                  <td><Sparkline :curve="i.curve" :width="130" :height="30" :end-color="SIG_COLOR[i.signal] || 'var(--faint)'" /></td>
                  <td class="num">
                    <span
                      class="cross" :class="{ anomaly: i.anomaly, nodata: i.crossDev == null }"
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
                          <button class="exp-close press" @click="expanded = null">收起</button>
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
               滚动容器内容宽，天然锚在可视区内（表头保留，宽屏观感与原行式空态一致）。
               淡入淡出对齐其余提示条（MOTION.md §3-F「所有 v-if 提示行统一淡入」，
               筛选清空成排行消失的瞬间它随之上移淡入，读作同一动作的结果而非另一次
               跳变）；role=status 让读屏器在结果集清空时收到播报 -->
          <Transition name="swap">
            <div v-if="!filtered.length" class="empty-cell" role="status">
              没有符合当前筛选的物品　<button class="retry" @click="clearFilters">清除全部筛选</button>
            </div>
          </Transition>
        </div>

        <p class="src-note">
          榜单为全品类涨幅榜 Top10（钥匙/护甲/配件/物资等，子弹走
          <router-link to="/ammo">子弹行情</router-link>页）；信号口径与子弹页一致：P25 买入 / P80 卖出 / 税后 ≥8% 才报买入。
          「预赚」为税后口径——非子弹物品无税后字段，按兜底税率估算（对齐 iOS 页面级说明；逐物品税率见展开面板）。
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
/* 常驻数据年龄（见模板注释）：比 meta 基底的 faint 提一档到 dim——整行 meta 是
   背景说明，年龄是其中唯一影响决策的数字（iOS freshness 同为独立可见行）；不升
   到 tx/语义色：新鲜度异常的表达已有 live-dot 变灰 + stale-tip warn 两通道，此
   处恒定 dim 不抢第三通道 */
.meta-age { color: var(--dim); }
/* 推送断开常驻标记（meta 内，见模板注释）：warn 色轻量嵌进 mono 小字行 */
.live-down { color: var(--warn); margin-left: 6px; }

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
  /* transition 列表补 transform 项：chips 已挂 motion.css 的 .press（:active
     scale .98 全站按压语汇），该文件的约定是调用方自带 transition 且列表含
     transform，否则挂类也瞬跳；RM 兜底由 motion.css 文件尾统一关停 */
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease),
    background-color var(--t-fast) var(--ease), transform var(--t-fast) var(--ease);
}
.chip:hover,
.chip:active { color: var(--tx); border-color: var(--line-hover); }
.chip.on { color: var(--accent); border-color: var(--accent-dim); background: var(--accent-bg); }
.chip-dot { width: 6px; height: 6px; border-radius: 50%; }
.chip-n { font-family: var(--mono); color: var(--faint); }
.chip.refresh { margin-left: auto; }
.chip.refresh:disabled { opacity: .6; cursor: default; }
/* 方向标记 / 异常警示（inline SVG）：继承文字色。transition 含 transform——
   .flip 换向旋转（180° 中心对称，见模板注释）；RM 兜底在文件尾 */
.dir { width: 10px; height: 10px; margin-left: 2px; color: var(--accent); flex: none; transition: transform var(--t-fast) var(--ease); }
.dir.flip { transform: rotate(180deg); }
.warn-ic { width: 11px; height: 11px; margin-right: 3px; vertical-align: -1px; }
.refresh-tip { font-family: var(--mono); font-size: var(--fs-xs); margin: 0 0 var(--sp-3); }
.refresh-tip.warn { color: var(--warn); }
/* 成功回声走 dim（同子弹页口径）：成功是常态、降权不打断；warn 留给失败——
   两态同一条提示行，色档即语义档 */
.refresh-tip.ok { color: var(--dim); }
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
/* 触控垫层：视觉 18px 不变，伪元素外扩命中区到 44px（18+13×2），不占布局位、
   不挡输入（命中区只覆盖自身周边空白），与「可点目标≥44px」原则对齐 */
.search-clear::after { content: ''; position: absolute; inset: -13px; }

/* ---- 列头口径说明提示层（Popover API 渐进增强，配模板 .th-q/.th-pop）----
   问号小钮视觉 14px，浮层进出场 @starting-style + allow-discrete（180ms 微交互档，
   只动 opacity/transform）；锚定走 anchor positioning，@supports 守卫——不支持时
   浮层回退 UA 默认视口居中（仍可读可关），不影响居中兜底的 inset/margin 残留；
   不支持 Popover API 的浏览器该 div 恒 display:none，title 兜底说明仍在 */
.th-q {
  position: relative; /* 触屏伪元素外扩命中区的包含块 */
  display: inline-flex; align-items: center; justify-content: center;
  width: 14px; height: 14px; margin-left: 5px; vertical-align: -2px;
  border: 1px solid var(--line); border-radius: 50%;
  background: none; color: var(--faint); cursor: pointer; padding: 0;
  font-family: var(--mono); font-size: 10px; line-height: 1;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
}
.th-q:hover,
.th-q:active { color: var(--accent); border-color: var(--accent-dim); }
.q-rank { anchor-name: --q-rank; }
.q-cross { anchor-name: --q-cross; }
/* 浮层开着时问号钮保持点亮（light dismiss 关闭即回落）：:has 相邻兄弟匹配其后的
   popover；不支持 :has/:popover-open 的浏览器整条失效，安全降级为无开态高亮 */
.th-q:has(+ .th-pop:popover-open) { color: var(--accent); border-color: var(--accent-dim); }
.th-pop {
  background: var(--panel-solid);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  box-shadow: var(--shadow-md); /* top layer 浮层，按令牌约定可用阴影 */
  color: var(--tx); font-size: var(--fs-xs); line-height: 1.8;
  padding: 10px 14px; max-width: 300px;
  /* 覆写继承的 nowrap（.tbl th 有 white-space:nowrap，浮层是 th 子孙会继承）：
     口径说明是 80+ 字长句，nowrap 下行宽不受 max-width 约 300px 束、文字溢出
     浮层画出界；normal 让长句在盒内正常折行 */
  white-space: normal;
  /* display/overlay 走 allow-discrete：让「关闭」（含 light dismiss）也有出场过渡，
     否则浮层瞬失；不支持离散过渡的引擎这两项被忽略，退回瞬开瞬关=现状 title 行为 */
  opacity: 0; transform: translateY(-4px);
  transition: opacity var(--t-med) var(--ease), transform var(--t-med) var(--ease),
    display var(--t-med) allow-discrete, overlay var(--t-med) allow-discrete;
}
.th-pop:popover-open { opacity: 1; transform: none; }
@starting-style {
  .th-pop:popover-open { opacity: 0; transform: translateY(-4px); }
}
/* 老浏览器防护（子弹页同款）：不识别 popover 属性的引擎（老 Safari/Firefox）会把
   该 div 当普通块级元素常驻渲染——opacity:0 不可见但占位，80 字长句折行 ≈60px 高
   直接撑破表头。显式 display:none 整个摘除，回退到「title 兜底说明仍在」的现状
   （功能完整，非降级）；:popover-open 选择器与 popover 属性在同版本落地，互斥守卫
   恒成立 */
@supports not selector(:popover-open) {
  .th-pop { display: none; }
}
@supports (anchor-name: --a) {
  /* 问号钮正下方水平居中，越缘自动翻转；inset/margin 覆盖 UA popover 的居中残留
     （inset:0 + margin auto）。整组守卫：不支持 anchor 时上面两条不生效，浮层仍
     是 UA 默认居中——不会出现「定位在左上角」的坏兜底 */
  .th-pop.pop-rank,
  .th-pop.pop-cross {
    inset: auto; margin: 0;
    position-area: bottom;
    position-try-fallbacks: flip-block flip-inline;
  }
  .th-pop.pop-rank { position-anchor: --q-rank; }
  .th-pop.pop-cross { position-anchor: --q-cross; }
}

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
.row.open { background: var(--accent-bg); }
.cat-tag {
  /* fs-2xs 与行内 .sig 徽章同档：--fs-micro 白名单「不承载实义数据」，分类
     （物资/护甲/配件…）是扫读时的过滤线索、是实义数据，10px 在触屏上已不可辨 */
  font-family: var(--mono); font-size: var(--fs-2xs); color: var(--faint);
  border: 1px solid var(--line2); border-radius: var(--radius-pill);
  padding: 1px 8px; margin-left: 8px; vertical-align: 1px;
}
/* 游戏同款品级底色方框（染底 + 描边），口径同 AmmoMarketView 行内图标 */
.a-icw {
  position: relative;
  display: inline-flex; align-items: center; justify-content: center;
  width: 30px; height: 22px; margin-right: 8px; vertical-align: middle;
  border: 1px solid var(--line);
  border-color: color-mix(in srgb, var(--gd, var(--faint)) 45%, transparent);
  border-radius: 4px;
}
.a-icw.ld {
  background: var(--deep);
  background: color-mix(in srgb, var(--gd, var(--faint)) 15%, var(--deep));
}
.a-ic { width: 26px; height: 18px; object-fit: contain; } /* 加载淡入与占位底见 motion.css（imgReady） */
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
/* 观望降噪（同子弹页 .sig.wait 口径）：本榜单实测常态是观望（6/10 行）——十行里
   六行灰胶囊边框，BUY/SELL/WATCH 彩胶囊反而被淹没（「全员徽章等于没有徽章」，
   与 .cross.anomaly 徽章只给异常态同一条纪律）；去胶囊描边与底、降为素文本，
   彩色胶囊成为信号列唯一扫读锚点。「数据不足」（rank==null）同为 .wait 一并
   降噪，缺失态本就不该有徽章实感；色保持 .sig 基底的 dim（≥6.1:1 不降对比） */
.sig.wait { border-color: transparent; background: none; padding: 2px 0; }
td.profit { color: var(--ok); font-weight: 600; }
/* 现价列：行内最重（主数字立权，预赚/区间均为次级档）+ 位宽钉住——列宽原本
   由行集内容决定，筛选掉最贵行（1,083,727 = 9 字符）后列随收窄，榜单小时级
   轮换换血时整列右对齐数字横跳。min-width 按 7 位数现价预留（10ch ≈ 8 位数
   也容得下）+ 左右 padding，行集怎么变列宽恒定，闪变箭头也被同一余量吸收；
   不支持表格单元 min-width 的老引擎整条丢弃，回到现状 */
.tbl td.price-cell {
  font-size: var(--fs-md); color: var(--tx-strong); font-weight: 700;
  min-width: calc(10ch + 20px);
}

/* ---------- 价格闪变（配脚本 diffPriceFlash）：diff 出的涨/跌格一次性 0.8s 底色
     脉冲（思路库口径；一次性读数脉冲非循环、不占 MOTION.md §5 循环档位），
     动效毕 JS 摘类。箭头是静态等价物——RM 下脉冲关、箭头保留（「涨跌色标保留
     静态等价物」）；keyframes 只声明 from 帧，to 落回单元格自然背景（斑马/hover
     底在 tr 上不冲突）。不支持 color-mix 的引擎 from 帧失效即无脉冲，退回纯箭头 */
@keyframes flash-up { from { background-color: color-mix(in srgb, var(--ok) 14%, transparent); } }
@keyframes flash-down { from { background-color: color-mix(in srgb, var(--danger) 14%, transparent); } }
.price-cell.up { animation: flash-up .8s var(--ease) 1; }
.price-cell.down { animation: flash-down .8s var(--ease) 1; }
.price-cell.up::after,
.price-cell.down::after {
  font-size: 8px; margin-left: 3px; vertical-align: 2px;
}
.price-cell.up::after { content: "▲"; color: var(--ok); }
.price-cell.down::after { content: "▼"; color: var(--danger); }

.cross { font-family: var(--mono); font-size: var(--fs-xs); color: var(--dim); cursor: help; }
/* 双源「重叠不足 24h」行（crossDev == null，显示「重叠 Nh」）：降为 faint——
   「没做双源结论」是数据缺席，与「偏差 0.9%」的实测值同权重渲染会让缺席
   读作「一致」；异常是 warn 徽章、实测是 dim、缺席是 faint，三档一眼可辨 */
.cross.nodata { color: var(--faint); }
/* 双源异常从「变色文字」升格为 warn 微底色块（radius-sm 方角，区别于信号列的
   pill 胶囊——两类标记形态可辨）：扫榜单时异常行不必读数字即可跳出；非异常保持
   纯文字，徽章只给异常态——全员徽章等于没有徽章。rgba 为 color-mix 的引擎兜底
   （同 .sig 家族双写法） */
.cross.anomaly {
  color: var(--warn); font-weight: 600;
  display: inline-flex; align-items: center;
  padding: 2px 8px; border-radius: var(--radius-sm);
  border: 1px solid rgba(227, 178, 94, .4);
  background: rgba(227, 178, 94, .1);
  border-color: color-mix(in srgb, var(--warn) 40%, transparent);
  background: color-mix(in srgb, var(--warn) 10%, transparent);
}

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
  /* transition 列表含 transform：已挂 .press（:active scale .98 全站按压语汇），
     motion.css 约定调用方自带含 transform 的 transition（同 .chip） */
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease),
    transform var(--t-fast) var(--ease);
}
.exp-close:hover,
.exp-close:active { color: var(--tx); border-color: var(--line-hover); }
.exp-note { color: var(--faint); font-size: var(--fs-xs); margin: 10px 2px 2px; line-height: 1.8; }

.src-note { color: var(--faint); font-size: var(--fs-xs); margin-top: var(--sp-4); line-height: 1.8; }
.src-note a { color: var(--accent); }
.src-note a:hover,
.src-note a:active { text-decoration: underline; text-underline-offset: 3px; }

/* ---- 触屏命中区补足（hover:none = 粗指针环境）：可点目标 ≥44px 原则——视觉尺寸
   可以小，命中区不能小。chips/重试/收起用 min-height 补垫层（inline-flex 天然垂直
   居中，胶囊变饱满但不改字号与排布）；搜索框同排落单（真实高约 30px，同是可点
   目标且要弹键盘，命中更该足额——子弹页同思路 chip+search 同块增高）；
   问号钮视觉 14px、伪元素外扩到 44px。桌面（hover 环境）维持原紧凑密度，信息密度不损失 */
@media (hover: none) {
  .chip,
  .retry,
  .exp-close,
  .search { min-height: 44px; }
  .th-q::after { content: ''; position: absolute; inset: -15px; }
}

@media (max-width: 680px) {
  .c-range { display: none; }
  .chip-n { display: none; }
}

/* 本页新增/收紧的微交互过渡统一在 reduce 下关闭（live-dot 的在上面自带）；
   swap/sk/exp/mini-spin/.a-ic 淡入等全局类由 motion.css 文件尾统一兜底，
   此处只管本页 scoped 项 */
@media (prefers-reduced-motion: reduce) {
  .chip, .search, .search-clear, .retry, .exp-close, .row-chev, .dir,
  .th-q, .th-pop { transition: none; } /* th-pop 瞬开瞬关：浮层内容（口径文字）本身是静态语义等价物 */
  .retry:active { transform: none; }
  /* 价格闪变：脉冲关，▲▼ 箭头与涨跌色保留（语义反馈的静态等价物） */
  .price-cell.up, .price-cell.down { animation: none; }
}
</style>
