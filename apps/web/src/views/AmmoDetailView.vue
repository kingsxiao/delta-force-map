<script setup>
/* ============================================================
   AmmoDetailView — 弹种详情（/ammo/item/:name）
   ------------------------------------------------------------
   手机端动线的承接页：全表展开面板嵌在横向滚动表容器里，窄屏下面板
   td 跨满表内容宽（>600px），按钮带与图表半截落在视口外、内外滚动
   方向打架——≤680px 点行 / 点卖出迷你卡由 AmmoMarketView 改跳本页
   （弹名 encodeURIComponent，vue-router 解析时解码）；桌面直链亦可
   打开（内容列自适应，版式与移动一致）。
   数据链与行情页同源：useSnapshotFeed 接同一份 ammo/market.json
   （SSE / 分档轮询 / 回前台补拉全套随挂卸）；另借 snapshotCache 会话
   缓存秒开——从全表点进来时快照已在内存（peekSnapshot 先行渲染，
   fetch 304 / 200 落地后 market.value 接管），返回再进不白屏。
   内容 = 全表展开行的完整版：7 天大图（PriceChart，底色 card2 与
   十字线圈心填充同源）+ 关键数据（现价 / 24h / 税后预赚 / 日抛耗时 /
   穿透 / 官方均价 + 7 天分位轨道）+ 口径脚注（ItemNotes 共用组件）+
   记入囤货（usePositions.upsert，与台账行内编辑同一落库路径）。
   返回：history.state.back 存在（站内点入）走 router.back——列表页
   滚动位置由浏览器 popstate 原生恢复；直链进入（无上一页）replace
   回 /ammo 兜底。
   ============================================================ */
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useReveal } from '../composables/useReveal'
import { useStars } from '../composables/useStars'
import { usePositions } from '../composables/usePositions'
import PriceChart from './ammo/PriceChart.vue'
import ItemNotes from './ammo/ItemNotes.vue'
import PenBadge from './ttk/PenBadge.vue'
import SkeletonView from '../components/SkeletonView.vue'
import { imgReady, hideImg } from '../composables/imgReady'
import { useSnapshotFeed } from '../composables/useSnapshotFeed'
import { peekSnapshot } from '../composables/snapshotCache'
import { fmt, pct, SIGNAL_META, gradeVar } from '../utils/format.js'
import { CAL } from '../data/ttk/calibers.js'
import { marketNamePen } from '../data/ttk/ammo-market-alias.js'
import { formatVersionLabel, sourceLabel, picThumb } from '@shared/js/marketMeta.js'
import { fmtHours, dayTradeEta, isDayTradeItem, DAY_TRADE_MAX_H, DAY_TRADE_MIN_NET_PCT } from '@shared/js/sellEta.js'

const route = useRoute()
const router = useRouter()
const { observeRoot } = useReveal()
const rootEl = ref(null)

/* ---------- 数据（与行情页同一份快照 + 同一条数据链） ---------- */
const SNAP_URL = `${import.meta.env.BASE_URL}ammo/market.json`
const { market, loadState, loadError, refreshing, load } = useSnapshotFeed(SNAP_URL, {
  events: ['market'],
  emptyOn404: true,
  accept: (j) => !!(j && Array.isArray(j.items)),
  onInvalid: 'error',
  invalidError: '数据格式异常',
  syntaxError: '行情数据格式异常，请稍后重试',
  silentNeedsData: true,
})

/* 会话缓存秒开：peekSnapshot 读模块级 Map（非响应式，首渲染取到即用）；
   fetch 落地后 market.value 变化驱动本 computed 重估并接管（新快照覆写）。
   hasSnap 而非 loadState 驱动渲染分支——cache 命中时 loadState 仍是
   loading（silentNeedsData 把非 silent 拉取置 loading），不该回骨架 */
const snap = computed(() => market.value ?? peekSnapshot(SNAP_URL))
const items = computed(() => snap.value?.items ?? [])
const itemName = computed(() => String(route.params.name ?? ''))
const item = computed(() => items.value.find((i) => i.name === itemName.value) ?? null)

/* ---------- 信号门槛 / 版本（快照 rules 下发，与行情页同口径，不写死数字） ---------- */
const rules = computed(() => snap.value?.rules ?? {})
const ruleNum = (k, d) => (Number.isFinite(rules.value[k]) ? rules.value[k] : d)
const buyRankPct = computed(() => Math.round(ruleNum('BUY_RANK_MAX', 0.2) * 100))
const watchRankPct = computed(() => Math.round(ruleNum('WATCH_RANK_MAX', 0.35) * 100))
const sellRankPct = computed(() => Math.round(ruleNum('SELL_RANK_MIN', 0.8) * 100))
/* 官方均价偏离告警阈值（服务端同款 0.15，非 rules 成员） */
const OFFICIAL_DEV_WARN = 0.15
const versionLabel = computed(() => formatVersionLabel(snap.value?.version))
const srcShort = computed(() => sourceLabel(snap.value?.source))

/* ---------- TTK 联动：弹名 → 穿透等级（无映射显「—」，宁缺勿错，口径同全表） ---------- */
const penOf = (name) => marketNamePen(name, CAL)

/* ---------- 日抛耗时（口径单一源 @shared/js/sellEta.js，与全表列同源） ----------
   触屏没有 hover，结论落在副标行内：达标 / 超时 / 无先例三态如实可读 */
const dt = computed(() => (item.value ? dayTradeEta(item.value) : null))
const dtOk = computed(() => !!(item.value && dt.value && isDayTradeItem(item.value, dt.value)))
const dtNet = Math.round(DAY_TRADE_MIN_NET_PCT * 100)
const dtCell = computed(() => (dt.value ? `${Math.round(dt.value.medianH)}h` : '—'))
const dtSub = computed(() => {
  if (!dt.value) return '无历史先例'
  return dtOk.value ? `≤${DAY_TRADE_MAX_H}h 达标` : `超 ${DAY_TRADE_MAX_H}h`
})
const dtTip = computed(() => {
  if (!item.value) return ''
  if (!dt.value) return '现价无可参照的历史上涨段（处 7 天新低 / 新高或样本不足），无法估计日抛耗时'
  return `历史中位 ${fmtHours(dt.value.medianH)}（${dt.value.episodes} 次样本）：现价涨到税后净利 ≥${dtNet}% 卖价的耗时，${dtOk.value ? '满足' : `超 ${DAY_TRADE_MAX_H} 小时不满足`}日抛门槛`
})

/* ---------- 自选星标 + 记入囤货（useStars / usePositions 单例） ----------
   详情页无台账区块可滚：记入后给一行回执，指路行情页台账行内改数量成本 */
const { stars, toggleStar } = useStars()
const { positions, upsert: upsertPosition } = usePositions()
const inLedger = computed(() => !!(item.value && positions.value.some((p) => p.name === item.value.name)))
const posTip = ref('')
let posTipTimer = null
function quickAdd() {
  const i = item.value
  if (!i || inLedger.value) return
  upsertPosition({ name: i.name, qty: 100, cost: i.current })
  posTip.value = `已按现价 ${fmt(i.current)} × 100 发记入囤货；数量与成本到行情页「我的囤货台账」行内修改`
  clearTimeout(posTipTimer)
  posTipTimer = setTimeout(() => { posTip.value = '' }, 6000)
}

/* ---------- 返回：站内点入走 back（列表滚动位置由浏览器原生恢复）；
   直链 / 刷新进入无上一页，replace 回 /ammo 兜底 ---------- */
function goBack() {
  if (window.history.state?.back) router.back()
  else router.replace('/ammo')
}

/* ---------- 页面标题 / 揭示动画 ---------- */
let prevTitle = ''
function syncTitle() {
  document.title = item.value ? `三角洲行动 · ${item.value.name} 行情` : '三角洲行动 · 子弹详情'
}
onMounted(() => {
  prevTitle = document.title
  syncTitle()
  nextTick(() => observeRoot(rootEl.value))
})
watch(item, () => {
  syncTitle()
  // 快照从 cache 秒开 → fetch 接管换血时 item 引用更新：补一次 reveal 观察
  //（幂等，与 useReveal 内部去重口径一致）
  nextTick(() => observeRoot(rootEl.value))
})
onUnmounted(() => {
  document.title = prevTitle
  clearTimeout(posTipTimer)
})
</script>

<template>
  <div ref="rootEl" class="wrap page dt">
    <!-- 页头：返回钮独占一行（手机拇指热区），标题行 = 图标 + 弹名 + 信号 + 星标 -->
    <header class="compact-head dt-head">
      <button class="back press" @click="goBack">
        <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M9.5 4 5.5 8l4 4" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>
        返回行情全表
      </button>
      <template v-if="item">
        <div class="dt-title">
          <span
            class="a-icw dt-icw" aria-hidden="true"
            :style="{ '--gd': gradeVar(item.grade) }" :title="`品级 ${item.grade}`"
          >
            <img
              v-if="item.pic" class="a-ic"
              :src="picThumb(item.pic, 96)" alt=""
              width="38" height="26" loading="lazy" decoding="async"
              @load="imgReady" @error="hideImg"
            >
          </span>
          <h1>{{ item.name }}</h1>
          <span v-if="item.rank == null" class="sig wait">数据不足</span>
          <span v-else class="sig" :class="SIGNAL_META[item.signal].cls">{{ SIGNAL_META[item.signal].label }}</span>
          <button
            class="dt-star" :class="{ on: stars.has(item.name) }"
            :aria-pressed="stars.has(item.name)"
            :title="stars.has(item.name) ? '取消自选' : '加入自选'"
            @click="toggleStar(item.name)"
          ><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.6 9.59 6.02 14.28 6.16 10.57 9.03 11.88 13.54 8 10.9 4.12 13.54 5.43 9.03 1.72 6.16 6.41 6.02Z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/></svg></button>
        </div>
        <p class="meta" :title="`数据版本 ${versionLabel}`">{{ srcShort }}</p>
      </template>
      <h1 v-else class="dt-title-plain">子弹详情</h1>
    </header>

    <!-- 五分支互切（Transition mode="out-in"，MOTION.md §4.1）：item 命中 /
         快照在而弹名未命中 / 错误 / 空态 / 首载骨架（cache 秒开时不经骨架） -->
    <Transition name="swap" mode="out-in">
      <!-- 就绪：走势大图 + 关键数据 + 操作参考 -->
      <div v-if="item" key="ready" class="state-root">
        <section class="block reveal">
          <div class="block-h">
            <span class="bht">7 天走势</span><span class="bhline"></span>
            <span class="bhc">小时级 · 拖动查值</span>
          </div>
          <!-- 底色 card2：与展开行 td 背景同源——十字线圈心填充写死 --card2，
               图卡换底色会让查值点显深斑 -->
          <div class="chart-card">
            <PriceChart :curve="item.curve" :p25="item.p25" :p75="item.p75" :current="item.current" :official="item.official?.avg ?? null" />
          </div>
          <div class="dt-actions">
            <button
              class="pos-btn press" :class="{ on: inLedger }" :disabled="inLedger"
              :title="inLedger
                ? '已在囤货台账：数量与成本到行情页台账行内修改'
                : `按现价 ${fmt(item.current)} × 100 发记入囤货台账`"
              @click="quickAdd"
            >{{ inLedger ? '已记入囤货 ✓' : '记入囤货' }}</button>
            <p class="act-note">按现价预填 100 发，记入后到行情页台账行内改</p>
          </div>
          <Transition name="swap">
            <p v-if="posTip" class="pos-tip" role="status">{{ posTip }}</p>
          </Transition>
        </section>

        <section class="block reveal">
          <div class="block-h">
            <span class="bht">关键数据</span><span class="bhline"></span>
            <span class="bhc">{{ versionLabel }}</span>
          </div>
          <div class="stat-grid">
            <div class="stat">
              <i class="st-k">现价</i>
              <b class="st-v">{{ fmt(item.current) }}</b>
              <i class="st-sub">买入参考 P25 {{ fmt(item.p25) }}</i>
            </div>
            <div class="stat">
              <i class="st-k">24h 涨跌</i>
              <b class="st-v" :class="item.chg24h == null ? '' : item.chg24h >= 0 ? 'up' : 'down'">
                {{ item.chg24h == null ? '—' : pct(item.chg24h) }}
              </b>
              <i class="st-sub" :class="item.chg7d == null ? '' : item.chg7d >= 0 ? 'up' : 'down'">
                7天 {{ item.chg7d == null ? '—' : pct(item.chg7d) }}
              </i>
            </div>
            <div class="stat">
              <i class="st-k">税后预赚 · 发</i>
              <b class="st-v" :class="{ up: item.profitPerRound > 0 }">
                {{ item.profitPerRound > 0 ? `+${fmt(item.profitPerRound)}` : '—' }}
              </b>
              <i class="st-sub" :class="{ up: item.profitPerRound > 0 }">
                {{ item.profitPerRound > 0 ? `收益率 ${pct(item.profitPct)} · 挂卖 ${fmt(item.targetSell)}` : '暂无利差' }}
              </i>
            </div>
            <div class="stat">
              <i class="st-k">日抛耗时</i>
              <b class="st-v" :class="{ accent: dtOk }" :title="dtTip">{{ dtCell }}</b>
              <i class="st-sub" :class="{ accent: dtOk }">{{ dtSub }}</i>
            </div>
            <div class="stat">
              <i class="st-k">穿透等级</i>
              <span class="st-v st-pen">
                <PenBadge v-if="penOf(item.name) != null" :p="penOf(item.name)" />
                <template v-else>—</template>
              </span>
              <i class="st-sub">对各级护甲伤害通过率（TTK）</i>
            </div>
            <div class="stat">
              <i class="st-k">官方均价</i>
              <b class="st-v">{{ fmt(item.official?.avg) }}</b>
              <i v-if="item.official" class="st-sub" :class="{ 'off-bad': Math.abs(item.official.dev) > OFFICIAL_DEV_WARN }">
                偏离 {{ pct(item.official.dev) }}
              </i>
              <i v-else class="st-sub">无对账数据</i>
            </div>
          </div>
          <!-- 7 天分位轨道（满宽）：刻度阈值经 rules 下发；触屏无 hover，
               三条刻度的语义平移到图下图例，就地可读 -->
          <div class="rank-panel">
            <div class="rp-head">
              <i class="st-k">7 天分位</i>
              <b
                v-if="item.rank != null" class="rp-num"
                :class="{ low: item.rank <= watchRankPct / 100, high: item.rank >= sellRankPct / 100 }"
              >{{ Math.round(item.rank * 100) }}%</b>
              <b v-else class="rp-num">—</b>
              <span class="rp-range">区间 {{ fmt(item.weekLow) }} ~ {{ fmt(item.weekHigh) }}</span>
            </div>
            <div
              v-if="item.rank != null" class="rank-bar" role="img"
              :aria-label="`现价处近 7 天 ${Math.round(item.rank * 100)}% 分位`"
            >
              <i class="rb-tick buy" :style="{ left: `${buyRankPct}%` }"></i>
              <i class="rb-tick watch" :style="{ left: `${watchRankPct}%` }"></i>
              <i class="rb-tick" :style="{ left: `${sellRankPct}%` }"></i>
              <i
                class="rb-fill" :class="{ low: item.rank <= watchRankPct / 100, high: item.rank >= sellRankPct / 100 }"
                :style="{ width: `${Math.round(item.rank * 100)}%` }"
              ></i>
            </div>
            <p v-if="item.rank != null" class="rp-legend">
              现价在 7 天价格区间的位置 · 刻度：≤{{ buyRankPct }}% 买入 · ≤{{ watchRankPct }}% 关注 · ≥{{ sellRankPct }}% 卖出
            </p>
            <p v-else class="rp-legend">曲线不足 2 天，暂无分位</p>
          </div>
        </section>

        <section class="block reveal">
          <div class="block-h">
            <span class="bht">操作参考</span><span class="bhline"></span>
          </div>
          <div class="notes-card">
            <ItemNotes :item="item" />
          </div>
        </section>

        <p class="dt-foot reveal">
          <router-link to="/ammo" class="back-link press">返回行情全表，看其余 {{ Math.max(items.length - 1, 0) }} 种弹 →</router-link>
        </p>
      </div>

      <!-- 快照在而弹名未命中：下架 / 改名 / 链接手误 -->
      <div v-else-if="snap" key="missing" class="state-root">
        <div class="state-card">
          <p>行情里没有找到「{{ itemName }}」。</p>
          <p class="dim">弹种可能已下架或改名，链接也可能有误——回全表搜索确认。</p>
          <button class="retry" @click="goBack">返回行情全表</button>
        </div>
      </div>

      <div v-else-if="loadState === 'error'" key="error" class="state-root">
        <div class="state-card">
          <p>行情加载失败：{{ loadError }}</p>
          <button class="retry" :disabled="refreshing" @click="load()">{{ refreshing ? '重试中…' : '重试' }}</button>
        </div>
      </div>

      <div v-else-if="loadState === 'empty'" key="empty" class="state-root">
        <div class="state-card">
          <p>还没有行情数据。</p>
          <p class="dim">行情快照正在准备中，稍后再来看看。</p>
        </div>
      </div>

      <!-- 首载骨架（会话缓存未命中才走到）：主卡 + 数据格贴近真实首屏 -->
      <div v-else key="loading" class="state-root sk-hold">
        <SkeletonView variant="hero" />
        <SkeletonView variant="cards" />
      </div>
    </Transition>
  </div>
</template>

<style scoped>
.page { padding-bottom: var(--sp-10); }

/* ---------- 页头 ---------- */
.dt-head { row-gap: var(--sp-2); }
/* 返回钮：ghost 胶囊，紧凑页头首元素（手机单手热区）；触屏垫层全向扩 10px
   （上方是顶栏、下方标题行不可点，扩垫不劫持邻区） */
.back {
  display: inline-flex; align-items: center; gap: 6px;
  align-self: flex-start;
  background: none; border: 1px solid var(--line); border-radius: var(--radius-pill);
  color: var(--dim); font-size: var(--fs-xs); padding: 5px 14px; cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
}
.back:hover,
.back:active { color: var(--tx); border-color: var(--line-hover); }
.back svg { width: 11px; height: 11px; }
@media (pointer: coarse) {
  .back { position: relative; }
  .back::before { content: ""; position: absolute; inset: -10px; }
}
/* 标题行满宽独占：图标匣（品级染底，同 SellCard .sl-ic 语汇放大一档）+
   弹名（超长省略）+ 信号徽章 + 星标（右推） */
.dt-title {
  flex: 1 1 100%;
  display: flex; align-items: center; gap: 10px; min-width: 0;
}
.dt-title h1 {
  flex: 0 1 auto; min-width: 0; margin: 0;
  overflow: hidden; text-overflow: ellipsis;
}
.dt-title-plain { margin: 0; }
.dt-icw {
  position: relative; flex: none;
  width: 46px; height: 34px;
  display: inline-flex; align-items: center; justify-content: center;
  border: 1px solid var(--line);
  border-color: color-mix(in srgb, var(--gd, var(--faint)) 45%, transparent);
  border-radius: 6px;
}
.dt-icw.ld {
  background: var(--deep);
  background: color-mix(in srgb, var(--gd, var(--faint)) 15%, var(--deep));
}
.dt-icw .a-ic { width: 38px; height: 26px; object-fit: contain; }
.dt-star {
  flex: none; margin-left: auto;
  display: inline-flex; align-items: center; justify-content: center;
  width: 34px; height: 34px;
  background: none; border: 1px solid var(--line); border-radius: 50%;
  color: var(--faint); opacity: .55; cursor: pointer;
  transition: opacity var(--t-fast) var(--ease), color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
}
.dt-star:hover,
.dt-star:active { opacity: .85; border-color: var(--line-hover); }
.dt-star.on { color: var(--lv5); opacity: 1; border-color: color-mix(in srgb, var(--lv5) 45%, transparent); }
.dt-star.on svg path { fill: currentColor; }
.dt-star svg { width: 16px; height: 16px; }

/* ---------- 状态卡（口径同行情页 .state-card / .retry） ---------- */
.state-card {
  background: var(--card); border: 1px dashed var(--line); border-radius: var(--radius);
  padding: var(--sp-6); color: var(--tx); margin: var(--sp-4) 0;
}
.state-card .dim { color: var(--faint); font-size: var(--fs-sm); }
.retry {
  background: var(--accent-bg); color: var(--accent); border: 1px solid var(--accent-dim);
  border-radius: var(--radius); padding: 6px 18px; cursor: pointer; font-size: var(--fs-sm);
  transition: background-color var(--t-med) var(--ease), transform var(--t-fast) var(--ease);
}
.retry:hover { background: var(--accent-soft); }
.retry:active { transform: scale(.98); }
.retry:disabled { opacity: .45; cursor: default; }
.sk-hold {
  display: flex; flex-direction: column; gap: var(--sp-5);
  padding-top: var(--sp-6);
}

/* ---------- 走势图卡：card2 底与十字线圈心填充同源（见 PriceChart .pc-xh） ---------- */
.chart-card {
  background: var(--card2);
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  padding: 12px 12px 8px;
}
.dt-actions {
  display: flex; align-items: center; gap: 12px; flex-wrap: wrap;
  margin-top: var(--sp-3);
}
.pos-btn {
  font-family: var(--mono); font-size: var(--fs-sm);
  color: var(--accent); background: var(--accent-bg);
  border: 1px solid var(--accent-dim); border-radius: var(--radius-pill);
  padding: 8px 20px; cursor: pointer;
  transition: background-color var(--t-med) var(--ease), transform var(--t-fast) var(--ease);
}
.pos-btn:hover:not(:disabled),
.pos-btn:active:not(:disabled) { background: var(--accent-soft); }
.pos-btn:active:not(:disabled) { transform: scale(.98); }
/* 已记入：转 ok 语义并禁用（不覆盖已录成本，与展开行同口径） */
.pos-btn.on:disabled {
  color: var(--ok); cursor: default;
  border-color: color-mix(in srgb, var(--ok) 40%, transparent);
  background: color-mix(in srgb, var(--ok) 10%, transparent);
  opacity: .8;
}
.act-note { font-size: var(--fs-xs); color: var(--faint); }
.pos-tip { font-size: var(--fs-xs); color: var(--ok); margin: 8px 2px 0; }

/* ---------- 关键数据格：手机 2 列 / ≥681px 4 列 ---------- */
.stat-grid {
  display: grid; grid-template-columns: repeat(2, 1fr); gap: var(--sp-3);
}
@media (min-width: 681px) {
  .stat-grid { grid-template-columns: repeat(4, 1fr); }
}
.stat {
  display: flex; flex-direction: column; gap: 3px; min-width: 0;
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-lg);
  padding: 10px 12px;
  box-shadow: var(--edge-light);
}
.st-k {
  font-style: normal; font-family: var(--mono); font-size: var(--fs-2xs);
  letter-spacing: .08em; color: var(--faint);
}
.st-v {
  font-family: var(--mono); font-size: var(--fs-lg); font-weight: 700;
  color: var(--tx-strong); font-variant-numeric: tabular-nums;
  line-height: 1.2; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.st-sub {
  font-style: normal; font-family: var(--mono); font-size: var(--fs-2xs);
  color: var(--faint); white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.st-v.up, .st-sub.up { color: var(--ok); }
.st-v.down, .st-sub.down { color: var(--danger); }
.st-v.accent, .st-sub.accent { color: var(--accent); }
.st-sub.off-bad { color: var(--danger); }
.st-pen { display: inline-flex; align-items: center; min-height: 1.3em; }

/* ---------- 7 天分位轨道（满宽面板；刻度/填充染色的口径同全表 .rank-bar） ---------- */
.rank-panel {
  margin-top: var(--sp-3);
  display: flex; flex-direction: column; gap: 8px;
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-lg);
  padding: 12px 14px;
  box-shadow: var(--edge-light);
}
.rp-head { display: flex; align-items: baseline; gap: 10px; }
.rp-num {
  font-family: var(--mono); font-size: var(--fs-lg); font-weight: 700;
  color: var(--tx-strong); font-variant-numeric: tabular-nums;
}
.rp-num.low { color: var(--ok); }
.rp-num.high { color: var(--danger); }
.rp-range { margin-left: auto; font-family: var(--mono); font-size: var(--fs-xs); color: var(--dim); white-space: nowrap; }
.rank-bar { position: relative; height: 7px; background: var(--line2); border-radius: 4px; }
.rb-tick { position: absolute; top: -2px; bottom: -2px; width: 1px; background: var(--line-hover); }
.rb-tick.buy { background: color-mix(in srgb, var(--ok) 55%, transparent); }
.rb-tick.watch { background: color-mix(in srgb, var(--info) 50%, transparent); }
.rb-fill { position: absolute; top: 0; bottom: 0; left: 0; border-radius: 4px; background: var(--faint); }
.rb-fill.low {
  background: linear-gradient(90deg, color-mix(in srgb, var(--ok) 45%, transparent), var(--ok));
}
.rb-fill.high {
  background: linear-gradient(90deg, color-mix(in srgb, var(--danger) 45%, transparent), var(--danger));
}
.rp-legend { font-family: var(--mono); font-size: var(--fs-2xs); color: var(--faint); line-height: 1.7; }

/* ---------- 操作参考（脚注本体在 ItemNotes.vue scoped） ---------- */
.notes-card {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-lg);
  padding: var(--sp-1) var(--sp-4) var(--sp-3);
}
.dt-foot { margin-top: var(--sp-6); }
.back-link {
  color: var(--accent); font-size: var(--fs-sm); text-decoration: none;
  border-bottom: 1px solid var(--accent-dim); padding-bottom: 1px;
}
.back-link:active { opacity: .8; }

@media (prefers-reduced-motion: reduce) {
  .back, .dt-star, .retry, .pos-btn { transition: none; }
  .retry:active, .pos-btn:active { transform: none; }
  .a-ic { transition: none; }
}
</style>
