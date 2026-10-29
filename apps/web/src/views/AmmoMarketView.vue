<script setup>
/* ============================================================
   AmmoMarketView — 子弹行情 · 实时监控（/ammo）
   ------------------------------------------------------------
   数据源：public/ammo/market.json（由 scripts/ammo/fetch-once.mjs 生成，
   主源 moligod.com 分钟级，kkrb.net 小时级兜底，json.source 标明来源）。
   刷新链路（按环境自动取最优）：
     · 本地 dev + npm run ammo:live：SSE（127.0.0.1:8787）落盘后 ≤5s 推送，
       页面收到 event:market 自拉 market.json；
     · npm run serve 同源部署（scripts/server.mjs）：SSE /events 同源直连，
       快照由服务端抓取循环持续刷新（https 同源，无 mixed content / CORS）；
     · 其余环境（纯静态托管）：/health 探测不到服务端 → 静默轮询 + 手动
       『刷新数据』自动退回 30 分钟，且自动刷新仅在版本前进时才闪提示，
       不打每分钟无效流量、不误导「正在更新」。
   纯静态部署（无后端）不白屏：吃构建时快照，并如实标注数据年龄与来源；
   时效阈值按 source 分档（moligod 10/30min，kkrb 沿用 60/360min）。
   后台跑 live / monitor 时，出现买入/卖出信号会弹 macOS 系统通知
   （哪种子弹 / 什么价买 / 挂多少钱卖 / 预赚多少）。
   口径与 server/ammo/analyze.mjs 一致（v2 回测定稿）：低位企稳才买
   （分位 + 止跌 + 趋势三重确认）、目标挂卖近 3 天 P75、利润为税后
   到手价减买入价，随信号给止损位与最长持有时长。
   「日抛」筛选：现价买入 ≤24h 能涨到「税后回本线 +5%」卖价的弹（口径
   单一源 @shared/js/sellEta.js dayTradeEta / isDayTradeItem），全表控制条
   toggle chip + 「日抛耗时」列/排序承接。
   快照数据链（loadSeq 守卫 / SSE 版本门控 / 分档轮询 / 回前台补拉 /
   fingerprint 协商缓存）在 ../composables/useSnapshotFeed.js（三视图共用）。
   版本展示 / 阈值分档 / 通道门槛等纯逻辑在 ./ammo/marketMeta.js（自测共用）。
   页尾倒卖手册（./ammo/Playbook.vue，静态）：社区攻略整理的
   买卖时段 / 挂单定价 / 版本窗口 / 卡邮件要点与风险红线，与信号区互补。
   页头之下「我的囤货台账」抽为 ./ammo/PositionLedger.vue（props 传
   items/rules，usePositions + useAccount 内聚；全表展开行「记入囤货」经
   组件 expose 的 upsert 写入，台账现价的 diffPriceFlash 闪变随迁子组件）。
   TTK 联动：全表「穿透」列按弹名映射 TTK 穿透等级（PenBadge；映射与
   「— = 无穿透数据」口径见 src/data/ttk/ammo-market-alias.js）；进入时
   消费 /ammo?q=弹名 深链回填搜索框（TTK 页「现价」入口）。
   手机端动线（≤680px，--bp-mobile 同源断点）：点行 / 点卖出迷你卡不再
   就地展开（面板嵌横向滚动容器，窄屏不可用），改跳 /ammo/item/:name
   独立详情页（AmmoDetailView，返回即回全表）；桌面 ≥681px 保留行内展开。
   口径脚注组（口径/官方均价/军需处折算/预计卖出）抽为 ./ammo/ItemNotes.vue
   （文案单一源 ./ammo/etaLine.js），展开行与详情页共用。
   ============================================================ */
import { computed, nextTick, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useReveal } from '../composables/useReveal'
import { useStars } from '../composables/useStars'
import { usePositions } from '../composables/usePositions'
import SignalCard from './ammo/SignalCard.vue'
import SellCard from './ammo/SellCard.vue'
import Sparkline from './ammo/Sparkline.vue'
import PriceChart from './ammo/PriceChart.vue'
import Playbook from './ammo/Playbook.vue'
import MarketClock from './ammo/MarketClock.vue'
import PositionLedger from './ammo/PositionLedger.vue'
import ItemNotes from './ammo/ItemNotes.vue'
import PenBadge from './ttk/PenBadge.vue'
import SkeletonView from '../components/SkeletonView.vue'
import { imgReady, hideImg } from '../composables/imgReady'
import { useSnapshotFeed } from '../composables/useSnapshotFeed'
import { fmt, pct, SIGNAL_META, SIG_COLOR, gradeVar } from '../utils/format.js'
import { CAL } from '../data/ttk/calibers.js'
import { marketNamePen } from '../data/ttk/ammo-market-alias.js'
import {
  formatVersionLabel, staleness, methodDataLine, sourceLabel, staleTipText, picThumb,
} from '@shared/js/marketMeta.js'
import { fmtHours, marketClock, dayTradeEta, isDayTradeItem, DAY_TRADE_MAX_H, DAY_TRADE_MIN_NET_PCT } from '@shared/js/sellEta.js'
import { judgeSignals, sendNotifications } from '@shared/js/notify-policy.js'

const route = useRoute()
const router = useRouter()

const { observeRoot } = useReveal()

/* ---------- 数据加载（silent 静默刷新：不整页 loading，失败保留旧数据） ----------
   快照数据链（loadSeq 并发守卫 / load 四分支 / SSE 版本门控 / 分档轮询 /
   回前台按变灰阈值补拉 / 卸载清理 / fingerprint 协商缓存）统一在
   composables/useSnapshotFeed.js；本页注入差异：首载 404 视为「快照尚未
   生成」空态、结构非法整页报错、无数据时 silent 降级为整页重载、ready 后
   跑价格闪变 diff + 通知去抖 + 揭示 / 表格补挂 */
const pageRef = ref(null)
const ctlRef = ref(null)
const tblRef = ref(null)
const allSecRef = ref(null)

let clockTimer = null
let ctlRO = null
let prevTitle = '' // 路由标题：进入存默认值，卸载还原（模式同 TtkView）

const {
  market, loadState, loadError, refreshing, refreshTip, refreshTipKind,
  nowTs, liveChannel, load,
} = useSnapshotFeed(`${import.meta.env.BASE_URL}ammo/market.json`, {
  events: ['market'],
  emptyOn404: true,
  accept: (j) => !!(j && Array.isArray(j.items)),
  onInvalid: 'error',
  invalidError: '数据格式异常',
  syntaxError: '行情数据格式异常，请稍后重试',
  silentNeedsData: true,
  onLoaded: (json, { prev, silent }) => {
    diffPriceFlash(prev?.items, json.items)
    // 信号去抖 judge 挂在每次成功刷新上（含首次整页与静默轮询/SSE）：首轮只
    // 建基线不弹，之后 diff 出的新 BUY/SELL 才投递浏览器通知（见通知块注释）
    runNotifyJudge(json, { silent })
    // 四态互切走 <Transition mode="out-in">：ready 根节点在旧态离场结束后才
    // 插入 DOM，这一批 observeRoot/syncTblFade/mountCtlRO 只覆盖不换根的
    // 静默刷新路径；进场合子在 onStateRootEnter 补跑（三件事均幂等）
    nextTick(() => {
      observeRoot(pageRef.value)
      syncTblFade()
      mountCtlRO()
    })
  },
})

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

/* 四态互切走 <Transition mode="out-in">（MOTION.md §4.1）：ready 根节点在旧态
   离场结束后才插入 DOM，load() 成功路径里 nextTick 批次的 observeRoot/syncTblFade/
   mountCtlRO 那一刻还找不到真实节点（该批次只覆盖 silent 刷新这类不换根的路径）——
   在进场合子里补跑一次；三件事均幂等，与 load() 内批次重复执行无害 */
function onStateRootEnter() {
  if (loadState.value !== 'ready') return
  observeRoot(pageRef.value)
  syncTblFade()
  mountCtlRO()
}

/* 横滑渐隐提示：仅容器真溢出（can-scroll）且未滑到底（!at-end）时显示 */
const tblCanScroll = ref(false)
const tblAtEnd = ref(false)
function syncTblFade() {
  const el = tblRef.value
  if (!el) return
  /* 空态（无符合筛选的行）时表格只剩表头 nowrap 撑出的最小宽溢出，渐隐
     只会罩淡空态行右侧的「清除全部筛选」按钮——没有数据行就没有可横滑的内容 */
  const noRows = !filtered.value.length
  tblCanScroll.value = !noRows && el.scrollWidth > el.clientWidth + 2
  tblAtEnd.value = el.scrollLeft + el.clientWidth >= el.scrollWidth - 2
}

/* ---------- 数据时效（fetchedAt 距今分钟数；分钟钟每 60s 走一格，长开页面状态也诚实。
   nowTs 来自 useSnapshotFeed：轮询 tick 与回前台都会校正，本页再挂 60s 分钟钟） ---------- */
const ageMin = computed(() => {
  const t = Date.parse(market.value?.fetchedAt)
  return Number.isFinite(t) ? (nowTs.value - t) / 60000 : null
})
/* 数据版本：12 位分钟档（moligod）显示到 HH:mm，10 位小时档（kkrb）显示 HH:00 */
const versionLabel = computed(() => formatVersionLabel(market.value?.version))

/* ---------- 时效与更新粒度（按 json.source 分档，纯函数在 @shared/js/marketMeta.js） ---------- */
const thresholds = computed(() => staleness(market.value?.source))
const dataLine = computed(() => methodDataLine(market.value?.source))
const staleTipMsg = computed(() => staleTipText(market.value?.source, ageMin.value))

/* ---------- 实时通道（SSE）：本地开发连独立 live 服务（8787），部署形态连
   同源 /events（scripts/server.mjs）。通道建立 / 断线退避重探 / 版本门控
   拉取（hello 与 market 事件同为「版本前进才重新 GET」的轻量 ping）都在
   useSnapshotFeed 内；liveChannel 状态（off 环境不适用 / connecting /
   on / down）由此处的文案映射承接 ---------- */
const liveText = computed(() => {
  if (liveChannel.value === 'on') return '实时推送已连接，行情更新自动送达'
  if (liveChannel.value === 'down') return '实时推送已断开，自动重连中；期间每 60 秒自动刷新'
  if (liveChannel.value === 'connecting') return '实时推送连接中…'
  return '' // off：纯静态环境不显示，避免误导
})
/* 紧凑页头右列短语：更新粒度短标（@shared/js/marketMeta.js sourceLabel；
   完整版本号与通道全文在悬浮 title；本地 live/monitor 工具说明移 METHOD，
   不再占页头） */
const srcShort = computed(() => sourceLabel(market.value?.source))
const headTip = computed(() =>
  `数据版本 ${versionLabel.value}${liveText.value ? ` · ${liveText.value}` : ''}`)

/* ---------- 浏览器通知（去抖口径与服务端同源：shared/js/notify-policy.js） ----------
   双重部署现实（如实降级，不糊弄）：
     · 非安全上下文（线上 http://<IP> 形态）下 Chrome/Edge 无 Notification
       对象——开关置灰并说明需 HTTPS 部署；https 就绪即插即用，代码不改。
     · 后台标签页的更新源仅实时推送部署形态成立（SSE 落盘即拉；轮询只在
       页面可见时拉取），纯静态托管退化为「页面可见时提醒」。
   去抖 state 存 localStorage（与服务端 monitor-state.json 同构）：无论开关
   都随每次成功刷新逐轮推进（关掉再开不会把存量信号一次性爆发）；首次
   整页加载只建立基线不弹（信号卡就在眼前），静默刷新 diff 出的新 BUY/SELL
   才弹（buyLine/sellLine 与服务端通知同款文案），点击通知 window.focus()。 */
const NOTIFY_SUPPORTED = typeof window !== 'undefined' && window.isSecureContext && 'Notification' in window
const NOTIFY_ON_KEY = 'ammo-notify-on'
const NOTIFY_STATE_KEY = 'ammo-notify-state'
const NOTIFY_SCOPE_TIP = '后台提醒需实时推送部署形态（页头显示实时推送），纯静态托管仅页面可见时提醒'
const notifyOn = ref(false)
const notifyTip = ref('')
let notifyTipTimer = null

function loadNotifyState() {
  try {
    const raw = JSON.parse(localStorage.getItem(NOTIFY_STATE_KEY))
    return raw && typeof raw === 'object' && typeof raw.items === 'object' && raw.items ? raw : { items: {} }
  } catch {
    return { items: {} }
  }
}
const notifyJudgeState = loadNotifyState()
try {
  notifyOn.value = NOTIFY_SUPPORTED && localStorage.getItem(NOTIFY_ON_KEY) === '1'
} catch { /* 读取失败按关处理 */ }

function persistNotify(on) {
  try {
    if (on) localStorage.setItem(NOTIFY_ON_KEY, '1')
    else localStorage.removeItem(NOTIFY_ON_KEY)
  } catch { /* 隐私模式等写入失败时仅本次会话生效 */ }
}
function persistNotifyState() {
  try {
    localStorage.setItem(NOTIFY_STATE_KEY, JSON.stringify(notifyJudgeState))
  } catch { /* 同上 */ }
}
function flashNotifyTip(msg) {
  notifyTip.value = msg
  if (notifyTipTimer) clearTimeout(notifyTipTimer)
  notifyTipTimer = setTimeout(() => { notifyTip.value = '' }, 6000)
}
async function toggleNotify() {
  if (!NOTIFY_SUPPORTED) return
  if (notifyOn.value) {
    notifyOn.value = false
    persistNotify(false)
    return
  }
  let perm = Notification.permission
  if (perm === 'default') perm = await Notification.requestPermission()
  if (perm !== 'granted') {
    flashNotifyTip('浏览器通知权限未授予：请在地址栏权限设置中允许后重开')
    return
  }
  notifyOn.value = true
  persistNotify(true)
  flashNotifyTip(NOTIFY_SCOPE_TIP)
}
/* load 成功回调：喂 judge 推进去抖 state（与服务端同口径，含 WAIT 全量记录）；
   静默刷新且开关在开、权限已授予时才真正投递浏览器通知 */
function runNotifyJudge(json, { silent }) {
  try {
    const { buys, sells } = judgeSignals(notifyJudgeState, json.items || [])
    persistNotifyState()
    if (!silent || !notifyOn.value || Notification.permission !== 'granted') return
    if (!buys.length && !sells.length) return
    sendNotifications(buys, sells, ({ title, body }) => {
      try {
        const n = new Notification(title, { body })
        n.onclick = () => { window.focus(); n.close() }
      } catch { /* 单条通知构造失败不影响其余链路 */ }
    })
  } catch { /* 通知链路任何异常都不影响行情展示 */ }
}
const notifyBtnTitle = computed(() =>
  NOTIFY_SUPPORTED ? `BUY/SELL 新信号弹浏览器通知（与服务端通知同款文案与去抖口径）。${NOTIFY_SCOPE_TIP}` : '浏览器通知需 HTTPS 部署后可用')

/* ---------- 价格闪变反馈（思路库·价格闪变）：静默刷新落地后 diff 新旧现价，
   变化格挂 up/down 类——td 一次性 0.8s 底色脉冲 + 涨跌箭头，900ms 后摘类。
   MOTION.md §3-E 禁的是数字滚动（整表翻牌 = 噪声），这里不动数字本身；
   底色脉冲属 §6-1 允许的状态过渡（color/background 无布局成本），只给
   真变了的格、一次性、低幅度（≤14%）。纯静态环境快照版本不变 → diff
   天然为空，不会整表乱闪 ---------- */
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

/* ---------- 展示工具：fmt / pct / fmtSigned / SIGNAL_META / SIG_COLOR / gradeVar
   统一收编 ../utils/format.js（三页与信号卡共用，口径注释在彼处） ---------- */

/* ---------- 信号门槛（快照顶层 rules 下发，analyze.mjs RULES 展示子集） ----------
   页面文案 / 刻度线一律从 rules 渲染，杜绝 UI 与规则参数漂移（曾出现页面写
   8% / 25% 而规则已是 10% / 20% 的三处失同步）。rules 缺失（旧快照）时退
   v2 定稿值兜底显示 */
const rules = computed(() => market.value?.rules || {})
const ruleNum = (k, dflt) => (Number.isFinite(rules.value[k]) ? rules.value[k] : dflt)
const buyRankPct = computed(() => Math.round(ruleNum('BUY_RANK_MAX', 0.2) * 100)) // 买入分位门槛 %
const watchRankPct = computed(() => Math.round(ruleNum('WATCH_RANK_MAX', 0.35) * 100)) // 关注分位门槛 %
const sellRankPct = computed(() => Math.round(ruleNum('SELL_RANK_MIN', 0.8) * 100)) // 卖出分位门槛 %
const buyNetPct = computed(() => Math.round(ruleNum('BUY_MIN_NET_PCT', 0.1) * 100)) // 买入税后净利下限 %
/* 官方均价偏离告警阈值（服务端同款 0.15，非 rules 成员） */
const OFFICIAL_DEV_WARN = 0.15
const reduceMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches
// 表内行图标加载失败（CDN 抖动等）就地隐藏，不占位不报错——事件处理三页共享
//（composables/imgReady.js；占位底与淡入样式见 motion.css「图片占位」段）

/* ---------- TTK 联动：弹名 → 穿透等级（PenBadge 徽标，等级语义 0-7） ----------
   映射与「宁缺勿错」口径见 src/data/ttk/ammo-market-alias.js：一对多歧义
   （紫/蓝/金.300BLK）、国服命名无同型条目（DBP10 等）与弓弩箭矢返回 null，
   穿透列显「—」（表尾 METHOD 注明），绝不猜等级。 */
const penOf = (name) => marketNamePen(name, CAL)

/* ---------- 信号计数（筛选 chip 计数 + 买入空态文案共用；页头不再单设总览面板，
   数字就挂在筛选动作旁边——与雷达页 chip-n 同模式） ---------- */
const stats = computed(() => {
  const c = { BUY: 0, SELL: 0, WATCH: 0, WAIT: 0 }
  for (const i of items.value) if (c[i.signal] != null) c[i.signal]++
  return c
})

/* ---------- 自选星标 + 囤货台账（useStars / usePositions 单例：localStorage
   持久化 + 账号云同步挂钩，登录后由 useAccount 做两端合并，见 /account 页） ---------- */
const { stars, toggleStar } = useStars()
/* 台账区块（渲染 / 行内编辑 / 录入表单 / 现价闪变）整体内聚在
   ./ammo/PositionLedger.vue（props 传 items/rules）；页面保留 positions
   单例引用——全表展开行「记入囤货」的已记入态判定与查重守卫直接读它，
   写入走子组件 expose 的 upsert（账本字段落库收口在子组件一处） */
const { positions } = usePositions()
const ledgerRef = ref(null)

/* 全表行展开「记入囤货」：零持仓时的录入通道（区块本身有持仓才显示）——
   预填现价 × 100 发，数量与成本再到台账行内改；已在台账不覆盖用户已录成本 */
function quickAddPosition(i) {
  if (positions.value.some((p) => p.name === i.name)) return
  // 首条持仓让台账区块从无到有：区块带 .reveal（默认 opacity:0），中途出现的
  // 元素不在 load 成功后的 observeRoot 批次里，这里补一次 observe 否则永远隐藏
  const first = positions.value.length === 0
  ledgerRef.value?.upsert({ name: i.name, qty: 100, cost: i.current })
  if (first) nextTick(() => observeRoot(pageRef.value))
  // 记入后滚到台账区：用户在全表中下部展开行，台账在页头之下，不滚可能根本注意不到
  nextTick(() => {
    ledgerRef.value?.rootEl?.scrollIntoView({ block: 'center', behavior: reduceMotion() ? 'auto' : 'smooth' })
  })
}

/* ---------- 筛选与排序 ---------- */
const SIGNALS = [
  { v: 'all', label: '全部' },
  { v: 'BUY', label: '买入', dot: 'var(--ok)' },
  { v: 'WATCH', label: '关注', dot: 'var(--info)' },
  { v: 'SELL', label: '卖出', dot: 'var(--danger)' },
  { v: 'WAIT', label: '观望', dot: 'var(--faint)' },
  { v: 'star', label: '自选', star: true },
]
const SORTS = [
  { v: 'signal', label: '信号优先' },
  { v: 'profit', label: '预期利润' },
  { v: 'chg', label: '24h涨跌' },
  { v: 'rank', label: '价格分位' },
  { v: 'price', label: '当前价格' },
  { v: 'pct', label: '收益率' },
  { v: 'eta', label: '日抛耗时' },
]
/* 各排序键的默认方向；signal 为复合排序不参与方向切换。eta 默认升序：
   日抛视角「最快到价」在前，慢的/无估计的沉底 */
const SORT_DIR = { profit: 'desc', chg: 'desc', rank: 'asc', price: 'desc', pct: 'desc', eta: 'asc', signal: null }
const state = reactive({ signal: 'all', grade: 0, dayTrade: false, q: '', sort: 'signal', dir: null })

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
  state.dayTrade = false
  state.q = ''
}

const SIGNAL_ORDER = { BUY: 0, SELL: 1, WATCH: 2, WAIT: 3 }
const items = computed(() => market.value?.items || [])

/* ---------- 日抛（day-trade）：现价买入，24h 内能否有利润地卖出去 ----------
   口径单一源在 @shared/js/sellEta.js dayTradeEta / isDayTradeItem：卖价锚 =
   现价的税后回本线 + 利润下限（现价 × (1+5%)/(1−税率)，到价卖出即税后净赚
   5%），近 7 天「现价档 → 该卖价」的完整上涨段 ≥2 段、中位历时 ≤24h（挂单
   24h 费率档）才命中。不锚 P75 目标价（那是跨日持有计划的口径）——刚崩新低
   的弹判的是「从这一价位出发的当日修复力」，有历史先例才认，无先例（接飞刀）
   如实拒绝。etaMap 存全量（含中位超 24h 的「有节奏但慢」），供「日抛耗时」
   列与排序如实展示；命中数随市场状态起伏，chip 计数先行告知。 */
const dayNetPct = Math.round(DAY_TRADE_MIN_NET_PCT * 100)
const etaMap = computed(() => {
  const m = new Map()
  for (const i of items.value) {
    const e = dayTradeEta(i)
    if (e) m.set(i.name, e)
  }
  return m
})
const isDayTrade = (i) => {
  const e = etaMap.value.get(i.name)
  return e ? isDayTradeItem(i, e) : false
}
const dayTradeCount = computed(() => items.value.reduce((n, i) => n + (isDayTrade(i) ? 1 : 0), 0))
/* 耗时单元格紧凑格式：一律小时（17 → 「17h」），完整中文文案与卖价锚在悬浮 title */
const etaCell = (i) => {
  const e = etaMap.value.get(i.name)
  return e ? `${Math.round(e.medianH)}h` : '—'
}
const etaTitle = (i) => {
  const e = etaMap.value.get(i.name)
  if (!e) return '现价无可参照的历史上涨段（处 7 天新低 / 新高或样本不足），无法估计日抛耗时'
  const hit = e.medianH <= DAY_TRADE_MAX_H
  return `历史中位 ${fmtHours(e.medianH)}（${e.episodes} 次样本）：现价涨到税后净利 ≥${dayNetPct}% 卖价（${fmt(e.sellFor)}）的耗时${hit ? '，满足日抛门槛' : `，超 ${DAY_TRADE_MAX_H} 小时不满足日抛`}`
}
const dayTradeTip = computed(() =>
  `只看「现价买入后 ${DAY_TRADE_MAX_H} 小时内能涨到税后净利 ≥${dayNetPct}% 卖价」的弹（历史上涨段中位，样本 ≥2），当前命中 ${dayTradeCount.value} 种；再点一次取消`)

const filtered = computed(() => {
  let list = items.value
  if (state.signal === 'star') list = list.filter((i) => stars.value.has(i.name))
  else if (state.signal !== 'all') list = list.filter((i) => i.signal === state.signal)
  if (state.grade) list = list.filter((i) => i.grade === state.grade)
  /* 日抛 toggle 与信号/品级/搜索是「与」组合：信号锚定当下该买还是该卖，
     日抛约束一轮买卖的完成时限——日抛 × 关注正是「今天低位进场」的候选名单 */
  if (state.dayTrade) list = list.filter(isDayTrade)
  if (state.q.trim()) {
    const q = state.q.trim().toLowerCase()
    list = list.filter((i) => i.name.toLowerCase().includes(q))
  }
  /* 缺失值哨兵按最终方向取号（同构雷达页）：降序取向里 -Inf 沉底，asc 经
     m 翻转后 +Inf 才仍沉底——恒 -Inf 会让升序把「数据不足」行置顶 */
  const num = (x) => (Number.isFinite(x) ? x : state.dir === 'asc' ? Infinity : -Infinity)
  // sorters 统一「降序取向」，方向由 state.dir 的乘子在最后统一翻转
  const sorters = {
    signal: (a, b) =>
      SIGNAL_ORDER[a.signal] - SIGNAL_ORDER[b.signal] || num(b.profitPct) - num(a.profitPct),
    profit: (a, b) => num(b.profitPerRound) - num(a.profitPerRound),
    chg: (a, b) => num(b.chg24h) - num(a.chg24h),
    rank: (a, b) => num(b.rank) - num(a.rank),
    price: (a, b) => num(b.current) - num(a.current),
    pct: (a, b) => num(b.profitPct) - num(a.profitPct),
    eta: (a, b) => num(etaMap.value.get(b.name)?.medianH) - num(etaMap.value.get(a.name)?.medianH),
  }
  const pin = (a, b) => Number(stars.value.has(b.name)) - Number(stars.value.has(a.name))
  const base = sorters[state.sort]
  const m = state.dir === 'asc' ? -1 : 1
  const hasDir = !!SORT_DIR[state.sort]
  return [...list].sort((a, b) => pin(a, b) || (hasDir ? m * base(a, b) : base(a, b)))
})

/* 筛选/排序/自选变化也重算横滑渐隐：行数增减会改变 scrollWidth，不重算的话
   有行→空态的切换会残留 can-scroll（渐隐罩住空态行的「清除全部筛选」按钮） */
watch(filtered, () => nextTick(syncTblFade))

/* ---------- 行展开（桌面 ≥681px）/ 详情页跳转（手机 ≤680px） ----------
   展开面板 td 跨满表内容宽（手机 >600px），按钮带与图表半截落在视口外，
   且嵌在横向滚动容器里、内外滚动方向打架——窄屏点行不再就地展开，改为
   跳转 /ammo/item/:name 独立详情页（返回即回全表；弹名 encodeURIComponent，
   实名含引号/空格/斜杠），详情页承载同一套图表与口径脚注。断点与 CSS
   --bp-mobile 680px 同源（base.css 断点表），matchMedia 变更监听随挂卸 */
const mqNarrow = matchMedia('(max-width: 680px)')
const isNarrow = ref(mqNarrow.matches)
const onMqChange = (e) => { isNarrow.value = e.matches }
const goToItem = (name) => router.push(`/ammo/item/${encodeURIComponent(name)}`)
const expanded = ref(null)
const toggle = (name) => {
  if (isNarrow.value) { goToItem(name); return }
  expanded.value = expanded.value === name ? null : name
  if (expanded.value) scrollToExpander('nearest')
}
const scrollToExpander = (block) => {
  nextTick(() => {
    /* 展开面板以 grid-rows 0fr→1fr 铺开（--t-panel .25s，见 .exp-clip）：t=0 时
       高度近似 0，scrollIntoView 按半高判「已可见」会漏滚——等铺开再定位
       （RM 下无动画直滚）；260ms ≈ --t-panel 收尾 */
    const go = () => document.querySelector('tr.expander')?.scrollIntoView({
      block,
      behavior: reduceMotion() ? 'auto' : 'smooth',
    })
    if (reduceMotion()) { go(); return }
    setTimeout(go, 260)
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
const searchRef = ref(null)
const searchArmed = ref(false) // openFromSell 自动写入搜索词后的示意高亮态，手动输入 / ✕ 即解除
function openFromSell(i) {
  /* 手机上与点行同动线：直达该弹详情页（就地展开的面板在窄屏不可用） */
  if (isNarrow.value) { goToItem(i.name); return }
  state.signal = 'all'
  state.grade = 0
  state.q = i.name
  expanded.value = i.name
  // 搜索词是程序写入的：高亮 + 聚焦搜索框示意「全表正被它筛到 1 行」，✕
  // 一键还原；preventScroll 不抢 scrollIntoView 的滚动定位
  searchArmed.value = true
  nextTick(() => searchRef.value?.focus({ preventScroll: true }))
  scrollToExpander('center')
}
function clearSearch() {
  state.q = ''
  searchArmed.value = false
  searchRef.value?.focus({ preventScroll: true })
}
/* 总览格 / 空态动作 → 全表筛选联动：设置信号筛选并滚到全表（与卖出迷你卡
   openFromSell 同族的快捷动线——「这里看到数字，一步跳到明细」） */
function jumpSignal(v) {
  state.signal = v
  nextTick(() => {
    allSecRef.value?.scrollIntoView({ block: 'start', behavior: reduceMotion() ? 'auto' : 'smooth' })
  })
}
function showAllSell() {
  jumpSignal('SELL')
}
/* 无买入空态的出口：低位「关注」正是买入候补，直接筛出来看 */
function showWatch() {
  jumpSignal('WATCH')
}

const buyList = computed(() => items.value.filter((i) => i.signal === 'BUY').sort((a, b) => b.profitPct - a.profitPct))
const sellList = computed(() => items.value.filter((i) => i.signal === 'SELL').sort((a, b) => b.rank - a.rank))

/* 数据时刻（快照曲线末点的墙钟小时，不用设备本地时间——口径同 MarketClock）：
   传给页尾 Playbook 点亮「当前所处时段窗」。与 MarketClock 各算一次同源纯函数
   （162 弹 × 小时曲线，computed 缓存、随快照 60s 一算），换取兄弟组件间
   零事件耦合——数据流单向，Playbook 仍不接触行情数据本体 */
const clock = computed(() => marketClock(items.value))
const clockHour = computed(() => clock.value?.dataHour ?? null)
/* 市场时钟判读（buy=日内低位扫货窗 / sell=高位出货窗 / wait=中段）：
   BUY 信号区在「出货窗」给出等待提示（纯展示层，不改 analyze 的信号判定） */
const clockVerdict = computed(() => clock.value?.verdict ?? null)

/* ---------- 预计卖出时间（展开行脚注）：文案单一源 ./ammo/etaLine.js，
   经 ./ammo/ItemNotes.vue 渲染（详情页同款内容共用同一组件） ---------- */

/* ---------- 表头口径 popover 定位（G 项）：popover API 打开时默认在视口居中，
   读触发按钮 rect 就地落到按钮下方（popover 元素渲染进 top layer，不受
   .tbl-scroll 的 overflow / mask 裁剪）。toggle 事件不冒泡，捕获阶段在
   document 上统一接，一个监听管两个列提示层 ---------- */
/* 触发钮追踪：同 id 的触发钮有多个（每行偏离 ⚠ 共用 thpop-official），toggle
   事件本身拿不到 invoker，querySelector 恒命中 DOM 第一个——点第 N 行的 ⚠
   浮层会落到第 1 行旁。捕获 click 先记下真正的触发钮（invoker 的 show 是
   click 派发完成后的默认行为，时序保证 toggle 前必有一次触发钮 click）；
   触发钮已被静默刷新重建（isConnected 为 false）时退回 querySelector 兜底 */
let popInvoker = null
function onPopInvokerClick(e) {
  const btn = e.target.closest?.('[popovertarget]')
  if (btn) popInvoker = btn
}
function onThPopToggle(e) {
  const pop = e.target
  if (!e.newValue || !pop?.classList?.contains('th-pop')) return
  const btn = popInvoker?.isConnected && popInvoker.getAttribute('popovertarget') === pop.id
    ? popInvoker
    : tblRef.value?.querySelector(`[popovertarget="${pop.id}"]`)
  if (!btn) return
  const r = btn.getBoundingClientRect()
  /* 左缘贴按钮、越界内收；向下展开、近底时上提——固定落位不跟指针 */
  pop.style.left = `${Math.max(8, Math.min(r.left, window.innerWidth - 312))}px`
  pop.style.top = `${Math.min(r.bottom + 6, window.innerHeight - 160)}px`
}

/* ---------- 生命周期：快照数据链（load / SSE / 分档轮询 / visibility 补拉 /
   其卸载清理）在 useSnapshotFeed 内随本组件挂卸；这里只剩页级专属 ---------- */
onMounted(() => {
  prevTitle = document.title
  document.title = '三角洲行动 · 子弹行情'
  // 深链回填：/ammo?q=弹名（TTK 页「现价」入口跳转进来直接筛到该弹）。
  // 只在进入时消费一次，之后的搜索词变化属用户本地状态，不回写 URL
  const q = typeof route.query.q === 'string' ? route.query.q.trim().slice(0, 40) : ''
  if (q) state.q = q
  clockTimer = setInterval(() => { nowTs.value = Date.now() }, 60 * 1000)
  mqNarrow.addEventListener('change', onMqChange)
  document.addEventListener('toggle', onThPopToggle, true) // 捕获：toggle 不冒泡
  document.addEventListener('click', onPopInvokerClick, true) // 捕获：popover 触发钮追踪（见 onThPopToggle 注释）
  window.addEventListener('resize', syncTblFade)
  window.addEventListener('keydown', onGlobalKeydown)
})
onUnmounted(() => {
  document.title = prevTitle
  clearInterval(clockTimer)
  mqNarrow.removeEventListener('change', onMqChange)
  if (notifyTipTimer) clearTimeout(notifyTipTimer)
  if (flashTimer) clearTimeout(flashTimer)
  if (ctlRO) ctlRO.disconnect()
  document.removeEventListener('toggle', onThPopToggle, true)
  document.removeEventListener('click', onPopInvokerClick, true)
  window.removeEventListener('resize', syncTblFade)
  window.removeEventListener('keydown', onGlobalKeydown)
})
</script>

<template>
  <div ref="pageRef" class="wrap page">
    <!-- 页头（紧凑单行：标题降档 + 新鲜度/来源/通道短语右置，详情悬浮可见） -->
    <header class="compact-head">
      <h1>子弹价格监控<span class="live-dot" :class="{ stale: ageMin !== null && ageMin > thresholds.staleDotMin }" aria-hidden="true"></span></h1>
      <p v-if="market" class="meta" :title="headTip">{{ srcShort }}</p>
      <!-- 浏览器通知开关：非安全上下文（http 部署）无 Notification 对象，置灰如实降级 -->
      <button
        class="notify-btn" :class="{ on: notifyOn }" :disabled="!NOTIFY_SUPPORTED"
        :aria-pressed="notifyOn" :title="notifyBtnTitle"
        @click="toggleNotify"
      ><i class="nt-dot" aria-hidden="true"></i>信号通知{{ notifyOn ? ' · 开' : '' }}</button>
    </header>
    <p v-if="!NOTIFY_SUPPORTED" class="notify-hint">浏览器通知需 HTTPS 部署后可用</p>
    <!-- 开关反馈提示：淡入淡出（MOTION.md §3-F，.swap 进场带 6px 上移） -->
    <Transition name="swap">
      <p v-if="notifyTip" class="notify-hint" role="status">{{ notifyTip }}</p>
    </Transition>

    <!-- 数据过期提醒（moligod 30min / kkrb 6h，文案如实注明静态快照边界）。
         「刷新数据」按钮在全表控制条（首屏外），提示最刺眼时就地给出口；
         进出场淡入淡出（MOTION.md §3-F） -->
    <Transition name="swap">
      <p v-if="ageMin !== null && ageMin > thresholds.staleTipMin" class="state-tip stale-tip" role="status">
        {{ staleTipMsg }}
        <button class="retry" :disabled="refreshing" @click="load({ silent: true })">{{ refreshing ? '刷新中…' : '立即刷新' }}<!-- 内联小环与控制条刷新 chip 同款：进行中进度语义（MOTION.md §3-F，RM 下保留） --><i v-if="refreshing" class="mini-spin" aria-hidden="true"></i></button>
      </p>
    </Transition>

    <!-- 加载 / 空 / 错 / 就绪四态互切（MOTION.md §4.1，P0）：首载骨架屏 → 内容
         .swap 淡切（离场只淡出、进场带 6px 上移），四态各包单根 div 以 loadState
         为 key；.state-card 类名保留在空/错态内部（smoke.mjs 依赖） -->
    <Transition name="swap" mode="out-in" @enter="onStateRootEnter">
      <div v-if="loadState === 'loading'" key="loading" class="state-root sk-hold">
        <!-- 骨架预告真实首屏主体：全量表 8 行（占位结构见 SkeletonView / motion.css，
             全局 .sk-hold 的 max(560px, 60vh) 兜底首屏不空；与雷达页同构） -->
        <SkeletonView variant="table" :rows="8" />
      </div>
      <div v-else-if="loadState === 'empty'" key="empty" class="state-root">
        <div class="state-card">
          <p>还没有行情数据。</p>
          <p class="dim">行情快照正在准备中，稍后再来看看。</p>
        </div>
      </div>
      <div v-else-if="loadState === 'error'" key="error" class="state-root">
        <div class="state-card">
          <p>行情加载失败：{{ loadError }}</p>
          <button class="retry" @click="load()">重试</button>
        </div>
      </div>
      <div v-else key="ready" class="state-root">
        <!-- 我的囤货台账：./ammo/PositionLedger.vue（props 传 items/rules，有持仓才
             渲染）——浮盈按「挂目标价税后到手」口径，现价已达挂卖价的行高亮可出，
             现价闪变（diffPriceFlash）随迁子组件；全表「记入囤货」经 quickAddPosition
             写入并滚到此处，行为与样式沿抽出前 -->
        <PositionLedger ref="ledgerRef" :items="items" :rules="rules" />

        <!-- 买入信号 -->
        <section v-if="buyList.length" class="block reveal">
          <div class="block-h">
            <span class="bht">买入信号</span><span class="bhline"></span>
            <span class="bhc">{{ buyList.length }} 种 · 按预期收益率排序</span>
          </div>
          <!-- 市场时钟判读为「出货窗」（日内高位）时提示等回落：展示层提示，
               不改 analyze 信号（信号本身已含企稳/趋势门槛，见「计算口径」） -->
          <p v-if="clockVerdict === 'sell'" class="more-tip buy-clock-tip">
            市场时钟判读：当前处日内高位窗，追高扫货易买在时段顶部——不急可等低位窗（通常 02:00–05:00）再进场。
          </p>
          <div class="sig-grid">
            <SignalCard v-for="i in buyList.slice(0, 6)" :key="i.name" :item="i" :rules="rules" />
          </div>
          <p v-if="buyList.length > 6" class="more-tip">其余 {{ buyList.length - 6 }} 种买入信号见下方全表（筛选「买入」）。</p>
        </section>
        <!-- 买入空态：从裸虚线段升级为结构化空态卡——左侧信号匣（切角匣同族）+
             标题句 + 门槛说明，右侧给「低位关注」直达（那正是买入候补名单） -->
        <div v-else class="no-buy reveal" role="status">
          <i class="nb-ic" aria-hidden="true">
            <svg viewBox="0 0 16 16"><rect x="4.9" y="4.9" width="6.2" height="6.2" transform="rotate(45 8 8)" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/></svg>
          </i>
          <div class="nb-body">
            <b class="nb-t">买入信号静默</b>
            <span class="nb-d">当前没有弹种满足「7 天 ≤{{ buyRankPct }}% 分位企稳 + 挂卖税后利润 ≥ {{ buyNetPct }}%」的双重门槛；低位「关注」（≤{{ watchRankPct }}%）中的 {{ stats.WATCH }} 个弹种值得留意。</span>
          </div>
          <button class="nb-go press" @click="showWatch">
            查看低位关注
            <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3 8h9M8.5 4.5 12 8l-3.5 3.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>
          </button>
        </div>

        <!-- 卖出信号（迷你卡，点击直达全表走势） -->
        <section v-if="sellList.length" class="block reveal">
          <div class="block-h">
            <span class="bht">卖出信号</span><span class="bhline"></span>
            <span class="bhc">{{ sellList.length }} 种贴近 7 天高位 · 点击查看走势</span>
          </div>
          <div class="sell-grid">
            <SellCard
              v-for="i in sellList.slice(0, 12)" :key="i.name"
              :item="i" :rules="rules" @open="openFromSell(i)"
            />
            <button
              v-if="sellList.length > 12" class="sell-more press"
              aria-label="筛选全部卖出信号" @click="showAllSell"
            >+{{ sellList.length - 12 }} 种</button>
          </div>
        </section>

        <!-- 全量表（控制条吸顶，表容器内滚 + 表头 sticky） -->
        <section ref="allSecRef" class="block reveal">
          <div class="block-h">
            <span class="bht">全部弹药</span><span class="bhline"></span>
            <span class="bhc">{{ filtered.length }} / {{ items.length }} 种</span>
          </div>

          <!-- .tbl-zone：只包控制条 + 表容器（控制条吸顶的包含块）。
               曾把 METHOD 区留在里面给表容器 sticky 当「滑动余量」——页滚时后续
               内容会从吸顶表格背后穿过（行底半透明，文字叠印），已废弃该结构 -->
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
                    <i v-if="s.dot" class="chip-dot" :style="{ background: s.dot }"></i><svg v-if="s.star" class="chip-star" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.6 9.59 6.02 14.28 6.16 10.57 9.03 11.88 13.54 8 10.9 4.12 13.54 5.43 9.03 1.72 6.16 6.41 6.02Z"/></svg>{{ s.label }}
                    <!-- 信号计数挂在筛选动作旁（原页头总览面板的信息密度平移至此，
                         与雷达页 chip-n 同模式）；自选计 stars 集合 -->
                    <span class="chip-n">{{ s.v === 'all' ? items.length : s.v === 'star' ? stars.size : stats[s.v] }}</span>
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
                <!-- 日抛 toggle：与信号/品级单选组不同维度的开关（按住一个约束而非
                     换一个视角），独立 chip 组 + aria-pressed 开关语义；计数先行告知
                     命中量，高位盘整期天然稀少，点了才发现 0 条的挫败感在点击前化解 -->
                <div class="chips" role="group" aria-label="持有周期筛选">
                  <button
                    class="chip chip-dt" :class="{ on: state.dayTrade }"
                    :aria-pressed="state.dayTrade" :title="dayTradeTip"
                    @click="state.dayTrade = !state.dayTrade"
                  >
                    <svg class="chip-dt-ic" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.4" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M8 4.6V8l2.6 1.7" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>日抛
                    <span class="chip-n">{{ dayTradeCount }}</span>
                  </button>
                </div>
                <span class="search-wrap">
                  <input
                    ref="searchRef" v-model.trim="state.q" class="search"
                    :class="{ armed: searchArmed, hasq: state.q }"
                    type="search" placeholder="搜索弹种，如 5.56 / M995" aria-label="搜索弹种"
                    @input="searchArmed = false"
                  >
                  <button v-if="state.q" class="search-clear" aria-label="清除搜索" title="清除搜索" @click="clearSearch">✕</button>
                </span>
                <div class="chips" role="group" aria-label="排序">
                  <button
                    v-for="s in SORTS" :key="s.v"
                    class="chip" :class="{ on: state.sort === s.v }"
                    :aria-pressed="state.sort === s.v"
                    :title="state.sort === s.v && state.dir
                      ? `当前${state.dir === 'desc' ? '降序' : '升序'}，再点切换方向`
                      : null"
                    @click="onSort(s.v)"
                  >{{ s.label }}<svg v-if="state.sort === s.v && state.dir" class="dir" viewBox="0 0 16 16" aria-hidden="true"><path v-if="state.dir === 'desc'" d="M8 3.5v9M4.5 9 8 12.5 11.5 9" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/><path v-else d="M8 12.5v-9M4.5 7 8 3.5 11.5 7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
                </div>
                <button
                  class="chip refresh" title="重新拉取最新快照"
                  :disabled="refreshing" @click="load({ silent: true })"
                >{{ refreshing ? '刷新中…' : '刷新数据' }}<!-- 内联小环 = 「进行中」进度语义
                     （MOTION.md §3-F / 原则 5：RM 下唯一保留的循环动画） --><i v-if="refreshing" class="mini-spin" aria-hidden="true"></i></button>
              </div>
              <!-- 刷新结果提示：淡入淡出（MOTION.md §3-F） -->
              <Transition name="swap">
                <p v-if="refreshTip" class="refresh-tip" :class="refreshTipKind" role="status">{{ refreshTip }}</p>
              </Transition>
              <!-- 日抛开启中的口径提示行：门槛一句话 + 命中数 + 快捷出口（耗时排序）。
                   吸顶常驻而非藏在悬浮 title——触屏没有 hover，口径必须可见可读；
                   关闭即摘除，不给常开页增加永久行高 -->
              <Transition name="swap">
                <p v-if="state.dayTrade" class="refresh-tip dt-tip" role="status">
                  日抛口径：现价买入 ≤{{ DAY_TRADE_MAX_H }} 小时能涨到税后净利 ≥{{ dayNetPct }}% 的卖价（近 7 天上涨段中位，样本 ≥2）· 命中 {{ dayTradeCount }} / {{ items.length }} 种，建议叠加「关注 / 买入」信号使用 · 可按「日抛耗时」排序比快慢
                </p>
              </Transition>
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
                    <th class="c-pen">穿透</th>
                    <th class="num">当前价</th>
                    <th class="num" title="现价相对 24 小时前的涨跌幅（快照曲线末点倒数第 25 个点）">24h</th>
                    <th>信号</th>
                    <!-- 口径提示层（思路库·Popover）：两个最需要口径的列头可点开
                         浮层（popover API 进 top layer，不被表容器的 overflow/mask
                         裁剪；触屏可点开——title 只活在鼠标下）；定位与进出场见
                         .th-pop / onThPopToggle -->
                    <th class="num">
                      <button class="th-help" type="button" popovertarget="thpop-profit">税后预赚·发</button>
                      <div id="thpop-profit" class="th-pop" popover>按近 3 天 75 分位挂卖、扣除交易税（约 15%，逐弹实测反推）后每发的预期到手利润，括号内为对应收益率；触发买入信号要求税后收益率 ≥ 10%。</div>
                    </th>
                    <th class="num c-eta">
                      <button class="th-help" type="button" popovertarget="thpop-eta">日抛耗时</button>
                      <div id="thpop-eta" class="th-pop" popover>现价买入后涨到「税后净利 ≥{{ dayNetPct }}% 卖价（现价回本线 +{{ dayNetPct }}%）」的历史中位历时（近 7 天完整上涨段，样本 ≥2）；≤{{ DAY_TRADE_MAX_H }} 小时即「日抛」，筛选以此为准，「—」= 现价处 7 天新低 / 新高，无可参照的历史先例。与展开行「预计卖出」（锚近 3 天 75 分位目标价）口径不同：那边回答持有到目标价要多久，这边回答当天能否翻一轮。历史统计不代表未来。</div>
                    </th>
                    <th class="num">
                      <button class="th-help" type="button" popovertarget="thpop-rank">7天分位</button>
                      <div id="thpop-rank" class="th-pop" popover>现价处于近 7 天价格区间的位置：≤{{ watchRankPct }}% 贴近低位（绿，关注区；其中 ≤{{ buyRankPct }}% 且满足利差/企稳门槛才触发买入）、≥{{ sellRankPct }}% 贴近高位（红，考虑出货）；分位条上的刻度线就是这几条门槛。</div>
                      <!-- 官方均价口径浮层：⚠ 角标（现价偏离 ≥15% 的行）popovertarget 指到这里 -->
                      <div id="thpop-official" class="th-pop" popover>⚠ = 现价偏离官方均价 ≥15%。官方均价来自腾讯官方对账接口（约 24 小时一轮的「近期平均成交价」，无分钟曲线），只作旁路参照、不进信号；偏离大通常意味着现价刚剧烈波动或上游口径暂漂，操作前先看 7 天走势确认。</div>
                    </th>
                    <th class="num c-range">7天区间</th>
                    <th>走势（7天）</th>
                  </tr>
                </thead>
                <tbody>
                  <template v-for="i in filtered" :key="i.name">
                    <tr
                      class="row data-row" :class="{ open: expanded === i.name }"
                      tabindex="0"
                      :aria-expanded="expanded === i.name"
                      :aria-label="`${i.name}，查看 7 天走势详情`"
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
                        ><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.6 9.59 6.02 14.28 6.16 10.57 9.03 11.88 13.54 8 10.9 4.12 13.54 5.43 9.03 1.72 6.16 6.41 6.02Z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/></svg></button>
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
                        <!-- 军需处可兑换弹（旁路参照）：chip 悬浮给折算摘要，详情在展开行 -->
                        <i
                          v-if="i.trade" class="qm-chip"
                          :title="`军需处可兑换：材料折算 ${fmt(i.trade.costPerRound)}/发（${i.trade.materials.map((m) => `${m.count}×${m.name}`).join(' + ')} → ${i.trade.perCount} 发），现价 ${fmt(i.current)}`"
                        >军</i>
                        <i class="row-chev" aria-hidden="true"><svg viewBox="0 0 16 16"><path d="M4 6.2 8 10.2 12 6.2" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></i>
                      </td>
                      <!-- 穿透（TTK 联动）：无映射显「—」，等级语义与判定矩阵见 TTK 页 -->
                      <td class="c-pen">
                        <PenBadge v-if="penOf(i.name) != null" :p="penOf(i.name)" />
                        <template v-else>—</template>
                      </td>
                      <td class="mono strong num price-cell" :class="priceFlash[i.name]">
                        {{ fmt(i.current) }}<!-- 官方均价旁路参照（§7.5）：偏离 ≥15% 打 ⚠ 提示数据可疑；不进信号 -->
                        <button
                          v-if="i.official && Math.abs(i.official.dev) > OFFICIAL_DEV_WARN"
                          class="off-warn" popovertarget="thpop-official"
                          :aria-label="`${i.name} 现价偏离官方均价 ${(i.official.dev * 100).toFixed(1)}%，点击看口径`"
                          @click.stop
                        >⚠</button>
                      </td>
                      <td class="mono num" :class="i.chg24h == null ? 'dimtx' : i.chg24h >= 0 ? 'up-tx' : 'down-tx'">
                        {{ i.chg24h == null ? '—' : pct(i.chg24h) }}
                      </td>
                      <td>
                        <span v-if="i.rank == null" class="sig wait">数据不足</span>
                        <span v-else class="sig" :class="SIGNAL_META[i.signal].cls">{{ SIGNAL_META[i.signal].label }}</span>
                      </td>
                      <td class="mono num" :class="{ profit: i.profitPerRound > 0 }">
                        {{ i.profitPerRound > 0 ? `+${fmt(i.profitPerRound)}（${pct(i.profitPct)}）` : '—' }}
                      </td>
                      <!-- 日抛耗时（口径见 thpop-eta）：现价→税后回本线+5% 卖价的历史
                           中位历时；日抛命中的行点亮 accent，与 toggle chip 视觉联动——
                           「这行为什么在」就地可见 -->
                      <td class="mono dimtx num c-eta" :class="{ 'eta-ok': isDayTrade(i) }" :title="etaTitle(i)">
                        {{ etaCell(i) }}
                      </td>
                      <td class="num">
                        <div class="rank-cell">
                          <span
                            class="rb-num"
                            :class="{ low: i.rank != null && i.rank <= watchRankPct / 100, high: i.rank != null && i.rank >= sellRankPct / 100 }"
                          >{{ i.rank == null ? '—' : `${Math.round(i.rank * 100)}%` }}</span>
                          <div v-if="i.rank != null" class="rank-bar">
                            <i class="rb-tick buy" :style="{ left: `${buyRankPct}%` }" :title="`买入分位门槛 ≤${buyRankPct}%`"></i>
                            <i class="rb-tick watch" :style="{ left: `${watchRankPct}%` }" :title="`关注分位门槛 ≤${watchRankPct}%`"></i>
                            <i class="rb-tick" :style="{ left: `${sellRankPct}%` }" :title="`卖出分位门槛 ≥${sellRankPct}%`"></i>
                            <i
                              class="rb-fill"
                              :style="{ width: `${Math.round(i.rank * 100)}%` }"
                              :class="{ low: i.rank <= watchRankPct / 100, high: i.rank >= sellRankPct / 100 }"
                            ></i>
                          </div>
                        </div>
                      </td>
                      <td class="mono dimtx num c-range">{{ fmt(i.weekLow) }} ~ {{ fmt(i.weekHigh) }}</td>
                      <td><Sparkline :curve="i.curve" :width="130" :height="30" :end-color="SIG_COLOR[i.signal] || 'var(--faint)'" /></td>
                    </tr>
                    <!-- 展开面板开合双向动画（MOTION.md §3-C〔改〕）：<Transition name="exp">
                         提供进场铺开 + 收起铺收，过渡类与三层结构见 motion.css；v-if 保留，
                         行本身瞬时插入/移除，动的是内容高度——.exp-clip grid-rows 0fr→1fr；
                         原 td 的 padding 与 .exp-actions 的定位锚一并移入 .exp-pad，
                         随 0fr 裁剪同步铺开 -->
                    <Transition name="exp">
                      <tr v-if="expanded === i.name" class="expander">
                        <td colspan="10">
                          <div class="exp-clip">
                            <div class="exp-inner">
                              <div class="exp-pad">
                                <div class="exp-actions">
                                  <!-- 记入囤货（零持仓时的录入通道）：预填现价 × 100 发，数量成本再到台账行内改 -->
                                  <button
                                    class="exp-close exp-pos"
                                    :class="{ on: positions.some((p) => p.name === i.name) }"
                                    :disabled="positions.some((p) => p.name === i.name)"
                                    :title="positions.some((p) => p.name === i.name)
                                      ? '已在囤货台账：数量与成本到页面顶部台账行内修改'
                                      : `按现价 ${fmt(i.current)} × 100 发记入囤货台账，数量与成本可再修改`"
                                    @click="quickAddPosition(i)"
                                  >{{ positions.some((p) => p.name === i.name) ? '已记入囤货 ✓' : '记入囤货' }}</button>
                                  <button class="exp-close" @click="expanded = null">收起</button>
                                </div>
                                <PriceChart :curve="i.curve" :p25="i.p25" :p75="i.p75" :current="i.current" :official="i.official?.avg ?? null" />
                                <!-- 口径脚注组（口径/官方均价/军需处折算/预计卖出）：
                                     详情页共用同一组件（./ammo/ItemNotes.vue） -->
                                <ItemNotes :item="i" />
                              </div>
                            </div>
                          </div>
                        </td>
                      </tr>
                    </Transition>
                  </template>
                  <tr v-if="!filtered.length">
                    <td colspan="10" class="empty-cell">
                      没有符合当前筛选的弹种　<button class="empty-clear" @click="clearFilters">清除全部筛选</button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <!-- 方法与免责（.tbl-zone 之外：常规文档流，不会再钻进吸顶表格背后） -->
          <section class="block reveal">
            <div class="block-h"><span class="bht">计算口径</span><span class="bhline"></span></div>
            <ul class="method">
              <li><b>买入条件</b>（多重门槛，缺一不报）：现价处近 7 天曲线 ≤ {{ buyRankPct }}% 分位（≤ {{ watchRankPct }}% 先列「关注」）；已止跌企稳（高于 7 天低点 ≥3%、近 12 小时无新低、近 48 小时趋势斜率 ≥ +0.02%/h）；按近 3 天 75 分位挂卖、扣除交易税后收益率 ≥ {{ buyNetPct }}%；曲线 ≥ 2 天。随信号给止损位（破 7 天低点 3% 或单笔 −5% 风险上限）与建议持有上限（{{ Math.round(ruleNum('MAX_HOLD_H', 168) / 24) }} 天）。门槛数字随快照 <code>rules</code> 字段下发，与服务端 analyze.mjs 同源。</li>
              <li><b>卖出条件</b>：现价处 ≥ {{ sellRankPct }}% 分位且动能转弱（48 小时斜率不陡增）；强势上冲不催卖。</li>
              <li><b>预计卖出</b>：统计近 7 天小时曲线——「从当前价位档涨到目标挂卖价」的完整上涨段给出中位/最快历时；同小时均价聚合给出日内高位时段。历史统计不代表未来。</li>
              <li><b>日抛</b>：筛「一天之内能完成一买一卖」的弹——卖价锚是现价的税后回本线 + {{ dayNetPct }}%（到价卖出即税后净赚 {{ dayNetPct }}%；日内资金当天可周转两轮，等效于跨日持有一轮的 {{ buyNetPct }}% 利差门槛），近 7 天「现价档 → 该卖价」的完整上涨段 ≥ 2 段、中位历时 ≤ {{ DAY_TRADE_MAX_H }} 小时（24h 即挂单时长档位）才命中。现价处 7 天新低 / 新高的不算——无从该价位出发的历史先例，不接飞刀也不追高；与「关注 / 买入」信号组合，即是「今天低位进场、当天离场」的候选名单。</li>
              <li><b>能赚多少</b>：每发利润 = 目标挂卖价 × (1−税率) − 当前买入价；税率按税后价实测反推（约 15%，逐弹计算）。「回本挂卖价」= 成本 ÷ (1−税率)：15% 税下要在成本之上挂 +17.6% 才不亏，卡上它就不会「看着赚、到手亏」。</li>
              <li><b>官方均价</b>：来自腾讯官方对账接口（约 24 小时一轮的「近期平均成交价」，无分钟曲线），旁路参照、不进信号；现价偏离 ≥15% 的行在当前价列打 ⚠，展开行可看偏离数值。数据：{{ dataLine }}</li>
              <li><b>穿透</b>：来自 TTK 弹药数据（穿透等级决定对各级护甲的伤害通过率，判定矩阵见 TTK 页）。「—」= 无穿透数据（弓弩用弹 / 国服与通用命名差异 / 一名多弹无法确定对应），宁缺勿错。</li>
              <li><b>提醒</b>：交易行价格受版本、活动与大盘供需影响，历史分位不代表未来走势；利润测算未计挂单时间成本。</li>
            </ul>
          </section>
        </section>

        <!-- 全市场日内节律（数据驱动的「现在几点该买该卖」，插在倒卖手册之上：
             静态 WINDOWS 给共识时段，这里给当前快照的实时水位判读，两者互补） -->
        <MarketClock :items="items" />

        <!-- 倒卖手册：社区攻略整理的实操动线（买/卖/版本窗口/卡邮件 + 风险红线）。
             放在 .tbl-zone 之外：不影响表容器 sticky 的包含块余量；
             now-hour 点亮时段条里「当前所处窗」（数据时刻口径，见 clockHour 注释） -->
        <Playbook :now-hour="clockHour" :season="market?.season ?? null" />
      </div>
    </Transition>
  </div>
</template>

<style scoped>
.page { padding-bottom: var(--sp-10); }

/* ---------- 页头（紧凑单行走 base.css .compact-head；live 点与过期着色是本页专属） ---------- */
.live-dot {
  display: inline-block; width: 10px; height: 10px; border-radius: 50%;
  background: var(--ok); margin-left: 10px;
  box-shadow: 0 0 8px var(--ok);
  animation: pulse 2.2s var(--ease) infinite;
}
/* 数据超 1 小时未更新：停止脉冲变灰，live 承诺降级 */
.live-dot.stale { background: var(--faint); box-shadow: none; animation: none; }
@keyframes pulse { 50% { opacity: .35; } }
@media (prefers-reduced-motion: reduce) { .live-dot { animation: none; } }
.meta-stale { color: var(--warn); }

/* ---------- 浏览器通知开关（页头）：非安全上下文置灰；开=accent 点亮 ---------- */
.notify-btn {
  display: inline-flex; align-items: center; gap: 7px;
  background: none; color: var(--dim);
  border: 1px solid var(--line2); border-radius: var(--radius);
  padding: 4px 12px; font-size: var(--fs-xs); white-space: nowrap;
  cursor: pointer; align-self: center;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
}
.notify-btn:hover:not(:disabled) { color: var(--tx); border-color: var(--line); }
.notify-btn.on { color: var(--accent); border-color: var(--accent-dim); }
.nt-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--faint); }
.notify-btn.on .nt-dot { background: var(--accent); box-shadow: 0 0 6px var(--accent); }
.notify-btn:disabled { opacity: .45; cursor: default; }
/* 触屏命中垫层（通用原则 ≥44px）：按钮视觉高仅 ~26px，伪元素四周扩垫补足命中；
   页头该角四周空旷（左侧 meta 文本不承接点击），扩垫不与相邻命中区重叠 */
@media (pointer: coarse) {
  .notify-btn { position: relative; }
  .notify-btn::before { content: ""; position: absolute; inset: -10px; }
}
/* 整句辅助说明按字阶下限 fs-xs（base.css 阶梯注释：fs-2xs 只承载标签类）；
   这也是通知被拒后的补救指引（去哪改权限），是反馈闭环里的可操作信息，
   11px 读不清操作路径 */
.notify-hint { color: var(--faint); font-size: var(--fs-xs); margin: 6px 0 0; }

.state-tip { color: var(--dim); font-size: var(--fs-md); padding: var(--sp-6) 0; }
.stale-tip { color: var(--warn); }
/* 过期提示内嵌的「立即刷新」：主按钮 .retry 的小一号内联变体 */
.stale-tip .retry { font-size: var(--fs-xs); padding: 3px 14px; margin-left: 10px; vertical-align: 1px; }
/* 内联小环在行内文字旁的基线对齐（chip 是 inline-flex 自带 gap，这里是行内 p） */
.stale-tip .retry .mini-spin { margin-left: 5px; vertical-align: -2px; }
.state-card {
  background: var(--card); border: 1px dashed var(--line2); border-radius: var(--radius);
  padding: var(--sp-6); color: var(--tx); margin: var(--sp-4) 0;
}
.state-card .dim { color: var(--faint); font-size: var(--fs-sm); }
/* loading 态骨架根：全表单段；高度兜底走全局 .sk-hold 的 max(560px, 60vh)
   （motion.css，三页统一，MOTION.md §4 验收②③） */
.sk-hold {
  display: flex; flex-direction: column; gap: var(--sp-5);
  padding-top: var(--sp-6); /* 对齐 ready 首屏首块的节奏 */
}
/* 主要按钮（重试/清筛选；台账录入钮同款取值在 PositionLedger.vue）：
   --accent-bg 底 + --accent-dim 边，hover 提底 --accent-soft，
   按下 scale(.98)，禁用降透明；键盘走全局 :focus-visible 外框 */
.retry,
.empty-clear {
  background: var(--accent-bg); color: var(--accent); border: 1px solid var(--accent-dim);
  border-radius: var(--radius); padding: 6px 18px; cursor: pointer; font-size: var(--fs-sm);
  transition: background-color var(--t-med) var(--ease), transform var(--t-fast) var(--ease);
}
.retry:hover,
.empty-clear:hover { background: var(--accent-soft); }
.retry:active,
.empty-clear:active { transform: scale(.98); }
.retry:disabled,
.empty-clear:disabled { opacity: .45; cursor: default; }
.empty-cell { text-align: center; color: var(--dim); padding: var(--sp-6) 0; }

/* iOS Safari 聚焦字号 <16px 的输入会整页自动放大（viewport 未锁 maximum-scale，
   锁了伤无障碍）：移动端把搜索输入临时升到 16px，桌面视觉不变（台账输入的
   同款规则随 PositionLedger.vue 迁出） */
@media (max-width: 680px) {
  .search { font-size: var(--fs-lg); }
}

.sig-grid {
  display: grid; grid-template-columns: repeat(auto-fill, minmax(330px, 1fr)); gap: var(--sp-4);
}
.more-tip { color: var(--faint); font-size: var(--fs-xs); margin-top: var(--sp-3); }
/* BUY 区市场时钟提示（出货窗等回落）：语义由文本承担 */
.buy-clock-tip {
  color: var(--dim);
}
/* ---------- 买入空态卡：信号匣（切角匣同族）+ 结论句 + 低位关注直达 ---------- */
.no-buy {
  margin-top: var(--sp-6);
  display: flex; align-items: center; gap: var(--sp-4);
  padding: var(--sp-4) var(--sp-5);
  background: linear-gradient(180deg, var(--card2) 0%, var(--card) 80%);
  border: 1px solid var(--line); border-radius: var(--radius-lg);
  box-shadow: var(--edge-light);
}
.nb-ic {
  flex: none; width: 42px; height: 42px;
  display: grid; place-items: center;
  color: var(--ok);
  background: var(--deep); border: 1px solid var(--line);
  /* 右上切角：与 SignalCard 图标匣同族的战术弹药匣轮廓 */
  clip-path: polygon(0 0, calc(100% - 11px) 0, 100% 11px, 100% 100%, 0 100%);
}
.nb-ic svg { width: 14px; height: 14px; display: block; }
.nb-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
.nb-t { font-size: var(--fs-sm); font-weight: 600; color: var(--tx-strong); }
.nb-d { font-size: var(--fs-xs); color: var(--dim); line-height: 1.7; }
.nb-go {
  flex: none;
  display: inline-flex; align-items: center; gap: 7px;
  background: var(--accent-bg); color: var(--accent); border: 1px solid var(--accent-dim);
  border-radius: var(--radius); padding: 7px 16px; cursor: pointer; font-size: var(--fs-sm);
  transition: background-color var(--t-med) var(--ease), transform var(--t-fast) var(--ease);
}
.nb-go:hover { background: var(--accent-soft); }
.nb-go:active { transform: scale(.98); }
.nb-go svg { width: 12px; height: 12px; }
/* 窄屏：文案列保持与图标匣并排，按钮换行到文字下方同列对齐——否则按钮
   钉在右侧会把说明挤成每行五六字的细条 */
@media (max-width: 680px) {
  .no-buy { flex-wrap: wrap; row-gap: 10px; }
  .nb-body { flex: 1 1 calc(100% - 42px - var(--sp-4)); }
  .nb-go { margin-left: calc(42px + var(--sp-4)); }
}

/* ---------- 卖出迷你卡网格（卡片本体样式在 SellCard.vue；此处只管排布）。
   auto-fit：信号少于轨道数时（如 3 张卡）收回空轨道让卡撑满行宽，
   分位轨道加长反而更可读 ---------- */
.sell-grid {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(272px, 1fr)); gap: var(--sp-3);
}
.sell-more {
  display: flex; align-items: center; justify-content: center;
  min-height: 96px;
  border: 1px dashed var(--line2); border-radius: var(--radius-lg);
  background: none; color: var(--dim);
  font-family: var(--mono); font-size: var(--fs-xs);
  cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease),
    transform var(--t-fast) var(--ease); /* transform 项服务 .press 按压（motion.css 约定：调用方列表须含 transform） */
}
.sell-more:hover,
.sell-more:active { color: var(--tx); border-color: var(--line-hover); }

/* ---------- 吸顶控制条（复用 base.css .sticky-bar；高度经 RO 写入 --ctl-h，
   供 .tbl-scroll 的 max-height 按视口净高封顶） ---------- */
.ctl-sticky { padding: var(--sp-2) 0; margin-bottom: var(--sp-4); }
/* 吸顶投影滚动驱动（C 项，思路库·滚动驱动动效）：控制条未滚离页头时还在常规
   文档流位、不是「浮在内容之上」，.sticky-bar 常驻的 --shadow-md 是失真的浮空感。
   scroll() 时间线纯 CSS 驱动投影与底边线随页滚渐入（0→96px 段），无 JS 监听。
   @supports 守卫：不支持的时间线退回现状常驻投影；限 ≥681px——移动端控制条
   已还原为 static 常规块（见下方媒体查询），不该在滚动时凭空获得投影。
   animation 声明优先级高于 .sticky-bar 的静态 box-shadow/border，from 帧生效 */
@supports (animation-timeline: scroll()) {
  @media (min-width: 681px) {
    .ctl-sticky {
      animation: ctl-shadow linear both;
      animation-timeline: scroll(root);
      animation-range: 0 96px;
    }
    @keyframes ctl-shadow {
      from { box-shadow: none; border-bottom-color: transparent; }
      to { box-shadow: var(--shadow-md); border-bottom-color: var(--line); }
    }
  }
}
.ctl-bar {
  display: flex; flex-wrap: wrap; align-items: center; gap: var(--sp-4);
}
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chip {
  display: inline-flex; align-items: center; gap: 6px;
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  color: var(--dim); font-size: var(--fs-xs); padding: 4px 12px; cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease), background-color var(--t-fast) var(--ease);
}
/* 按下同 hover（chip/次要按钮规格，与 radar 页对齐）；置于 .on 之前——选中项按下保持选中观感 */
.chip:hover,
.chip:active { color: var(--tx); border-color: var(--line-hover); }
.chip.on { color: var(--accent); border-color: var(--accent-dim); background: var(--accent-bg); }
.chip-dot { width: 6px; height: 6px; border-radius: 50%; }
.chip-star { width: 12px; height: 12px; fill: currentColor; flex: none; }
/* 信号计数（同雷达页 chip-n）：弱化等宽小字缀在标签后，数字即概览 */
.chip-n { font-family: var(--mono); color: var(--faint); }
.chip.refresh { margin-left: auto; }
.chip.refresh:disabled { opacity: .6; cursor: default; }
/* 触屏筛选/排序 chip 与搜索框增高（真实 padding 而伪元素垫层——chips 间 gap
   仅 6px，负 inset 垫层会互相叠命中区，点 A 边缘误触 B）：26px → ~34px，
   视觉与命中同步抬升，代价只是控制条多两行像素；仅粗指针生效，桌面密度不变 */
@media (pointer: coarse) {
  .chip { padding: 8px 14px; }
  .search { padding: 8px 14px; }
}
/* 触屏窄屏搜索框独占一行满宽：16px 防聚焦缩放字号下，placeholder「搜索弹种，
   如 5.56 / M995」约需 ~230px，180px 定宽（净内容区仅 ~152px）必截断，截掉的
   恰是示例词「M995」——新手引导失效。控制条本就 flex-wrap，独占行零结构成本，
   输入命中区同时放大（同 .chip 增高的触屏密度取舍） */
@media (pointer: coarse) and (max-width: 680px) {
  .search-wrap { flex: 1 1 100%; }
  .search { width: 100%; }
}
/* 方向标记（inline SVG）：继承 chip 的 --accent 文字色 */
.dir { width: 10px; height: 10px; margin-left: 2px; color: var(--accent); flex: none; }
.refresh-tip { font-family: var(--mono); font-size: var(--fs-xs); margin-top: 6px; }
.refresh-tip.ok { color: var(--dim); }
.refresh-tip.warn { color: var(--warn); }
/* 日抛 toggle 的时钟图标（同 .dir 家族）：继承 chip 文字色，选中随 .on 转 accent */
.chip-dt-ic { width: 12px; height: 12px; flex: none; }
/* 日抛开启中的口径提示行：中性 dim（区别于刷新结果的 ok/warn 语义） */
.dt-tip { color: var(--dim); }
.search {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  color: var(--tx); font-size: var(--fs-xs); padding: 5px 14px; width: 180px;
  font-family: var(--sans); /* 表单控件不吃 body 字阶，显式声明（同 .qty-in 显式 --mono 的口径） */
  transition: border-color var(--t-fast) var(--ease);
}
/* 键盘可达走全局 :focus-visible 外框；:focus 只做边框提亮，不抹 outline */
.search:focus { border-color: var(--accent-dim); }
/* 搜索框包装：给「✕ 清除」留绝对定位包含块（不占布局位，不挤 chip） */
.search-wrap { position: relative; display: inline-flex; }
/* openFromSell 自动写入搜索词后的示意态：accent 边框 + 微底色，提示全表
   正被该词筛到 1 行；用户手动输入 / ✕ 清除即解除 */
.search.armed { border-color: var(--accent-dim); background: var(--accent-bg); }
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

/* ---------- 全表：内滚容器（max-height + overflow + 表头 sticky）。
   不做页级 sticky：吸顶的表容器会让后续区块从其背后穿过（行底半透明 →
   文字叠印），常规文档流 + 控制条吸顶即够用（同 radar / craft 页口径） ---------- */
.tbl-scroll {
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
/* 吸顶表头浮空投影（滚动驱动，同 .ctl-sticky 手法）：容器内滚动 >0 后表头
   浮在数据行上，恒定 1px 底线不足以分层——投影随滚动 0→32px 渐入。
   scroll(nearest block) 即 th 的最近滚动祖先 .tbl-scroll，纯 CSS 无监听；
   @supports 守卫：不支持的时间线回落上面的静态底线（功能完整）；
   box-shadow 映射无布局成本，投影叠底线复用 --shadow-sm 档 */
@supports (animation-timeline: scroll()) {
  .tbl-scroll .tbl th {
    animation: th-float linear both;
    animation-timeline: scroll(nearest block);
    animation-range: 0 32px;
  }
  @keyframes th-float {
    from { box-shadow: 0 1px 0 var(--line); }
    to { box-shadow: var(--shadow-sm), 0 1px 0 var(--line); }
  }
}

/* ---------- 表头口径提示层（G 项，思路库·Popover）：th-help 承接 th 的全部排版
   （mono 小字属白名单标签类），支持 popover 的浏览器才给虚线下划暗示可点
   （不支持时点击无效，不给暗示误导）；键盘可达走全局 :focus-visible ---------- */
.th-help {
  background: none; border: 0; padding: 0; cursor: default;
  font-family: inherit; font-size: inherit; font-weight: inherit;
  letter-spacing: inherit; color: inherit;
}
@supports selector(:popover-open) {
  .th-help { cursor: help; border-bottom: 1px dotted var(--faint); }
}
/* 提示层本体：popover 渲染进 top layer（不被表容器 overflow/mask 裁剪、触屏可
   点开）；UA 默认居中显示，inset 归零改由 onThPopToggle 读按钮 rect 落位。
   进出场走 @starting-style + allow-discrete（display/overlay 保住离场帧）。
   老浏览器防护：不识别 popover 属性时元素是普通 div 会常显撑爆表头——
   显式 display:none，回退到「无提示」现状（功能完整，非降级） */
.th-pop {
  position: fixed; inset: auto; margin: 0;
  width: min(300px, calc(100vw - 24px));
  background: var(--panel-solid);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  box-shadow: var(--shadow-md);
  padding: 10px 12px;
  font-family: var(--sans);
  font-size: var(--fs-xs);
  line-height: 1.7;
  color: var(--dim);
  transition: opacity var(--t-med) var(--ease), transform var(--t-med) var(--ease),
    display var(--t-med) allow-discrete, overlay var(--t-med) allow-discrete;
}
.th-pop:not(:popover-open) { opacity: 0; transform: translateY(4px); }
@starting-style { .th-pop:popover-open { opacity: 0; transform: translateY(4px); } }
@supports not selector(:popover-open) {
  .th-pop { display: none; }
}
/* 右缘渐隐：仅容器真溢出且未滑到底时出现（桌面无溢出永不显示）。
   mask 直接挂在滚动容器上（相对视口右缘、不随内容横滑）——绝对定位的
   ::after 属于滚动内容，横滑 300px 后会漂进表格中部，形同渲染 bug */
.tbl-scroll.can-scroll:not(.at-end) {
  -webkit-mask-image: linear-gradient(to right, #000 calc(100% - 36px), transparent);
  mask-image: linear-gradient(to right, #000 calc(100% - 36px), transparent);
}

/* 移动端：控制条全量换行高达 280px+，吸顶会占视口 1/3——取消吸顶还原为常规块
   （去掉 sticky-bar 的实底/边框/阴影）；表容器按视口净高封顶，表头 sticky
   在内滚容器里不受影响，浏览主路径不变 */
@media (max-width: 680px) {
  .ctl-sticky {
    position: static;
    background: none;
    border-bottom: 0;
    box-shadow: none;
    padding: 0;
  }
  .tbl-scroll {
    max-height: max(50vh, calc(100vh - 96px));
  }
}

.row { cursor: pointer; }
.row:focus-visible { background: var(--row-hover); }
.row.open { background: var(--accent-bg); }
/* 自选星标（aria-pressed 开关）：关 = --faint 星 + opacity .42，开 = --lv5 金；
   hover（含关态）opacity .8 + 边 --line-hover，按下同 hover */
.star {
  display: inline-flex; align-items: center; vertical-align: middle;
  background: none; border: 1px solid transparent; border-radius: var(--radius-sm);
  padding: 2px; margin: 0 1px 0 -3px;
  color: var(--faint); opacity: .42; cursor: pointer;
  transition: opacity var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease), color var(--t-fast) var(--ease);
}
.star svg { width: 12px; height: 12px; display: block; }
.star.on { color: var(--lv5); opacity: 1; }
.star.on svg path { fill: currentColor; }
.star:hover,
.star:active { opacity: .8; border-color: var(--line-hover); }
/* 行内弹药图标：官方 pic 缩略坐在游戏同款品级底色方框里（品级色染底 + 描边，
   身份与品级合一）；品级色经行内 --gd 下发，染底等图片加载完（.ld）再上，
   加载/失败态仍走 motion.css 占位底。染底 15% / 描边 45% 对齐 iOS GradeBadge
   「12% 底 + 40% 描边」同族，容器面积大故略提一档 */
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
.a-name { color: var(--tx-strong); }
.row-chev {
  display: inline-flex; align-items: center; vertical-align: middle;
  color: var(--faint); margin-left: 6px;
  /* 箭头统一 --t-slow .22s（MOTION.md §3-C 收编）：先转后合，与下方 .exp-clip
     的 .25s 铺开协调成同一动作（原 --t-fast 快一档显割裂） */
  transition: transform var(--t-slow) var(--ease), color var(--t-fast) var(--ease);
}
.row-chev svg { width: 12px; height: 12px; display: block; }
.row.open .row-chev { transform: rotate(180deg); color: var(--accent); }

.rank-cell { display: flex; align-items: center; justify-content: flex-end; gap: 8px; }
.rb-num { font-family: var(--mono); font-size: var(--fs-xs); color: var(--dim); }
.rb-num.low { color: var(--ok); }
.rb-num.high { color: var(--danger); }
/* 分位条阈值刻度：买入线（rules.BUY_RANK_MAX，默认 20%）/ 关注线（35%）/
   卖出线（80%）三分动态，与 METHOD/浮层同源自 rules 下发（不得写死数字）；
   填充按所在区间染渐变绿/红，中性段用暗灰 */
.rank-bar { position: relative; width: 110px; height: 7px; background: var(--line2); border-radius: 4px; }
.rb-tick {
  position: absolute; top: -2px; bottom: -2px; width: 1px;
  background: var(--line-hover);
}
/* 买入/关注两根低位刻度点亮语义色：同 7px 高的条上三根线，卖出线保持中性
   （右侧填充本身已染红，再上色会糊） */
.rb-tick.buy { background: rgba(133, 181, 120, .55); background: color-mix(in srgb, var(--ok) 55%, transparent); }
.rb-tick.watch { background: rgba(133, 152, 181, .5); background: color-mix(in srgb, var(--info) 50%, transparent); }
.rb-fill { position: absolute; top: 0; bottom: 0; left: 0; border-radius: 4px; background: var(--faint); }
.rb-fill.low {
  background: linear-gradient(90deg, rgba(133, 181, 120, .45), var(--ok));
  background: linear-gradient(90deg, color-mix(in srgb, var(--ok) 45%, transparent), var(--ok));
}
.rb-fill.high {
  background: linear-gradient(90deg, rgba(217, 106, 89, .45), var(--danger));
  background: linear-gradient(90deg, color-mix(in srgb, var(--danger) 45%, transparent), var(--danger));
}
@media (max-width: 680px) {
  .c-range { display: none; }
  /* 窄屏控制条本就多行换行，计数缀字加大换行噪音：同雷达页口径隐藏 */
  .chip-n { display: none; }
  /* 穿透列与 7 天区间列同法降级：移动端窄屏隐藏（穿透徽标仍可见于 TTK 页与详情） */
  .c-pen { display: none; }
  /* 日抛耗时列同法隐藏：口径与数值在展开行「预计卖出」仍在，窄屏横滑距离优先；
     日抛筛选本身照常生效（chip 文字自释，不依赖计数） */
  .c-eta { display: none; }
  /* 弹种列整格不折行：容器窄于表格时 auto 布局按「最长不可断单词」压缩首列，
     弹名几乎全被拆成两三行（行高 83/62px 参差）；表格本就横向滚动，让首列
     按完整内容定宽（星标+图标+弹名+箭头一行放下），借用滚动即可 */
  .row td:first-child { white-space: nowrap; }
  /* 同步收窄走势图与分位条补偿列宽，缩短横滑距离（比例不变仅等比缩小） */
  .tbl .spark { width: 100px; height: 23px; }
  .rank-bar { width: 72px; }
}

/* 信号徽章（.sig 家族）收编 base.css：与雷达页/详情页共用（观望降噪口径在彼处） */
/* 主数字立权：预赚（含收益率）才是本表的决策数字——升为行内最重（fs-md + 700，
   .tbl 前缀压过 .tbl .mono 的 fs-xs 特异性）；profit 行有绿底色块成组，扫读锚点唯一 */
.tbl td.profit { color: var(--ok); font-weight: 700; font-size: var(--fs-md); }
/* 日抛耗时列默认 dimtx 素文本；日抛命中行（中位 ≤24h）点亮 accent：
   与 toggle chip 的选中色同源，「这行为什么在筛选结果里」就地可读 */
.tbl td.c-eta.eta-ok { color: var(--accent); }
/* 当前价降半档为行内第二重（tx-strong 色保持醒目）：与预赚并重会让行内
   出现两个「最重」，扫读失去主锚；无信号的行（预赚为 —）当前价自然主导 */
.tbl td.price-cell { position: relative; font-size: var(--fs-sm); color: var(--tx-strong); font-weight: 600; }
/* 官方均价偏离 ⚠ 角标（td 内随文小按钮）：warn 色裸样式，点开 thpop-official 浮层 */
.off-warn {
  border: 0; background: none; padding: 0 0 0 2px;
  color: var(--warn); font-size: var(--fs-2xs); cursor: pointer; vertical-align: 2px;
}
/* 24h 涨跌列：涨绿跌红（涨跌色恒定语义，同 SignalCard 闪变口径），缺失弱化 */
.tbl td.up-tx { color: var(--ok); }
.tbl td.down-tx { color: var(--danger); }
/* 军需处可兑换 chip：弹名旁 mini 徽标（品级底色方框同位语言），warn 色衬「倒挂套利」语义 */
.qm-chip {
  font-style: normal; flex: none;
  font-family: var(--mono); font-size: var(--fs-micro);
  color: var(--warn); border: 1px solid color-mix(in srgb, var(--warn) 45%, transparent);
  border-radius: 3px; padding: 0 3px; margin-left: 4px; cursor: help;
}

/* ---------- 价格闪变（B 项）：diff 出的涨/跌格一次性 0.8s 底色脉冲（思路库口径；
     一次性读数脉冲非循环、不占 MOTION.md §5 循环档位），动效毕 JS 摘类。
     箭头绝对定位进 td 右 padding 区（padding 10px，8px 箭头 @right:1px 占 1–9px、
     文字右缘在 10px，零重叠）——不参与列宽计算：行内箭头会给该列临时加 ~10px
     宽、摘类后回缩，被闪格恰为列最宽格时右侧各列整体横跳（通用原则：数字列
     动效杜绝列宽跳动）。
     箭头是静态等价物——RM 下脉冲关、箭头保留（「涨跌色标保留静态等价物」）；
     keyframes 只声明 from 帧，to 落回单元格自然背景（斑马/hover 底在 tr 上不冲突） */
@keyframes flash-up { from { background-color: color-mix(in srgb, var(--ok) 14%, transparent); } }
@keyframes flash-down { from { background-color: color-mix(in srgb, var(--danger) 14%, transparent); } }
.price-cell.up { animation: flash-up .8s var(--ease) 1; }
.price-cell.down { animation: flash-down .8s var(--ease) 1; }
.price-cell.up::after,
.price-cell.down::after {
  position: absolute; right: 1px; top: 50%;
  transform: translateY(-50%);
  font-size: 8px; line-height: 1;
}
.price-cell.up::after { content: "▲"; color: var(--ok); }
.price-cell.down::after { content: "▼"; color: var(--danger); }

/* 展开面板（MOTION.md §3-C〔改〕，G3）：三层结构（.exp-clip/.exp-inner/.exp-pad）与
   .exp-* 过渡类已提升 motion.css（三页开合双向对齐，含 RM 兜底）。本页只留页级取值：
   .exp-pad 顶部 44px 预留动作条带（按钮带约占顶部 10~37px）——图表「现在」标注挂在
   曲线右端，现价贴近 7 天高点时会落到同一右上角，不预留就被不透明按钮盖住 */
.exp-pad { padding: 44px 10px 9px; }
.expander td {
  position: relative; background: var(--card2); border-top: 1px solid var(--accent-dim);
  padding: 0; /* padding 已移入 .exp-pad（随 0fr 铺开裁剪），td 本体归零 */
}
/* 右上动作组（收起 / 记入囤货）：锚在 .exp-pad，0fr 时随裁剪不可见；按钮本体静态排列 */
.exp-actions { position: absolute; top: 10px; right: 10px; display: flex; gap: 8px; }
.exp-close {
  font-family: var(--mono); font-size: var(--fs-xs); color: var(--dim);
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  padding: 3px 12px; cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
}
.exp-close:hover,
.exp-close:active { color: var(--tx); border-color: var(--line-hover); }
/* 「记入囤货」：与收起同规格；已记入态转 ok 并禁用（不覆盖已录成本） */
.exp-close.exp-pos:disabled { opacity: .7; cursor: default; }
.exp-close.exp-pos.on {
  color: var(--ok);
  border-color: rgba(133, 181, 120, .4); background: rgba(133, 181, 120, .1);
  border-color: color-mix(in srgb, var(--ok) 40%, transparent);
  background: color-mix(in srgb, var(--ok) 10%, transparent);
}
/* 口径脚注组样式（.note 等）随段落抽入 ./ammo/ItemNotes.vue（scoped 自持） */

/* 移动端展开面板：td 跨满表格内容宽（横滑容器下 >600px），绝对定位在宽 td
   右缘的按钮带与自适应到 600px 宽的图表右半都会落到视口外，点开行首屏看不到
   「收起」与现价标注。图与脚注按视口宽封顶渲染（PriceChart 的 ResizeObserver
   随之收窄 viewBox 基准），按钮带改流式置顶、不再钉死在 td 右上角。
   本块须置于 .expander td / .exp-actions 基础规则之后——同特异性靠源序覆盖 */
@media (max-width: 680px) {
  .exp-pad { padding-top: 12px; }
  .exp-actions { position: static; margin: 0 0 10px; max-width: calc(100vw - 56px); }
  .expander .pchart, .expander :deep(.note) { max-width: calc(100vw - 56px); }
}

.method {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-lg);
  padding: var(--sp-4) var(--sp-5);
  list-style: none; color: var(--dim); font-size: var(--fs-sm); line-height: 1.9;
}
.method li { padding-left: 16px; position: relative; }
.method li::before { content: "◆"; position: absolute; left: 0; color: var(--accent-dim); font-size: 8px; top: 7px; }
.method b { color: var(--tx); }

/* ---------- 触控垫层（D 项，通用原则·命中区 ≥44px）：视觉尺寸可以小，但触控
   命中区要补足。仅粗指针设备生效（桌面鼠标的视觉密度不变）；伪元素扩垫只扩
   命中区、不改视觉几何。star 上下相邻行中心距 ≈40px+，各扩 13px 不叠命中区；
   search-clear 自身 absolute 定位（不能改 position 破坏落位），垫层直接相对其
   铺开、左右少扩——避免吃掉输入框尾部的聚焦点击误触「清除」 ---------- */
@media (pointer: coarse) {
  .star { position: relative; }
  .star::before { content: ""; position: absolute; inset: -13px; }
  .search-clear::before { content: ""; position: absolute; inset: -13px -8px; }
  /* 表头口径按钮视觉是 11px 文字、命中过小：padding 扩垫 + 负 margin 抵消布局
     （hit-area 手法，命中高 11→35px、左右各 +8px）。刻意不再多扩——上下方向
     贴着滚动容器顶与第一行可点数据行，再扩就是劫持邻区点击（star
     四周空旷才敢 -13px 全向扩；相邻两个口径列间隙 20px，各扩 8px 不叠） */
  .th-help { padding: 12px 8px; margin: -12px -8px; }
  /* ⚠ 口径角标（行内随文小按钮，视觉仅 ~11px）：同 th-help 的 padding 扩垫 +
     负 margin 抵消手法（inline 元素 padding 不影响行盒几何，视觉零变化）；
     左右只扩 8px——右侧紧贴 td 数字右缘，扩多了劫持相邻列点击 */
  .off-warn { padding: 14px 8px; margin: -14px -8px; }
  /* 展开面板动作钮（视觉高 ~25px）：伪元素垫层保视觉尺寸，上下扩 10px 补到 ~45px。
     刻意不用 padding 法——胶囊钮的 padding 就是视觉本体，改了钮就胖一圈；
     左右只扩 3px——两钮 gap 8px，各扩 3px 不互相叠命中区（3+3<8），宽度本就富余 */
  .exp-close { position: relative; }
  .exp-close::before { content: ""; position: absolute; inset: -10px -3px; }
  /* 错误态重试 / 空筛清除（视觉高 ~27px）：同法补到 ~47px；两键相距远，无叠区 */
  .retry, .empty-clear { position: relative; }
  .retry::before, .empty-clear::before { content: ""; position: absolute; inset: -10px -8px; }
}

/* 本页全部微交互过渡的 reduced-motion 关闭（live-dot 脉冲另有独立规则；
   .swap .flip .exp 与 .a-ic 淡入、.mini-spin 等全局类由 motion.css 文件尾统一兜底） */
@media (prefers-reduced-motion: reduce) {
  .chip, .search, .search-clear, .sell-more, .exp-close, .star, .row-chev,
  .retry, .empty-clear,
  .nb-go { transition: none; }
  .nb-go:active { transform: none; }
  .retry:active, .empty-clear:active { transform: none; }
  /* C 项滚动驱动投影降级为常驻投影（现状）：吸顶「浮在内容上」的语义不随 RM 丢失 */
  .ctl-sticky { animation: none; }
  /* 表头浮空投影同理降级：恒定 1px 底线（from 帧即现状） */
  .tbl-scroll .tbl th { animation: none; }
  /* B 项价格闪变：脉冲关、箭头保留——涨跌色标的静态等价物 */
  .price-cell.up, .price-cell.down { animation: none; }
  /* G 项提示层：瞬开瞬关 */
  .th-pop { transition: none; }
}
</style>
