<script setup>
/* CraftView — 特勤处制造利润（工作台 / 防具台 / 技术中心 / 制药台）
   数据：public/craft/craft.json（server/craft/snapshot.mjs 落盘；上游 moligod
   特勤处快照，利润口径 = 材料现价买入 → 产出按现价×数量挂卖 → 扣手续费）。
   最佳口径（三端一致，见 shared/API.md §1.3）：missingPriceCount === 0 中
   profitPerHour 最大者——制造台同一时间只能跑一条，时利才是真实约束。
   刷新：同源 SSE（craft 事件静默重拉，shared/js/liveChannel.js）+ 60s 轮询
   兜底；数据节奏 = 服务端特勤处循环（默认 10 分钟）。 */
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import { formatVersionLabel, picThumb } from '@shared/js/marketMeta.js'
import { liveChannelUrl, isLocalHttpHost, createLiveChannel } from '@shared/js/liveChannel.js'

const market = ref(null)
const loadState = ref('loading') // loading | ready | empty | error
const loadError = ref('')
const refreshing = ref(false)
const refreshTip = ref('')
const expanded = ref(null)

/* BASE_URL 前缀：子路径静态托管（BASE_URL 非 "/"）下不 404（同子弹页口径） */
const DATA_URL = `${import.meta.env.BASE_URL}craft/craft.json`
const POLL_MS = 60 * 1000
let pollTimer = null
let prevTitle = ''

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
      loadError.value = e instanceof SyntaxError ? '特勤处数据格式异常，请稍后重试' : e.message
      loadState.value = 'error'
    }
  } finally {
    if (seq === loadSeq) refreshing.value = false
  }
}

/* ---------- 数据时效（分钟级源：10min 变灰 / 30min 过期提示） ---------- */
const nowTs = ref(Date.now())
const ageMin = computed(() => {
  const t = Date.parse(market.value?.fetchedAt)
  return Number.isFinite(t) ? (nowTs.value - t) / 60000 : null
})
/* 输出时长（不带「前」）：模板拼接为「数据已 3 小时未更新」——时间点表述会拼出语病 */
const ageLabel = computed(() => {
  if (ageMin.value == null) return ''
  return ageMin.value < 60
    ? `${Math.round(ageMin.value)} 分钟`
    : `${Math.round(ageMin.value / 60)} 小时`
})
const versionLabel = computed(() => formatVersionLabel(market.value?.version))
const STALE_DOT_MIN = 10
const STALE_TIP_MIN = 30

/* ---------- 展示工具 ---------- */
const fmt = (n) => (Number.isFinite(n) ? Math.round(n).toLocaleString('zh-CN') : '—')
const fmtProfit = (n) => (Number.isFinite(n) ? `${n >= 0 ? '+' : ''}${Math.round(n).toLocaleString('zh-CN')}` : '—')
const pct = (n) => (Number.isFinite(n) ? `${n >= 0 ? '+' : ''}${Math.round(n * 100)}%` : '—')
const PLACE_LABEL = { workbench: '工作台', armory: '防具台', tech: '技术中心', pharmacy: '制药台' }
const placeLabel = (p) => PLACE_LABEL[p] || p
const gradeVar = (g) => (g >= 1 && g <= 6 ? `var(--lv${g})` : 'var(--faint)')
const hideImg = (e) => { e.target.style.display = 'none' }

/* ---------- 筛选与排序 ---------- */
const SORTS = [
  { v: 'profitPerHour', label: '时利', dir: 'desc' },
  { v: 'profit', label: '单次利润', dir: 'desc' },
  { v: 'cost', label: '成本', dir: 'asc' },
  { v: 'periodHours', label: '耗时', dir: 'asc' },
]
const state = reactive({ place: 'all', q: '', sort: 'profitPerHour', dir: 'desc', completeOnly: false })

function onSort(v) {
  const def = SORTS.find((s) => s.v === v)
  if (state.sort !== v) {
    state.sort = v
    state.dir = def.dir
  } else {
    state.dir = state.dir === 'asc' ? 'desc' : 'asc'
  }
}
function setPlace(p) {
  state.place = p
  expanded.value = null
}
function clearFilters() {
  state.place = 'all'
  state.q = ''
  state.completeOnly = false
}
function onRowKeydown(e, id) {
  if (e.target !== e.currentTarget) return
  e.preventDefault()
  expanded.value = expanded.value === id ? null : id
}

const items = computed(() => market.value?.items || [])
const placeCounts = computed(() => {
  const c = {}
  for (const i of items.value) c[i.place] = (c[i.place] || 0) + 1
  return c
})
/** 缺价 / 缺时利的条目排在队尾（num 哨兵随方向感知），保证榜单头部都是可决策行 */
const filtered = computed(() => {
  let list = items.value
  if (state.place !== 'all') list = list.filter((i) => i.place === state.place)
  if (state.completeOnly) list = list.filter((i) => i.missingPriceCount === 0)
  if (state.q.trim()) {
    const q = state.q.trim().toLowerCase()
    list = list.filter(
      (i) =>
        i.output.name.toLowerCase().includes(q) ||
        i.materials.some((m) => m.name.toLowerCase().includes(q)),
    )
  }
  const num = (x) => (Number.isFinite(x) ? x : state.dir === 'asc' ? Infinity : -Infinity)
  const m = state.dir === 'asc' ? 1 : -1
  const sorters = {
    profitPerHour: (a, b) => (num(a.profitPerHour) - num(b.profitPerHour)) * m,
    profit: (a, b) => (num(a.profit) - num(b.profit)) * m,
    cost: (a, b) => (num(a.cost) - num(b.cost)) * m,
    periodHours: (a, b) => (num(a.periodHours) - num(b.periodHours)) * m,
  }
  return [...list].sort(sorters[state.sort] || sorters.profitPerHour)
})
/** 时利条的最大绝对值（条形图归一化基准，跨正负） */
const maxHourly = computed(() =>
  filtered.value.reduce((mx, i) => Math.max(mx, Math.abs(i.profitPerHour || 0)), 1),
)

/* ---------- 最佳（口径：完整价 + 时利最大；hero 跟随制造台筛选） ---------- */
function bestOf(list) {
  return list
    .filter((i) => i.missingPriceCount === 0 && i.profitPerHour != null)
    .sort((a, b) => b.profitPerHour - a.profitPerHour)[0] || null
}
const best = computed(() => {
  const pool = state.place === 'all' ? items.value : items.value.filter((i) => i.place === state.place)
  return bestOf(pool)
})
/** 各台最佳：四张速览卡 + 点击直达筛选 */
const placeBests = computed(() => {
  const out = []
  for (const p of market.value?.places || []) {
    out.push({ place: p.id, label: p.label, item: bestOf(items.value.filter((i) => i.place === p.id)) })
  }
  return out
})

/* ---------- 实时通道（同源 SSE；craft 事件静默重拉） ---------- */
const LIVE_SSE_URL = liveChannelUrl(location)
const liveChannel = ref('off') // off | connecting | on | down
let live = null
const liveTip = computed(
  () => ({
    on: '实时推送已连接，利润自动更新',
    down: '实时推送已断开，自动重连中；期间每 60 秒自动刷新',
    connecting: '实时推送连接中…',
  }[liveChannel.value] || '')
)
function connectLive() {
  if (!LIVE_SSE_URL) return
  live = createLiveChannel({
    url: LIVE_SSE_URL,
    events: ['craft'],
    isLocal: () => isLocalHttpHost(location),
    onState: (s) => { liveChannel.value = s },
    onEvent: (t) => { if (t === 'craft') load({ silent: true }) },
  })
  live.start()
}
function onVisibility() {
  if (document.hidden) return
  nowTs.value = Date.now()
  load({ silent: true })
}

onMounted(() => {
  prevTitle = document.title
  document.title = '三角洲行动 · 特勤处制造利润'
  load()
  connectLive()
  pollTimer = setInterval(() => {
    if (document.hidden) return
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
  <div class="wrap page">
    <header class="compact-head">
      <h1>特勤处制造 <span class="live-dot" :class="{ stale: ageMin !== null && ageMin > STALE_DOT_MIN }" aria-hidden="true"></span></h1>
      <p v-if="market" class="meta" :title="`数据版本 ${versionLabel}${liveTip ? ' · ' + liveTip : ''}`">
        配方 {{ market.stats.total }} · 价格完整 {{ market.stats.complete }}
      </p>
    </header>

    <p v-if="ageMin !== null && ageMin > STALE_TIP_MIN" class="state-tip stale-tip" role="status">
      数据已 {{ ageLabel }}未更新，利润估算可能已变化，可稍后回来查看。
    </p>
    <p v-if="loadState === 'loading'" class="state-tip" role="status">正在加载特勤处制造数据…</p>
    <div v-else-if="loadState === 'empty'" class="state-card">
      <p>还没有特勤处制造数据。</p>
      <p class="dim">快照正在准备中，稍后再来看看。</p>
      <button class="retry" @click="load()">重试</button>
    </div>
    <div v-else-if="loadState === 'error'" class="state-card">
      <p>特勤处制造数据加载失败：{{ loadError }}</p>
      <button class="retry" @click="load()">重试</button>
    </div>

    <template v-if="loadState === 'ready'">
      <!-- 今日时利最佳（跟随制造台筛选）：主数字立权 + 材料速览 -->
      <section v-if="best" class="hero" :aria-label="`时利最佳：${best.output.name}`">
        <div class="hero-top">
          <p class="hero-kicker"><i class="hero-diamond" aria-hidden="true"></i>时利最佳<span v-if="state.place !== 'all'" class="hero-scope"> · {{ placeLabel(best.place) }}</span></p>
          <div class="hero-chips">
            <span class="tag">{{ placeLabel(best.place) }}</span>
            <span v-if="best.requiredLevel != null" class="tag">Lv.{{ best.requiredLevel }} 解锁</span>
            <span class="tag tag-fee">手续费 {{ Math.round((best.feeRate ?? 0) * 100) }}%</span>
          </div>
        </div>
        <div class="hero-main">
          <span class="a-icw hero-icw" aria-hidden="true">
            <img
              v-if="best.output.pic" class="a-ic hero-ic"
              :src="picThumb(best.output.pic, 144)" alt=""
              width="56" height="40" loading="lazy" decoding="async"
              @error="hideImg"
            >
            <i class="a-gd hero-gd" :style="{ background: gradeVar(best.output.grade) }" :title="`品级 ${best.output.grade}`"></i>
          </span>
          <div class="hero-name">
            <h2>{{ best.output.name }}<span v-if="best.output.count > 1" class="hero-count"> ×{{ best.output.count }}</span></h2>
            <p class="hero-sub">产出单价 {{ fmt(best.output.price) }}<template v-if="best.output.count > 1"> × {{ best.output.count }} 件</template>，按现价挂卖估算</p>
          </div>
          <div class="hero-figure">
            <p class="hero-num" :class="{ loss: best.profit < 0 }">{{ fmtProfit(best.profitPerHour) }}</p>
            <p class="hero-unit">哈夫币 / 小时</p>
          </div>
        </div>
        <dl class="hero-stats">
          <div><dt>单次净利润</dt><dd :class="{ loss: best.profit < 0 }">{{ fmtProfit(best.profit) }}</dd></div>
          <div><dt>材料成本</dt><dd>{{ fmt(best.cost) }}</dd></div>
          <div><dt>制造耗时</dt><dd>{{ best.periodLabel || '—' }}</dd></div>
          <div><dt>成本回报</dt><dd :class="{ loss: best.roi < 0 }">{{ pct(best.roi) }}</dd></div>
        </dl>
        <div class="hero-mats" aria-label="材料清单">
          <button
            v-for="m in best.materials" :key="m.name"
            class="mat-chip" type="button"
            title="点击在榜单中搜索该材料"
            @click="state.q = m.name"
          >
            <img v-if="m.pic" class="mat-ic" :src="picThumb(m.pic, 48)" alt="" width="16" height="16" loading="lazy" decoding="async" @error="hideImg">
            <span class="mat-name">{{ m.name }}</span>
            <span v-if="m.count > 1" class="mat-count">×{{ m.count }}</span>
            <span class="mat-cost" :class="{ miss: m.price == null }">{{ m.price == null ? '无价' : fmt(m.cost) }}</span>
          </button>
        </div>
      </section>

      <!-- 各台最佳速览：点击直达该台筛选 -->
      <nav class="place-grid" aria-label="各制造台最佳">
        <button
          v-for="pb in placeBests" :key="pb.place"
          class="place-card" :class="{ on: state.place === pb.place }"
          :aria-pressed="state.place === pb.place"
          @click="setPlace(state.place === pb.place ? 'all' : pb.place)"
        >
          <p class="pc-label">{{ pb.label }}最佳</p>
          <template v-if="pb.item">
            <p class="pc-name">{{ pb.item.output.name }}</p>
            <p class="pc-nums">
              <span class="pc-hour" :class="{ loss: pb.item.profit < 0 }">{{ fmt(pb.item.profitPerHour) }}/h</span>
              <span class="pc-sub">{{ pb.item.periodLabel }} · 利润 {{ fmt(pb.item.profit) }}</span>
            </p>
          </template>
          <p v-else class="pc-empty">价格数据不足</p>
        </button>
      </nav>

      <!-- 榜单板块头（兄弟页 .block-h 惯例）：筛选命中数就地可见——当前页面无任何
           「筛出了几条」的反馈，筛选后只能靠数行数 -->
      <div class="block-h">
        <span class="bht">ALL RECIPES</span><span class="bhline"></span>
        <span class="bhc">{{ filtered.length }} / {{ items.length }} 条</span>
      </div>

      <!-- 控制条 -->
      <div class="ctl-bar">
        <div class="chips" role="group" aria-label="制造台筛选">
          <button
            class="chip" :class="{ on: state.place === 'all' }"
            :aria-pressed="state.place === 'all'"
            @click="setPlace('all')"
          >全部<span class="chip-n">{{ items.length }}</span></button>
          <button
            v-for="p in market.places" :key="p.id"
            class="chip" :class="{ on: state.place === p.id }"
            :aria-pressed="state.place === p.id"
            @click="setPlace(p.id)"
          >{{ p.label }}<span class="chip-n">{{ placeCounts[p.id] || 0 }}</span></button>
        </div>
        <input v-model.trim="state.q" class="search" type="search" placeholder="搜索产物 / 材料" aria-label="搜索产物或材料" />
        <div class="chips" role="group" aria-label="排序">
          <button
            v-for="s in SORTS" :key="s.v"
            class="chip" :class="{ on: state.sort === s.v }"
            :aria-pressed="state.sort === s.v"
            :title="state.sort === s.v
              ? `当前${state.dir === 'desc' ? '降序' : '升序'}，再点切换方向`
              : null"
            @click="onSort(s.v)"
            >{{ s.label }}<svg v-if="state.sort === s.v" class="dir" viewBox="0 0 16 16" aria-hidden="true"><path v-if="state.dir === 'desc'" d="M8 3.5v9M4.5 9 8 12.5 11.5 9" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/><path v-else d="M8 12.5v-9M4.5 7 8 3.5 11.5 7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
        </div>
        <button
          class="chip" :class="{ on: state.completeOnly }"
          :aria-pressed="state.completeOnly"
          @click="state.completeOnly = !state.completeOnly"
        >只看价格完整</button>
        <button class="chip refresh" :disabled="refreshing" title="重新拉取最新快照" @click="load({ silent: true })">{{ refreshing ? '刷新中…' : '刷新' }}</button>
      </div>
      <p v-if="refreshTip" class="refresh-tip warn" role="status">{{ refreshTip }}</p>

      <!-- 利润榜单 -->
      <div class="tbl-scroll">
        <table class="tbl">
          <thead>
            <tr>
              <th class="num">#</th>
              <th>产物</th>
              <th class="c-place">制造台</th>
              <th class="num">耗时</th>
              <th class="num">材料成本</th>
              <th class="num">净利润</th>
              <th class="num">时利 / 小时</th>
              <th class="num c-today" title="今日按现价估算的最高利润（乐观参照，非承诺）">今日最高</th>
            </tr>
          </thead>
          <tbody>
            <template v-for="(i, idx) in filtered" :key="i.id">
              <tr
                class="row" :class="{ open: expanded === i.id, odd: idx % 2 === 0, even: idx % 2 === 1 }"
                tabindex="0"
                :aria-expanded="expanded === i.id"
                @click="expanded = expanded === i.id ? null : i.id"
                @keydown.enter="onRowKeydown($event, i.id)"
                @keydown.space="onRowKeydown($event, i.id)"
              >
                <td class="mono dimtx num">{{ idx + 1 }}</td>
                <td>
                  <span class="a-icw" aria-hidden="true">
                    <img
                      v-if="i.output.pic" class="a-ic"
                      :src="picThumb(i.output.pic, 96)" alt=""
                      width="26" height="18" loading="lazy" decoding="async"
                      @error="hideImg"
                    >
                    <i class="a-gd" :style="{ background: gradeVar(i.output.grade) }" :title="`品级 ${i.output.grade}`"></i>
                  </span>
                  <span class="a-name">{{ i.output.name }}</span>
                  <span v-if="i.output.count > 1" class="a-count">×{{ i.output.count }}</span>
                  <span v-if="i.missingPriceCount > 0" class="miss-tag" :title="`${i.missingPriceCount} 项材料或产出缺价，利润无法估算`">价格缺失</span>
                  <i class="row-chev" aria-hidden="true"><svg viewBox="0 0 16 16" width="10" height="10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 6 L8 10.5 L12.5 6"/></svg></i>
                </td>
                <td class="c-place"><span class="place-tag">{{ placeLabel(i.place) }}<span v-if="i.requiredLevel != null" class="place-lv"> Lv.{{ i.requiredLevel }}</span></span></td>
                <td class="mono dimtx num">{{ i.periodLabel || '—' }}</td>
                <td class="mono dimtx num">{{ i.missingPriceCount ? '—' : fmt(i.cost) }}</td>
                <td class="mono num profit-cell" :class="{ pos: i.profit > 0, neg: i.profit < 0 }">{{ i.missingPriceCount ? '—' : fmtProfit(i.profit) }}</td>
                <td class="num">
                  <div class="hourly-cell">
                    <!-- 缺价配方的服务端字段是 0 而非 null（契约 §1.3 降级展示）：
                         与成本 / 利润列同款以 missingPriceCount 为门槛，不显示假「0」 -->
                    <span v-if="i.profitPerHour != null && !i.missingPriceCount" class="mono hourly-num" :class="{ pos: i.profitPerHour > 0, neg: i.profitPerHour < 0 }">{{ fmt(i.profitPerHour) }}</span>
                    <span v-else class="mono dimtx">—</span>
                    <div v-if="i.profitPerHour && !i.missingPriceCount" class="hourly-bar" aria-hidden="true">
                      <i
                        class="hb-fill"
                        :class="{ neg: i.profitPerHour < 0 }"
                        :style="{ width: `${Math.max(3, Math.round((Math.abs(i.profitPerHour) / maxHourly) * 100))}%` }"
                      ></i>
                    </div>
                  </div>
                </td>
                <!-- 同 408 行时利列：缺价行 todayMaxProfit 服务端降级为 0 而非 null，
                     按 missingPriceCount 门槛显示 —，不与成本/净利润/时利三列口径打架 -->
                <td class="mono dimtx num c-today" :title="'今日按现价估算的最高利润（乐观参照，非承诺）'">{{ i.todayMaxProfit != null && !i.missingPriceCount ? fmt(i.todayMaxProfit) : '—' }}</td>
              </tr>
              <tr v-if="expanded === i.id" class="expander">
                <td colspan="8">
                  <button class="exp-close" @click="expanded = null">收起</button>
                  <div class="exp-mats">
                    <p class="exp-title">材料清单</p>
                    <ul class="mat-list">
                      <li v-for="m in i.materials" :key="m.name">
                        <img v-if="m.pic" class="mat-ic" :src="picThumb(m.pic, 48)" alt="" width="16" height="16" loading="lazy" decoding="async" @error="hideImg">
                        <span class="mat-name">{{ m.name }}</span>
                        <span class="mat-count">×{{ m.count }}</span>
                        <span class="mat-price mono">{{ m.price == null ? '无价' : `单价 ${fmt(m.price)}` }}</span>
                        <!-- 无价材料 cost 服务端为 0：与左侧「无价」呼应显示 —，避免把 0 当真实成本 -->
                        <span class="mat-cost mono">{{ m.price == null ? '—' : fmt(m.cost) }}</span>
                      </li>
                    </ul>
                  </div>
                  <p v-if="i.missingPriceCount === 0" class="exp-formula mono">
                    产出收入 {{ fmt(i.revenue) }}（{{ fmt(i.output.price) }} × {{ i.output.count }}）
                    − 材料成本 {{ fmt(i.cost) }}
                    − 手续费 {{ fmt(i.fee) }}（{{ Math.round((i.feeRate ?? 0) * 100) }}%）
                    = 净利润 <b :class="{ neg: i.profit < 0 }">{{ fmtProfit(i.profit) }}</b>
                  </p>
                  <!-- 缺价行的产出单价 / 7 日最高利润服务端均为 0 而非 null：0 与 null 同等降级为 —，
                       避免「利润无法估算」旁边站着假数字 0（完整行不受影响，可照常显示含 0/负值） -->
                  <p v-else class="exp-formula dimtx">有 {{ i.missingPriceCount }} 项材料或产出缺价，利润无法估算；产出单价 {{ i.output.price > 0 ? fmt(i.output.price) : '—' }}。</p>
                  <p class="exp-note">
                    估算口径：材料按现价全部买入、产出按现价即时挂卖并扣手续费；制造期间价格波动、挂单深度与实际成交均会造成偏差。
                    7 日最高利润 {{ !i.missingPriceCount && i.sevenDayMaxProfit != null ? fmt(i.sevenDayMaxProfit) : '—' }} 为乐观参照，不构成承诺。
                  </p>
                </td>
              </tr>
            </template>
            <tr v-if="!filtered.length">
              <td colspan="8" class="empty-cell">没有符合当前筛选的配方　<button class="retry" @click="clearFilters">清除全部筛选</button></td>
            </tr>
          </tbody>
        </table>
      </div>

      <p class="src-note">
        覆盖工作台 / 防具台 / 技术中心 / 制药台全量配方（含制造台等级解锁与耗时）；
        利润为按分钟级现价的实时估算，最佳口径 = 价格完整的配方中「每小时利润」最高（制造台同一时间只能跑一条，时利才是真实约束）。
        买卖深度与限价挂单以游戏内为准。
      </p>
    </template>
  </div>
</template>

<style scoped>
.page { padding-bottom: var(--sp-10); }

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
.stale-tip { color: var(--warn); }
.state-card {
  background: var(--card); border: 1px dashed var(--line2); border-radius: var(--radius);
  padding: var(--sp-6); color: var(--tx); margin: var(--sp-4) 0;
}
.state-card .dim { color: var(--faint); font-size: var(--fs-sm); }
.retry {
  background: var(--accent-bg); color: var(--accent); border: 1px solid var(--accent-dim);
  border-radius: var(--radius); padding: 6px 18px; cursor: pointer; font-size: var(--fs-sm);
  transition: background-color var(--t-med) var(--ease), transform var(--t-fast) var(--ease);
}
.retry:hover { background: var(--accent-soft); }
.retry:active { background: var(--accent-soft); transform: scale(.98); }
.empty-cell { text-align: center; color: var(--dim); padding: var(--sp-6) 0; }

/* ---------- 时利最佳主卡 ---------- */
.hero {
  position: relative;
  background: var(--card);
  border: 1px solid var(--accent-dim);
  border-radius: var(--radius-lg);
  padding: var(--sp-4) var(--sp-5) var(--sp-4);
  margin: var(--sp-5) 0 var(--sp-4);
  box-shadow: var(--edge-light);
  overflow: hidden;
}
/* 顶缘强调：主色 1px 渐变线，确立「最佳」的唯一性（全站唯一强调色的克制用法） */
.hero::before {
  content: "";
  position: absolute; top: 0; left: 0; right: 0; height: 2px;
  background: linear-gradient(90deg, transparent, var(--accent), transparent);
}
.hero-top {
  display: flex; align-items: center; justify-content: space-between;
  gap: var(--sp-4); flex-wrap: wrap;
}
.hero-kicker {
  display: inline-flex; align-items: center; gap: 8px;
  font-family: var(--mono); font-size: var(--fs-2xs); letter-spacing: .18em;
  color: var(--accent);
}
.hero-diamond {
  width: 7px; height: 7px; background: var(--accent);
  transform: rotate(45deg);
  box-shadow: 0 0 8px rgba(45, 212, 191, .4);
}
.hero-scope { color: var(--dim); letter-spacing: .08em; }
.hero-chips { display: flex; gap: 6px; flex-wrap: wrap; }
.tag {
  font-family: var(--mono); font-size: var(--fs-micro); color: var(--dim);
  border: 1px solid var(--line2); border-radius: var(--radius-pill);
  padding: 2px 9px; letter-spacing: .06em;
}
.tag-fee { color: var(--faint); }
.hero-main {
  display: flex; align-items: center; gap: var(--sp-4);
  margin-top: var(--sp-3); flex-wrap: wrap;
}
.hero-icw { width: 60px; height: 44px; }
.hero-ic { width: 56px; height: 40px; }
.hero-gd { left: -5px; bottom: -4px; width: 7px; height: 7px; }
.hero-name { min-width: 0; flex: 1; }
.hero-name h2 {
  font-size: var(--fs-xl); color: var(--tx-strong); font-weight: 700;
  line-height: var(--lh-tight); letter-spacing: .01em;
  overflow-wrap: anywhere;
}
.hero-count { font-family: var(--mono); font-size: var(--fs-md); color: var(--dim); font-weight: 600; margin-left: 4px; }
.hero-sub { color: var(--faint); font-size: var(--fs-xs); margin-top: 4px; }
.hero-figure { margin-left: auto; text-align: right; }
.hero-num {
  font-family: var(--mono); font-size: var(--fs-display); font-weight: 700;
  color: var(--ok); line-height: 1; letter-spacing: -.01em;
  font-variant-numeric: tabular-nums;
}
.hero-num.loss, .loss { color: var(--danger); }
.hero-unit { color: var(--faint); font-size: var(--fs-xs); margin-top: 6px; letter-spacing: .1em; }
.hero-stats {
  display: grid; grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: var(--sp-3); margin-top: var(--sp-4);
  border-top: 1px solid var(--line2); padding-top: var(--sp-3);
}
.hero-stats dt { color: var(--faint); font-size: var(--fs-micro); letter-spacing: .08em; margin-bottom: 3px; }
.hero-stats dd {
  font-family: var(--mono); font-size: var(--fs-md); font-weight: 600;
  color: var(--tx-strong); font-variant-numeric: tabular-nums;
}
.hero-stats dd.loss { color: var(--danger); }
.hero-mats { display: flex; flex-wrap: wrap; gap: 6px; margin-top: var(--sp-3); }
.mat-chip {
  display: inline-flex; align-items: center; gap: 6px;
  background: var(--bg2); border: 1px solid var(--line);
  border-radius: var(--radius-pill); padding: 3px 10px;
  color: var(--tx); font-size: var(--fs-xs); cursor: pointer;
  transition: border-color var(--t-fast) var(--ease), color var(--t-fast) var(--ease);
}
.mat-chip:hover, .mat-chip:active { border-color: var(--line-hover); color: var(--tx-strong); }
.mat-name { white-space: nowrap; }
.mat-count { font-family: var(--mono); color: var(--dim); }
.mat-cost { font-family: var(--mono); color: var(--faint); }
.mat-cost.miss { color: var(--warn); }

/* ---------- 各台最佳速览 ---------- */
.place-grid {
  display: grid; grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: var(--sp-3); margin-bottom: var(--sp-4);
}
.place-card {
  text-align: left; background: var(--card); border: 1px solid var(--line);
  border-radius: var(--radius-lg); padding: var(--sp-3) var(--sp-4);
  cursor: pointer; box-shadow: var(--edge-light);
  transition: border-color var(--t-fast) var(--ease), transform var(--t-fast) var(--ease);
}
.place-card:hover, .place-card:active { border-color: var(--line-hover); transform: translateY(-1px); }
.place-card.on { border-color: var(--accent-dim); background: var(--accent-bg); }
.pc-label {
  font-family: var(--mono); font-size: var(--fs-micro); color: var(--faint);
  letter-spacing: .12em; margin-bottom: 6px;
}
.place-card.on .pc-label { color: var(--accent); }
.pc-name {
  color: var(--tx-strong); font-size: var(--fs-sm); font-weight: 600;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.pc-nums { margin-top: 4px; display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; }
.pc-hour {
  font-family: var(--mono); font-size: var(--fs-md); font-weight: 700;
  color: var(--ok); font-variant-numeric: tabular-nums;
}
.pc-hour.loss { color: var(--danger); }
.pc-sub { font-family: var(--mono); font-size: var(--fs-micro); color: var(--faint); }
.pc-empty { color: var(--faint); font-size: var(--fs-xs); margin-top: 4px; }
@media (max-width: 900px) { .place-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
@media (max-width: 480px) { .place-grid { grid-template-columns: 1fr; } }

/* ---------- 控制条 ---------- */
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
.chip-n { font-family: var(--mono); color: var(--faint); }
.chip.refresh { margin-left: auto; }
.chip.refresh:disabled { opacity: .6; cursor: default; }
.dir { width: 10px; height: 10px; margin-left: 2px; color: var(--accent); flex: none; }
.refresh-tip { font-family: var(--mono); font-size: var(--fs-xs); margin: 0 0 var(--sp-3); }
.refresh-tip.warn { color: var(--warn); }
.search {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  color: var(--tx); font-size: var(--fs-xs); padding: 5px 14px; width: 160px;
  font-family: var(--sans);
  transition: border-color var(--t-fast) var(--ease);
}
.search:focus { border-color: var(--accent-dim); }

/* ---------- 榜单表 ---------- */
.tbl-scroll {
  overflow-x: auto;
  border: 1px solid var(--line);
  border-radius: var(--radius);
}
.tbl-scroll .tbl { min-width: 960px; }
.row { cursor: pointer; }
.row.odd { background: transparent; }
.row.even { background: var(--zebra); }
.row:hover,
.row:focus-visible { background: var(--row-hover); }
.row.open { background: var(--accent-bg); box-shadow: inset 2px 0 0 var(--accent-dim); }
.a-icw {
  position: relative;
  display: inline-flex; align-items: center; justify-content: center;
  width: 28px; height: 18px; margin-right: 8px; vertical-align: middle;
}
.a-ic { width: 26px; height: 18px; object-fit: contain; opacity: .92; }
.a-gd {
  position: absolute; left: -4px; bottom: -3px;
  width: 6px; height: 6px; transform: rotate(45deg);
  box-shadow: 0 0 0 2px var(--card);
}
.a-name { color: var(--tx-strong); white-space: nowrap; }
.a-count { font-family: var(--mono); font-size: var(--fs-xs); color: var(--dim); margin-left: 4px; }
.miss-tag {
  font-family: var(--mono); font-size: var(--fs-micro); color: var(--warn);
  border: 1px solid color-mix(in srgb, var(--warn) 40%, transparent);
  background: color-mix(in srgb, var(--warn) 10%, transparent);
  border-radius: var(--radius-pill); padding: 1px 8px; margin-left: 8px; vertical-align: 1px;
  white-space: nowrap;
}
.place-tag {
  font-family: var(--mono); font-size: var(--fs-xs); color: var(--dim); white-space: nowrap;
}
.place-lv { color: var(--faint); }
.row-chev {
  display: inline-flex; align-items: center; color: var(--faint);
  margin-left: 6px;
  transition: transform var(--t-fast) var(--ease), color var(--t-fast) var(--ease);
}
.row-chev svg { display: block; }
.row.open .row-chev { transform: rotate(180deg); color: var(--accent); }

td.profit-cell { font-weight: 600; }
td.profit-cell.pos { color: var(--ok); }
td.profit-cell.neg { color: var(--danger); }
/* 时利列是默认排序依据（行内主数字）：字号升一档对齐兄弟页 price-cell 的主列惯例
   （压过 base.css .tbl .mono 的 fs-xs；已带 700 字重与正负语义色） */
td .hourly-num { font-size: var(--fs-md); }
.hourly-cell { display: flex; align-items: center; justify-content: flex-end; gap: 8px; }
.hourly-num { font-weight: 700; font-variant-numeric: tabular-nums; }
.hourly-num.pos { color: var(--ok); }
.hourly-num.neg { color: var(--danger); }
.hourly-bar {
  position: relative; width: 72px; height: 5px;
  background: var(--line2); border-radius: 3px; overflow: hidden;
}
.hb-fill {
  position: absolute; inset: 0 auto 0 0; border-radius: 3px;
  background: linear-gradient(90deg, color-mix(in srgb, var(--ok) 40%, transparent), var(--ok));
}
.hb-fill.neg {
  background: linear-gradient(90deg, color-mix(in srgb, var(--danger) 40%, transparent), var(--danger));
}

/* ---------- 展开明细 ---------- */
.expander td { position: relative; background: var(--card2); border-top: 1px solid var(--accent-dim); }
.exp-close {
  position: absolute; top: 10px; right: 10px;
  font-family: var(--mono); font-size: var(--fs-2xs); color: var(--dim);
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  padding: 3px 12px; cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
}
.exp-close:hover,
.exp-close:active { color: var(--tx); border-color: var(--line-hover); }
.exp-title {
  font-family: var(--mono); font-size: var(--fs-2xs); color: var(--accent);
  letter-spacing: .14em; margin-bottom: 8px;
}
.mat-list { list-style: none; display: flex; flex-direction: column; gap: 5px; max-width: 560px; }
.mat-list li {
  display: flex; align-items: center; gap: 8px;
  padding: 4px 10px; background: var(--bg2); border: 1px solid var(--line2);
  border-radius: var(--radius);
  font-size: var(--fs-sm);
}
.mat-list .mat-name { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.mat-list .mat-count { font-family: var(--mono); color: var(--dim); font-size: var(--fs-xs); }
.mat-list .mat-price { color: var(--faint); font-size: var(--fs-xs); white-space: nowrap; }
.mat-list .mat-cost { color: var(--tx-strong); font-size: var(--fs-sm); font-variant-numeric: tabular-nums; min-width: 64px; text-align: right; }
.exp-formula { margin-top: 10px; color: var(--tx); font-size: var(--fs-sm); line-height: 1.8; }
.exp-formula b.neg { color: var(--danger); }
.exp-formula.dimtx { color: var(--dim); }
.exp-note { color: var(--faint); font-size: var(--fs-xs); margin: 8px 2px 2px; line-height: 1.8; }

.src-note { color: var(--faint); font-size: var(--fs-xs); margin-top: var(--sp-4); line-height: 1.8; }

@media (max-width: 1000px) { .c-today { display: none; } }
@media (max-width: 680px) {
  .c-place { display: none; }
  .chip-n { display: none; }
  .hero-figure { margin-left: 0; text-align: left; width: 100%; }
  /* 4 格统计在窄屏压至 ~70px/格，数字贴边：折 2×2 */
  .hero-stats { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  /* iOS Safari 聚焦字号 <16px 的输入会整页自动放大（同 AmmoMarketView 口径） */
  .search { font-size: var(--fs-lg); }
}

@media (prefers-reduced-motion: reduce) {
  .chip, .search, .retry, .exp-close, .row-chev, .place-card, .mat-chip { transition: none; }
  .retry:active, .place-card:hover, .place-card:active { transform: none; }
}
</style>
