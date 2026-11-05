<script setup>
/* TradeHouseView — 交易行全览（复刻自 moligod「交易行」）
   数据：public/market/tradehouse.json（server/market/tradehouse.mjs 落盘，
   上游 moligod trade-house-snapshot，AES-256-GCM 公开传输编码在服务端解码）。
   全市场 ~1750 件的现价 / 昨日均价 / 7 日区间浏览：品类 segmented +
   子品类 chips + 品级筛选 + 搜索 + 排序 + 分页（120/页，避免 1700+ 行 DOM）。
   24h% = 现价 / 昨日均价 − 1（昨日均价是滚动窗口均值，作涨跌参照）。 */
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import SkeletonView from '../components/SkeletonView.vue'
import { imgReady, hideImg } from '../composables/imgReady'
import { useSnapshotFeed } from '../composables/useSnapshotFeed'
import { fmt, pct, gradeVar } from '../utils/format.js'
import { picThumb } from '@shared/js/marketMeta.js'

const rootEl = ref(null)
let prevTitle = ''

const {
  market, loadState, loadError, refreshing,
  load,
} = useSnapshotFeed(`${import.meta.env.BASE_URL}market/tradehouse.json`, {
  events: ['tradehouse'],
  syntaxError: '交易行数据格式异常，请稍后重试',
  successTip: false,
})

const items = computed(() => market.value?.items || [])

/* ---------- 筛选 / 排序 / 分页 ---------- */
const PAGE_SIZE = 120
const CATS = [
  { v: 'all', label: '全部' },
  { v: 'ammo', label: '子弹' },
  { v: 'acc', label: '配件' },
  { v: 'gun', label: '枪械' },
  { v: 'props', label: '物品' },
  { v: 'protect', label: '防具' },
]
const SORTS = [
  { v: 'current', label: '现价', dir: 'desc' },
  { v: 'chg24h', label: '24h 涨跌', dir: 'desc' },
  { v: 'sevenLow', label: '7日低位', dir: 'asc' },
  { v: 'grade', label: '品级', dir: 'desc' },
]
const state = reactive({ cat: 'all', sub: 'all', grade: 0, q: '', sort: 'current', dir: 'desc', page: 0 })
const pageRef = ref(0)

const subs = computed(() => {
  const m = new Map()
  for (const it of items.value) {
    if (state.cat !== 'all' && it.category !== state.cat) continue
    const s = it.subcategory
    if (!s || s === '-') continue
    m.set(s, (m.get(s) || 0) + 1)
  }
  return [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, 24)
})

function setCat(c) {
  state.cat = c
  state.sub = 'all'
  state.page = 0
}
function onSort(v) {
  const def = SORTS.find((s) => s.v === v)
  if (state.sort !== v) {
    state.sort = v
    state.dir = def.dir
  } else {
    state.dir = state.dir === 'asc' ? 'desc' : 'asc'
  }
  state.page = 0
}

const chgOf = (it) =>
  it.current > 0 && it.yesterdayAvg > 0 ? it.current / it.yesterdayAvg - 1 : null

const filtered = computed(() => {
  let list = items.value
  if (state.cat !== 'all') list = list.filter((i) => i.category === state.cat)
  if (state.sub !== 'all') list = list.filter((i) => i.subcategory === state.sub)
  if (state.grade) list = list.filter((i) => i.grade === state.grade)
  const q = state.q.trim().toLowerCase()
  if (q) list = list.filter((i) => i.name.toLowerCase().includes(q) || (i.alias || '').toLowerCase().includes(q))
  const num = (x) => (Number.isFinite(x) ? x : state.dir === 'asc' ? Infinity : -Infinity)
  const m = state.dir === 'asc' ? 1 : -1
  const sorters = {
    current: (a, b) => (num(a.current) - num(b.current)) * m,
    chg24h: (a, b) => (num(chgOf(a)) - num(chgOf(b))) * m,
    sevenLow: (a, b) => (num(a.sevenDayLow) - num(b.sevenDayLow)) * m,
    grade: (a, b) => (num(a.grade) - num(b.grade)) * m,
  }
  return [...list].sort(sorters[state.sort] || sorters.current)
})
const pageCount = computed(() => Math.max(1, Math.ceil(filtered.value.length / PAGE_SIZE)))
const pageItems = computed(() => {
  const p = Math.min(state.page, pageCount.value - 1)
  return filtered.value.slice(p * PAGE_SIZE, p * PAGE_SIZE + PAGE_SIZE)
})
function goPage(d) {
  state.page = Math.min(pageCount.value - 1, Math.max(0, state.page + d))
}

const chgCls = (c) => (c == null ? 'dim' : c > 0 ? 'up' : c < 0 ? 'down' : 'dim')
/* 7 日区间位置（0=贴低 1=贴高）：现价在 [7dLow, 7dHigh] 的分位 */
const rangePos = (it) => {
  if (!(it.current > 0) || !(it.sevenDayHigh > it.sevenDayLow)) return null
  return Math.min(1, Math.max(0, (it.current - it.sevenDayLow) / (it.sevenDayHigh - it.sevenDayLow)))
}

const updatedLabel = computed(() => {
  const v = String(market.value?.version || '')
  return v.length === 12 ? `${v.slice(4, 6)}-${v.slice(6, 8)} ${v.slice(8, 10)}:${v.slice(10, 12)}` : ''
})

/* 本页无级联入场：120/页分页换行会让新 .reveal 行卡在透明态（IO 批次不随
   分页重挂），页级淡入已由路由过渡承担 */

onMounted(() => {
  prevTitle = document.title
  document.title = '三角洲行动 · 交易行全览'
})
onBeforeUnmount(() => {
  document.title = prevTitle
})
</script>

<template>
  <div ref="rootEl" class="wrap page">
    <header class="compact-head">
      <h1>交易行全览</h1>
      <p v-if="market" class="meta" :title="`数据版本 ${market.version}`">
        全市场 {{ market.stats.total }} 件（有价 {{ market.stats.priced }}） · 更新于 {{ updatedLabel }}
      </p>
    </header>

    <Transition name="swap" mode="out-in">
      <div v-if="loadState === 'loading'" key="loading" class="state-root sk-hold">
        <SkeletonView variant="table" :rows="10" />
      </div>
      <div v-else-if="loadState === 'empty'" key="empty" class="state-root">
        <div class="state-card">
          <p>还没有交易行数据。</p>
          <p class="dim">快照正在准备中，稍后再来看看。</p>
          <button class="retry" :disabled="refreshing" @click="load()">重试</button>
        </div>
      </div>
      <div v-else-if="loadState === 'error'" key="error" class="state-root">
        <div class="state-card">
          <p>交易行数据加载失败：{{ loadError }}</p>
          <button class="retry" :disabled="refreshing" @click="load()">重试</button>
        </div>
      </div>
      <div v-else key="ready" class="state-root">
        <!-- 筛选条：品类 segmented + 子品类 chips + 品级 + 搜索 -->
        <div class="ctl-bar" role="group" aria-label="筛选">
          <div class="seg" role="tablist" aria-label="品类">
            <button
              v-for="c in CATS" :key="c.v" type="button" role="tab"
              class="seg-btn" :class="{ on: state.cat === c.v }"
              :aria-selected="state.cat === c.v"
              @click="setCat(c.v)"
            >{{ c.label }}</button>
          </div>
          <div v-if="subs.length" class="sub-chips" role="group" aria-label="子品类">
            <button class="chip" :class="{ on: state.sub === 'all' }" type="button" @click="state.sub = 'all'; state.page = 0">全部子类</button>
            <button
              v-for="[s, n] in subs" :key="s" type="button"
              class="chip" :class="{ on: state.sub === s }"
              @click="state.sub = state.sub === s ? 'all' : s; state.page = 0"
            >{{ s }} <span class="chip-n">{{ n }}</span></button>
          </div>
          <div class="ctl-row">
            <label class="grade-sel">
              品级
              <select v-model.number="state.grade" @change="state.page = 0">
                <option :value="0">全部</option>
                <option v-for="g in [6, 5, 4, 3, 2, 1]" :key="g" :value="g">{{ g }} 级</option>
              </select>
            </label>
            <input v-model="state.q" class="search" type="search" placeholder="搜索物品名…" aria-label="搜索物品名" @input="state.page = 0">
            <span class="dim count">命中 {{ filtered.length }} 件</span>
          </div>
        </div>

        <!-- 榜单 -->
        <div class="tbl-scroll">
          <table class="tbl">
            <thead>
              <tr>
                <th>物品</th>
                <th class="num sortable" @click="onSort('grade')">品级</th>
                <th class="num sortable" @click="onSort('current')">现价 {{ state.sort === 'current' ? (state.dir === 'desc' ? '↓' : '↑') : '' }}</th>
                <th class="num">昨日均价</th>
                <th class="num sortable" @click="onSort('chg24h')">24h {{ state.sort === 'chg24h' ? (state.dir === 'desc' ? '↓' : '↑') : '' }}</th>
                <th class="num">7 日区间位置</th>
                <th class="num sortable" @click="onSort('sevenLow')">7日低 {{ state.sort === 'sevenLow' ? (state.dir === 'asc' ? '↑' : '↓') : '' }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="it in pageItems" :key="it.objectId + it.name">
                <td>
                  <span class="it-cell">
                    <span class="icw" :style="{ '--gd': gradeVar(it.grade) }">
                      <img v-if="it.pic" class="ic" :src="picThumb(it.pic, 96)" alt="" loading="lazy" decoding="async" @load="imgReady" @error="hideImg">
                    </span>
                    <span class="it-name">
                      <span class="it-title">{{ it.name }}</span>
                      <span class="it-sub dim">{{ it.categoryCn || it.category }}<template v-if="it.subcategory && it.subcategory !== '-'"> · {{ it.subcategory }}</template></span>
                    </span>
                  </span>
                </td>
                <td class="num"><span class="grade-dot" :style="{ color: gradeVar(it.grade) }">{{ it.grade ?? '—' }}</span></td>
                <td class="num strong">{{ fmt(it.current) }}</td>
                <td class="num dim">{{ fmt(it.yesterdayAvg) }}</td>
                <td class="num" :class="chgCls(chgOf(it))">{{ pct(chgOf(it)) }}</td>
                <td class="num">
                  <span v-if="rangePos(it) != null" class="range" :title="`7日 ${fmt(it.sevenDayLow)} ~ ${fmt(it.sevenDayHigh)}`">
                    <span class="range-bar"><span class="range-dot" :style="{ left: `${(rangePos(it) * 100).toFixed(0)}%` }"></span></span>
                  </span>
                  <span v-else class="dim">—</span>
                </td>
                <td class="num dim">{{ fmt(it.sevenDayLow) }}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <!-- 分页 -->
        <div class="pager" v-if="pageCount > 1">
          <button class="pg-btn" type="button" :disabled="state.page === 0" @click="goPage(-1)">‹ 上一页</button>
          <span class="dim pg-label">第 {{ state.page + 1 }} / {{ pageCount }} 页</span>
          <button class="pg-btn" type="button" :disabled="state.page >= pageCount - 1" @click="goPage(1)">下一页 ›</button>
        </div>

        <p class="dim foot-note">价格与区间为上游（moligod 交易行快照）分钟级透传；「昨日均价」是滚动 24h 窗口，作涨跌参照而非整日均价。</p>
      </div>
    </Transition>
  </div>
</template>

<style scoped>
.ctl-bar { display: flex; flex-direction: column; gap: var(--sp-3); margin-bottom: var(--sp-4); }
.seg { display: flex; flex-wrap: wrap; gap: var(--sp-2); }
.seg-btn {
  padding: 6px 14px; min-height: 36px; background: var(--card); border: 1px solid var(--line);
  border-radius: 999px; color: var(--dim); font-size: var(--fs-sm); cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
}
.seg-btn:hover { color: var(--tx); border-color: var(--line-hover); }
.seg-btn.on { color: var(--accent); border-color: var(--accent); }
.sub-chips { display: flex; flex-wrap: wrap; gap: var(--sp-2); }
.chip {
  padding: 3px 10px; background: none; border: 1px solid var(--line); border-radius: 999px;
  color: var(--dim); font-size: var(--fs-xs); cursor: pointer;
}
.chip.on { color: var(--tx-strong); border-color: var(--accent); background: var(--accent-bg); }
.chip-n { color: var(--faint); font-family: var(--mono); font-size: var(--fs-2xs); }
.ctl-row { display: flex; align-items: center; gap: var(--sp-3); flex-wrap: wrap; }
.grade-sel { display: inline-flex; align-items: center; gap: 6px; color: var(--dim); font-size: var(--fs-sm); }
.grade-sel select, .search {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius);
  color: var(--tx); padding: 7px 10px; font-size: var(--fs-sm);
}
.search { flex: 1; min-width: 160px; max-width: 280px; }
.count { font-size: var(--fs-xs); margin-left: auto; }

.it-cell { display: flex; align-items: center; gap: 10px; min-width: 0; }
.icw {
  flex: none; width: 40px; height: 40px; border-radius: var(--radius-sm);
  background: var(--bg2); border: 1px solid color-mix(in srgb, var(--gd, var(--line)) 35%, transparent);
  display: inline-flex; align-items: center; justify-content: center;
}
.ic { max-width: 32px; max-height: 32px; opacity: 0; transition: opacity var(--t-med) var(--ease); }
.ic.ld { opacity: 1; }
.it-name { display: flex; flex-direction: column; min-width: 0; }
.it-title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--tx); }
.it-sub { font-size: var(--fs-2xs); }
.strong { color: var(--tx-strong); font-weight: 600; }
.up { color: var(--ok); }
.down { color: var(--danger); }
.dim { color: var(--faint); }
.grade-dot { font-family: var(--mono); font-weight: 700; }

/* 7 日区间条：轨道 + 当前位置圆点 */
.range { display: inline-block; width: 96px; }
.range-bar { position: relative; display: block; height: 4px; border-radius: 2px; background: var(--bg2); border: 1px solid var(--line); }
.range-dot {
  position: absolute; top: 50%; width: 8px; height: 8px; border-radius: 50%;
  background: var(--accent); transform: translate(-50%, -50%); box-shadow: 0 0 6px var(--accent-dim);
}

.pager { display: flex; align-items: center; justify-content: center; gap: var(--sp-4); padding: var(--sp-4) 0; }
.pg-btn {
  padding: 8px 14px; background: var(--card); border: 1px solid var(--line); border-radius: var(--radius);
  color: var(--dim); cursor: pointer; font-size: var(--fs-sm);
}
.pg-btn:disabled { opacity: .4; cursor: default; }
.pg-btn:not(:disabled):hover { color: var(--tx); border-color: var(--line-hover); }
.pg-label { font-size: var(--fs-xs); }
.foot-note { font-size: var(--fs-xs); margin: var(--sp-3) 0 0; }
.sortable { cursor: pointer; user-select: none; }
.sortable:hover { color: var(--tx); }

@media (prefers-reduced-motion: reduce) {
  .seg-btn, .chip, .pg-btn, .ic { transition: none; }
}
</style>
