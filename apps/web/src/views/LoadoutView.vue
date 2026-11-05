<script setup>
/* LoadoutView — 战备值差价（复刻自 moligod「战备值差价」）
   数据：public/market/loadout.json（server/market/tradehouse.mjs 落盘，上游
   moligod preparedness-valuation，免登录、小时级）。口径：
     · system = 游戏内系统折算价（物品带入对局按此价计「战备值」）
     · diff = system − current：市场现价低于战备折算价的部分——买入手赚
   上游已过滤只回 diff > 0 的条目（实测 100 项）；页面按差价/收益率排序浏览。
   数据小时级，走轮询不吃 SSE。 */
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import SkeletonView from '../components/SkeletonView.vue'
import { imgReady, hideImg } from '../composables/imgReady'
import { useSnapshotFeed } from '../composables/useSnapshotFeed'
import { fmt, pct, fmtSigned, gradeVar } from '../utils/format.js'

let prevTitle = ''

const {
  market, loadState, loadError, refreshing,
  load,
} = useSnapshotFeed(`${import.meta.env.BASE_URL}market/loadout.json`, {
  syntaxError: '战备差价数据格式异常，请稍后重试',
  successTip: false,
})

const items = computed(() => market.value?.items || [])
/* 收益率 = diff / current（每 1 哈夫币现价能换回的战备价差） */
const yieldOf = (it) => (it.diff != null && it.current > 0 ? it.diff / it.current : null)

const SORTS = [
  { v: 'diff', label: '差价' },
  { v: 'yield', label: '收益率' },
  { v: 'current', label: '现价' },
]
const sortV = ref('diff')
const sortDir = ref('desc')
function onSort(v) {
  if (sortV.value === v) sortDir.value = sortDir.value === 'desc' ? 'asc' : 'desc'
  else {
    sortV.value = v
    sortDir.value = v === 'current' ? 'asc' : 'desc'
  }
}
const sorted = computed(() => {
  const m = sortDir.value === 'asc' ? 1 : -1
  const num = (x) => (Number.isFinite(x) ? x : sortDir.value === 'asc' ? Infinity : -Infinity)
  const sorters = {
    diff: (a, b) => (num(a.diff) - num(b.diff)) * m,
    yield: (a, b) => (num(yieldOf(a)) - num(yieldOf(b))) * m,
    current: (a, b) => (num(a.current) - num(b.current)) * m,
  }
  return [...items.value].sort(sorters[sortV.value] || sorters.diff)
})

const updatedLabel = computed(() => {
  const v = String(market.value?.version || '')
  return v.length === 12 ? `${v.slice(4, 6)}-${v.slice(6, 8)} ${v.slice(8, 10)}:${v.slice(10, 12)}` : ''
})

onMounted(() => {
  prevTitle = document.title
  document.title = '三角洲行动 · 战备值差价'
})
onBeforeUnmount(() => {
  document.title = prevTitle
})
</script>

<template>
  <div class="wrap page">
    <header class="compact-head">
      <h1>战备值差价</h1>
      <p v-if="market" class="meta" :title="`数据版本 ${market.version}`">
        {{ market.stats.total }} 项 · 差价合计 {{ fmt(market.stats.diffSum) }} · 更新于 {{ updatedLabel }}
      </p>
    </header>

    <p class="state-tip">
      口径：<code>战备价</code> = 游戏内系统折算价（带入对局按此计战备值），<code>差价 = 战备价 − 现价</code>。
      正差价 = 现价低于战备折算价——按战备价口径「买入手赚」。上游只回正差价条目；价格为小时级。
    </p>

    <Transition name="swap" mode="out-in">
      <div v-if="loadState === 'loading'" key="loading" class="state-root sk-hold">
        <SkeletonView variant="table" :rows="10" />
      </div>
      <div v-else-if="loadState === 'empty'" key="empty" class="state-root">
        <div class="state-card">
          <p>还没有战备差价数据。</p>
          <p class="dim">快照正在准备中，稍后再来看看。</p>
          <button class="retry" :disabled="refreshing" @click="load()">重试</button>
        </div>
      </div>
      <div v-else-if="loadState === 'error'" key="error" class="state-root">
        <div class="state-card">
          <p>战备差价加载失败：{{ loadError }}</p>
          <button class="retry" :disabled="refreshing" @click="load()">重试</button>
        </div>
      </div>
      <div v-else key="ready" class="state-root">
        <div class="tbl-scroll">
          <table class="tbl">
            <thead>
              <tr>
                <th>物品</th>
                <th class="num">品级</th>
                <th class="num sortable" @click="onSort('current')">现价 {{ sortV === 'current' ? (sortDir === 'asc' ? '↑' : '↓') : '' }}</th>
                <th class="num">战备价</th>
                <th class="num sortable" @click="onSort('diff')">差价 {{ sortV === 'diff' ? (sortDir === 'desc' ? '↓' : '↑') : '' }}</th>
                <th class="num sortable" @click="onSort('yield')">收益率 {{ sortV === 'yield' ? (sortDir === 'desc' ? '↓' : '↑') : '' }}</th>
                <th class="num">更新</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="it in sorted" :key="it.objectId + it.name">
                <td>
                  <span class="it-cell">
                    <span class="icw" :style="{ '--gd': gradeVar(it.grade) }">
                      <img v-if="it.pic" class="ic" :src="it.pic" alt="" loading="lazy" decoding="async" @load="imgReady" @error="hideImg">
                    </span>
                    <span class="it-name">
                      <span class="it-title">{{ it.name }}</span>
                      <span class="it-sub dim">{{ it.categoryCn || it.category }}<template v-if="it.subcategory"> · {{ it.subcategory }}</template></span>
                    </span>
                  </span>
                </td>
                <td class="num"><span class="grade-dot" :style="{ color: gradeVar(it.grade) }">{{ it.grade ?? '—' }}</span></td>
                <td class="num">{{ fmt(it.current) }}</td>
                <td class="num dim">{{ fmt(it.system) }}</td>
                <td class="num strong up">{{ fmtSigned(it.diff) }}</td>
                <td class="num up">{{ pct(yieldOf(it)) }}</td>
                <td class="num dim">{{ (it.lastUpdate || '').slice(5) || '—' }}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="dim foot-note">
          战备价与差价为上游（moligod preparedness-valuation）小时级透传；「收益率」为本站派生
          （差价 / 现价）。战备值口径以游戏内实际结算为准，本表仅供参考，不构成任何建议。
        </p>
      </div>
    </Transition>
  </div>
</template>

<style scoped>
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
.up { color: var(--ok); }
.dim { color: var(--faint); }
.strong { color: var(--tx-strong); }
.grade-dot { font-family: var(--mono); font-weight: 700; }
.sortable { cursor: pointer; user-select: none; }
.sortable:hover { color: var(--tx); }
.foot-note { font-size: var(--fs-xs); margin: var(--sp-3) 0 0; }
@media (prefers-reduced-motion: reduce) {
  .ic { transition: none; }
}
</style>
