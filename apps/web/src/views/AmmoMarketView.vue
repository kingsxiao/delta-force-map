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
   口径与 scripts/ammo/analyze.mjs 一致：7 天小时级曲线分位数回归，
   P25 以下买入、P75 以上卖出，利润为税后到手价减买入价。
   版本展示 / 阈值分档 / 通道门槛等纯逻辑在 ./ammo/marketMeta.js（自测共用）。
   页尾 PLAYBOOK 倒卖手册（./ammo/Playbook.vue，静态）：社区攻略整理的
   买卖时段 / 挂单定价 / 版本窗口 / 卡邮件要点与风险红线，与信号区互补。
   TTK 联动：全表「穿透」列按弹名映射 TTK 穿透等级（PenBadge；映射与
   「— = 无穿透数据」口径见 src/data/ttk/ammo-market-alias.js）；进入时
   消费 /ammo?q=弹名 深链回填搜索框（TTK 页「现价」入口）。
   ============================================================ */
import { computed, nextTick, onMounted, onUnmounted, reactive, ref } from 'vue'
import { useRoute } from 'vue-router'
import { useReveal } from '../composables/useReveal'
import { useStars } from '../composables/useStars'
import { usePositions } from '../composables/usePositions'
import { useAccount } from '../composables/useAccount'
import SignalCard from './ammo/SignalCard.vue'
import SellCard from './ammo/SellCard.vue'
import Sparkline from './ammo/Sparkline.vue'
import PriceChart from './ammo/PriceChart.vue'
import Playbook from './ammo/Playbook.vue'
import MarketClock from './ammo/MarketClock.vue'
import PenBadge from './ttk/PenBadge.vue'
import { CAL } from '../data/ttk/calibers.js'
import { marketNamePen } from '../data/ttk/ammo-market-alias.js'
import {
  formatVersionLabel, staleness, methodDataLine,
  liveChannelUrl, isLocalHttpHost, staleTipText, picThumb,
} from '@shared/js/marketMeta.js'
import { createLiveChannel } from '@shared/js/liveChannel.js'
import { predictSellEta, fmtHours, fmtPeak } from '@shared/js/sellEta.js'
import { judgeSignals, sendNotifications } from '@shared/js/notify-policy.js'

const route = useRoute()

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
let prevTitle = '' // 路由标题：进入存默认值，卸载还原（模式同 TtkView）

async function load(opts = {}) {
  const silent = !!(opts.silent && market.value)
  if (silent) refreshing.value = true
  else loadState.value = 'loading'
  try {
    const prevVersion = market.value?.version
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
    // 信号去抖 judge 挂在每次成功刷新上（含首次整页与静默轮询/SSE）：首轮只
    // 建基线不弹，之后 diff 出的新 BUY/SELL 才投递浏览器通知（见通知块注释）
    runNotifyJudge(json, { silent })
    if (silent) {
      // 自动轮询/SSE 触发的刷新只在版本真的前进时提示——纯静态环境快照永不
      // 变化，每分钟闪一次「已更新至 <旧版本>」是在误导；手动点击仍给反馈
      if (!opts.auto || json.version !== prevVersion) {
        refreshTip.value = `已更新至 ${versionLabel.value}`
        refreshTipKind.value = 'ok'
        if (tipTimer) clearTimeout(tipTimer)
        tipTimer = setTimeout(() => { refreshTip.value = '' }, 4000)
      }
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
        ? '行情数据格式异常，请稍后重试'
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
/* 数据版本：12 位分钟档（moligod）显示到 HH:mm，10 位小时档（kkrb）显示 HH:00 */
const versionLabel = computed(() => formatVersionLabel(market.value?.version))

/* ---------- 时效与更新粒度（按 json.source 分档，纯函数在 @shared/js/marketMeta.js） ---------- */
const thresholds = computed(() => staleness(market.value?.source))
const dataLine = computed(() => methodDataLine(market.value?.source))
const staleTipMsg = computed(() => staleTipText(market.value?.source, ageMin.value))

/* ---------- 实时通道（SSE）：本地开发连独立 live 服务（8787），部署形态连
   同源 /events（scripts/server.mjs）。先探测 /health 再连：本地探不到保持
   「未连接」带退避重探（人可能稍后开 live）；非本地且从未连上判「环境
   不适用」退 30min 轮询——纯静态托管的快照永不变化，不打每分钟无效流量。
   连上后断开（服务端部署重启等）不再永久放弃：30s→2min 退避重探 /health，
   恢复后自动回到实时推送（重连助手与雷达页共用 shared/js/liveChannel.js） ---------- */
const LIVE_SSE_URL = liveChannelUrl(location)
const liveChannel = ref('off') // off(环境不适用) | connecting | on | down
let live = null
function connectLive() {
  if (!LIVE_SSE_URL) return
  live = createLiveChannel({
    url: LIVE_SSE_URL,
    events: ['market'],
    isLocal: () => isLocalHttpHost(location),
    onState: (s) => { liveChannel.value = s },
    onEvent: (t, data) => {
      if (t === 'hello') {
        try {
          const meta = JSON.parse(data)
          // hello 携带的版本比页面当前新（页面先于服务连上）：主动补拉一次
          if (market.value && meta.version && meta.version !== market.value.version) {
            load({ silent: true, auto: true })
          }
        } catch { /* hello 数据异常只标记连接态，不影响链路 */ }
      } else if (t === 'market') {
        load({ silent: true, auto: true })
      }
    },
  })
  live.start()
}
const liveText = computed(() => {
  if (liveChannel.value === 'on') return '实时推送已连接，行情更新自动送达'
  if (liveChannel.value === 'down') return '实时推送已断开，自动重连中；期间每 60 秒自动刷新'
  if (liveChannel.value === 'connecting') return '实时推送连接中…'
  return '' // off：纯静态环境不显示，避免误导
})
/* 紧凑页头右列短语：更新粒度短标（完整版本号与通道全文在悬浮
   title；本地 live/monitor 工具说明移 METHOD，不再占页头） */
const srcShort = computed(() => {
  const s = market.value?.source
  return s === 'moligod' ? '分钟级' : s === 'kkrb' ? '小时级' : ''
})
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

/* ---------- 展示工具 ---------- */
const fmt = (n) => (Number.isFinite(n) ? Math.round(n).toLocaleString('zh-CN') : '—')
const pct = (n) => (Number.isFinite(n) ? `${n >= 0 ? '+' : ''}${(n * 100).toFixed(1)}%` : '—')
/* 带符号金额（囤货浮盈可为负）：+12,345 / -1,024 */
const fmtSigned = (n) => (Number.isFinite(n) ? `${n >= 0 ? '+' : '-'}${Math.abs(Math.round(n)).toLocaleString('zh-CN')}` : '—')
const SIGNAL_META = {
  BUY: { label: '买入', cls: 'buy' },
  WATCH: { label: '关注', cls: 'watch' },
  SELL: { label: '卖出', cls: 'sell' },
  WAIT: { label: '观望', cls: 'wait' },
}
/* 迷你走势末点语境色（Sparkline endColor）：与信号徽章同语义——BUY ok /
   SELL danger / WATCH info / WAIT（含数据不足行）faint */
const SIG_COLOR = { BUY: 'var(--ok)', SELL: 'var(--danger)', WATCH: 'var(--info)', WAIT: 'var(--faint)' }
const gradeVar = (g) => (g >= 2 && g <= 6 ? `var(--lv${g})` : 'var(--faint)')
const reduceMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches
// 表内行图标加载失败（CDN 抖动等）就地隐藏，不占位不报错
const hideImg = (e) => { e.target.style.display = 'none' }

/* ---------- TTK 联动：弹名 → 穿透等级（PenBadge 徽标，等级语义 0-7） ----------
   映射与「宁缺勿错」口径见 src/data/ttk/ammo-market-alias.js：一对多歧义
   （紫/蓝/金.300BLK）、国服命名无同型条目（DBP10 等）与弓弩箭矢返回 null，
   穿透列显「—」（表尾 METHOD 注明），绝不猜等级。 */
const penOf = (name) => marketNamePen(name, CAL)

/* ---------- 行情脉搏：全市场信号分布（页头总览条） ---------- */
const stats = computed(() => {
  const c = { BUY: 0, SELL: 0, WATCH: 0, WAIT: 0 }
  for (const i of items.value) if (c[i.signal] != null) c[i.signal]++
  return c
})

/* ---------- 自选星标 + 囤货台账（useStars / usePositions 单例：localStorage
   持久化 + 账号云同步挂钩，登录后由 useAccount 做两端合并，见 /account 页） ---------- */
const { stars, toggleStar } = useStars()
const { positions, save: savePositions } = usePositions()
const { user: accountUser } = useAccount() // 仅用于台账区块的云同步状态标（同步逻辑全在 useAccount 单例内）

/* 台账行 join 行情快照：弹名已不在当前快照（下架 / 改名）时 item=null，只展示记录本体 */
const positionRows = computed(() =>
  positions.value.map((p) => {
    const item = items.value.find((i) => i.name === p.name) || null
    const netSell = item?.netSell ?? null // 挂 P75 税后到手 / 发
    const netNow = item && item.current != null && Number.isFinite(item.taxRate)
      ? item.current * (1 - item.taxRate) : null // 现价直出税后 / 发
    return {
      ...p,
      item,
      netSell,
      netNow,
      /* 到价浮盈（挂 P75 口径）与现价浮盈（直出口径） */
      gainNet: netSell != null ? (netSell - p.cost) * p.qty : null,
      gainNow: netNow != null ? (netNow - p.cost) * p.qty : null,
      atTarget: !!(item && item.current != null && item.targetSell != null && item.current >= item.targetSell),
    }
  })
)
const posTotals = computed(() => {
  let invest = 0
  let gainNet = 0
  let gainNow = 0
  for (const r of positionRows.value) {
    invest += r.cost * r.qty
    if (r.gainNet != null) gainNet += r.gainNet
    if (r.gainNow != null) gainNow += r.gainNow
  }
  return { invest, gainNet, gainNow, pct: invest > 0 ? gainNet / invest : null }
})
function upsertPosition(p) {
  const first = positions.value.length === 0
  // 只入账本事实三字段：调用方可能传台账行 join 行情后的展示对象（含 item/curve），
  // 整体入库会污染 localStorage 与云端 ledger.ammo（多次编辑即超 64KB 上限）
  const clean = { name: p.name, qty: p.qty, cost: p.cost }
  const i = positions.value.findIndex((x) => x.name === clean.name)
  if (i >= 0) positions.value[i] = clean
  else positions.value.push(clean)
  savePositions()
  // 首条持仓让台账区块从无到有：区块带 .reveal（默认 opacity:0），中途出现的
  // 元素不在 load 成功后的 observeRoot 批次里，这里补一次 observe 否则永远隐藏
  if (first) nextTick(() => observeRoot(pageRef.value))
}
function removePosition(name) {
  positions.value = positions.value.filter((p) => p.name !== name)
  savePositions()
}
/* 删除二次确认（防误触）：✕ 紧挨行内数字输入、触屏易点偏，一步即删不可恢复；
   首点进入「确认」待定态（3 秒后自动解除），再点同一行才真正删除 */
const posDelArm = ref(null)
let posDelTimer = null
function onPosDel(name) {
  if (posDelArm.value === name) {
    removePosition(name)
    disarmPosDel()
    return
  }
  posDelArm.value = name
  if (posDelTimer) clearTimeout(posDelTimer)
  posDelTimer = setTimeout(disarmPosDel, 3000)
}
function disarmPosDel() {
  posDelArm.value = null
  if (posDelTimer) { clearTimeout(posDelTimer); posDelTimer = null }
}
/* 行内编辑数量 / 成本（change 时写回；夹取规范值防 0 / 负数入库） */
function setPosQty(r, ev) {
  const n = Math.round(Number(ev.target.value))
  upsertPosition({ ...r, qty: Number.isFinite(n) && n >= 1 ? n : r.qty })
  ev.target.value = r.qty
}
function setPosCost(r, ev) {
  const n = Number(ev.target.value)
  upsertPosition({ ...r, cost: Number.isFinite(n) && n > 0 ? n : r.cost })
  ev.target.value = r.cost
}
/* 添加表单（弹名从当前行情里选——datalist 联想；成本留空默认现价，方便信号位快速记入） */
const posForm = reactive({ name: '', qty: 100, cost: '' })
const posFormErr = ref('')
function addPosition() {
  const name = posForm.name.trim()
  const item = items.value.find((i) => i.name === name)
  if (!item) { posFormErr.value = '弹名需从当前行情中选择（输入框可联想补全）'; return }
  const qty = Math.round(Number(posForm.qty))
  if (!Number.isFinite(qty) || qty < 1) { posFormErr.value = '数量至少为 1 发'; return }
  const cost = posForm.cost === '' ? item.current : Number(posForm.cost)
  if (!Number.isFinite(cost) || cost <= 0) { posFormErr.value = '成本价需为正数（留空按现价记入）'; return }
  upsertPosition({ name, qty, cost })
  posForm.name = ''
  posForm.qty = 100
  posForm.cost = ''
  posFormErr.value = ''
}
/* 全表行展开「记入囤货」：零持仓时的录入通道（区块本身有持仓才显示）——
   预填现价 × 100 发，数量与成本再到台账行内改；已在台账不覆盖用户已录成本 */
const posSecRef = ref(null)
function quickAddPosition(i) {
  if (positions.value.some((p) => p.name === i.name)) return
  upsertPosition({ name: i.name, qty: 100, cost: i.current })
  // 记入后滚到台账区：用户在全表中下部展开行，台账在页头之下，不滚可能根本注意不到
  nextTick(() => {
    posSecRef.value?.scrollIntoView({ block: 'center', behavior: reduceMotion() ? 'auto' : 'smooth' })
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
  /* 缺失值哨兵按最终方向取号（同构雷达页）：降序取向里 -Inf 沉底，asc 经
     m 翻转后 +Inf 才仍沉底——恒 -Inf 会让升序把「数据不足」行置顶 */
  const num = (x) => (Number.isFinite(x) ? x : state.dir === 'asc' ? Infinity : -Infinity)
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
const searchRef = ref(null)
const searchArmed = ref(false) // openFromSell 自动写入搜索词后的示意高亮态，手动输入 / ✕ 即解除
function openFromSell(i) {
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
function showAllSell() {
  state.signal = 'SELL'
  nextTick(() => {
    allSecRef.value?.scrollIntoView({ block: 'start', behavior: reduceMotion() ? 'auto' : 'smooth' })
  })
}

const buyList = computed(() => items.value.filter((i) => i.signal === 'BUY').sort((a, b) => b.profitPct - a.profitPct))
const sellList = computed(() => items.value.filter((i) => i.signal === 'SELL').sort((a, b) => b.rank - a.rank))

/* ---------- 预计卖出时间（展开行脚注；数据不足返回 null 不渲染） ----------
   买入/关注：历史到达历时（中位/最快）+ 日内高位时段；卖出：已在挂卖区，
   只给「今天几点出」的日内高位建议。口径见 ./ammo/sellEta.js 与 METHOD。 */
function etaLine(i) {
  const e = predictSellEta(i)
  if (!e) return null
  const peak = e.peakStart != null ? fmtPeak(e.peakStart, e.peakEnd) : null
  if (e.atTarget) {
    return peak
      ? `现价已处挂卖区，日内高位通常在 ${peak}，建议在该时段分批挂卖。`
      : '现价已处挂卖区，建议尽快挂卖。'
  }
  // 历时展示门槛：至少 2 次完整上涨样本（单样本中位没有置信度）
  if (e.medianH == null || e.episodes < 2) return null
  const clock = e.etaLabel ? `（${e.etaLabel} 前后）` : ''
  const base =
    `按近 7 天 ${e.episodes} 次同类上涨，从现价涨到 ${fmt(i.targetSell)}（P75）` +
    `中位约 ${fmtHours(e.medianH)}、最快 ${fmtHours(e.fastestH)}${clock}`
  return peak ? `${base}；该弹种日内高位通常在 ${peak}。` : `${base}。`
}

/* ---------- 生命周期：SSE + 静默轮询 + 分钟钟 + 全局监听（统一在此挂/卸） ---------- */
/* 轮询节奏按环境分档：live 通道不适用（https/file 纯静态部署，market.json 永不
   变化）时退回 30 分钟，避免 60s×缓存穿透对静态主机打无效流量（快照约
   400KB，60s 轮 ≈ 23MB/小时/标签页）；本地 http（live 已连或 monitor/手动
   fetch 在写盘）保持 60s。逐轮重排而非固定 setInterval，节奏可随通道状态切换 */
function schedulePoll() {
  const delay = liveChannel.value === 'off' ? 30 * 60 * 1000 : 60 * 1000
  pollTimer = setTimeout(() => {
    if (document.visibilityState === 'visible' && market.value) load({ silent: true, auto: true })
    schedulePoll()
  }, delay)
}
/* 回前台补拉：后台期间 schedulePoll 的可见检查会跳过拉取，切回最坏要
   等下个周期（off 档 30min）；数据龄已过变灰阈值就直接补一次，不等 tick */
function onVisibility() {
  if (document.visibilityState !== 'visible') return
  nowTs.value = Date.now() // 分钟钟 60s 才走一格，回台先校正数据年龄
  if (market.value && ageMin.value != null && ageMin.value > thresholds.staleDotMin) {
    load({ silent: true, auto: true })
  }
}
onMounted(() => {
  prevTitle = document.title
  document.title = '三角洲行动 · 子弹行情'
  // 深链回填：/ammo?q=弹名（TTK 页「现价」入口跳转进来直接筛到该弹）。
  // 只在进入时消费一次，之后的搜索词变化属用户本地状态，不回写 URL
  const q = typeof route.query.q === 'string' ? route.query.q.trim().slice(0, 40) : ''
  if (q) state.q = q
  load()
  connectLive() // 本地 live 服务在跑时走 SSE（≤5s）；不在 / 不适用则轮询兜底
  schedulePoll()
  clockTimer = setInterval(() => { nowTs.value = Date.now() }, 60 * 1000)
  document.addEventListener('visibilitychange', onVisibility)
  window.addEventListener('resize', syncTblFade)
  window.addEventListener('keydown', onGlobalKeydown)
})
onUnmounted(() => {
  document.title = prevTitle
  clearTimeout(pollTimer)
  clearInterval(clockTimer)
  if (tipTimer) clearTimeout(tipTimer)
  if (notifyTipTimer) clearTimeout(notifyTipTimer)
  if (posDelTimer) clearTimeout(posDelTimer)
  if (ctlRO) ctlRO.disconnect()
  if (live) live.stop()
  document.removeEventListener('visibilitychange', onVisibility)
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
    <p v-if="notifyTip" class="notify-hint" role="status">{{ notifyTip }}</p>

    <!-- 数据过期提醒（moligod 30min / kkrb 6h，文案如实注明静态快照边界）。
         「刷新数据」按钮在全表控制条（首屏外），提示最刺眼时就地给出口 -->
    <p v-if="ageMin !== null && ageMin > thresholds.staleTipMin" class="state-tip stale-tip" role="status">
      {{ staleTipMsg }}
      <button class="retry" :disabled="refreshing" @click="load({ silent: true })">{{ refreshing ? '刷新中…' : '立即刷新' }}</button>
    </p>

    <!-- 加载 / 空态 -->
    <p v-if="loadState === 'loading'" class="state-tip">正在加载行情…</p>
    <div v-else-if="loadState === 'empty'" class="state-card">
      <p>还没有行情数据。</p>
      <p class="dim">行情快照正在准备中，稍后再来看看。</p>
    </div>
    <div v-else-if="loadState === 'error'" class="state-card">
      <p>行情加载失败：{{ loadError }}</p>
      <button class="retry" @click="load()">重试</button>
    </div>

    <template v-if="loadState === 'ready'">
      <!-- 行情脉搏：全市场信号分布一览 -->
      <section class="pulse reveal" aria-label="行情总览">
        <div class="stat">
          <span class="st-k"><i class="st-dot ok"></i>买入信号</span>
          <span class="st-v ok">{{ stats.BUY }}</span>
          <span class="st-s">贴近 7 天低位 · 税后利润达标</span>
        </div>
        <div class="stat">
          <span class="st-k"><i class="st-dot danger"></i>卖出信号</span>
          <span class="st-v danger">{{ stats.SELL }}</span>
          <span class="st-s">贴近 7 天高位 · 建议出货</span>
        </div>
        <div class="stat">
          <span class="st-k"><i class="st-dot info"></i>低位关注</span>
          <span class="st-v info">{{ stats.WATCH }}</span>
          <span class="st-s">处低位但利润未达线</span>
        </div>
        <div class="stat">
          <span class="st-k"><i class="st-dot mute"></i>覆盖弹种</span>
          <span class="st-v">{{ items.length }}</span>
          <span class="st-s">交易行全部子弹 · 7 天曲线</span>
        </div>
      </section>

      <!-- 我的囤货台账：纯本地 localStorage（不上传不同步），有持仓才显示。
           浮盈按「挂 P75 税后到手」口径；现价已达挂卖价的行高亮可出 -->
      <section v-if="positions.length" ref="posSecRef" class="block reveal pos-block" aria-label="我的囤货台账">
        <div class="block-h">
          <span class="bht">MY POSITIONS</span><span class="bhline"></span>
          <span class="bhc">{{ positions.length }} 条 · 本机记录{{ accountUser ? ' · 已随账号云同步' : '' }}</span>
        </div>
        <div class="pos-sum">
          <span class="ps-item">总投入 <b>{{ fmt(posTotals.invest) }}</b></span>
          <span class="ps-item">到价浮盈（挂 P75）<b :class="posTotals.gainNet >= 0 ? 'pos-pos' : 'pos-neg'">{{ fmtSigned(posTotals.gainNet) }}</b><template v-if="posTotals.pct != null">（{{ pct(posTotals.pct) }}）</template></span>
          <span class="ps-item">现价直出浮盈 <b :class="posTotals.gainNow >= 0 ? 'pos-pos' : 'pos-neg'">{{ fmtSigned(posTotals.gainNow) }}</b></span>
        </div>
        <ul class="pos-list">
          <li v-for="r in positionRows" :key="r.name" :class="{ hit: r.atTarget }">
            <span class="pos-name">
              <span class="a-icw" aria-hidden="true">
                <img
                  v-if="r.item?.pic" class="a-ic"
                  :src="picThumb(r.item.pic, 96)" alt=""
                  width="26" height="18" loading="lazy" decoding="async"
                  @error="hideImg"
                >
              </span>
              <span class="pos-title">{{ r.name }}</span>
              <span v-if="r.atTarget" class="pos-badge">已到挂卖价</span>
              <span v-else-if="!r.item" class="pos-badge gone">不在当前行情</span>
            </span>
            <label class="pos-field" :title="`数量（${r.qty} 发）`">
              <span class="pos-k">数量</span>
              <input class="pos-in" type="number" min="1" :value="r.qty" aria-label="数量" @change="setPosQty(r, $event)">
            </label>
            <label class="pos-field" :title="`成本 / 发（${fmt(r.cost)}）`">
              <span class="pos-k">成本/发</span>
              <input class="pos-in" type="number" min="1" step="any" :value="r.cost" aria-label="成本单价" @change="setPosCost(r, $event)">
            </label>
            <span class="pos-cell">
              <span class="pos-k">现价</span>
              <span class="mono pos-v">{{ r.item ? fmt(r.item.current) : '—' }}</span>
            </span>
            <span class="pos-cell">
              <span class="pos-k">到价浮盈</span>
              <span class="mono pos-v" :class="r.gainNet == null ? '' : r.gainNet >= 0 ? 'pos-pos' : 'pos-neg'">{{ r.gainNet == null ? '—' : fmtSigned(r.gainNet) }}</span>
            </span>
            <span class="pos-cell">
              <span class="pos-k">现价浮盈</span>
              <span class="mono pos-v" :class="r.gainNow == null ? '' : r.gainNow >= 0 ? 'pos-pos' : 'pos-neg'">{{ r.gainNow == null ? '—' : fmtSigned(r.gainNow) }}</span>
            </span>
            <button
              class="pos-del" :class="{ arm: posDelArm === r.name }"
              :aria-label="posDelArm === r.name ? `再点一次，确认删除 ${r.name} 的囤货记录` : `删除 ${r.name} 的囤货记录`"
              :title="posDelArm === r.name ? '再点一次确认删除（3 秒后自动取消）' : '删除这条囤货'"
              @click="onPosDel(r.name)"
            >{{ posDelArm === r.name ? '确认' : '✕' }}</button>
          </li>
        </ul>
        <form class="pos-add" @submit.prevent="addPosition">
          <input
            v-model.trim="posForm.name" class="pos-in pos-add-name" list="pos-name-list"
            type="text" placeholder="弹名（可联想，如 M855A1）" aria-label="弹名"
          >
          <datalist id="pos-name-list">
            <option v-for="i in items" :key="i.name" :value="i.name" />
          </datalist>
          <input v-model.number="posForm.qty" class="pos-in" type="number" min="1" placeholder="数量" aria-label="数量" required>
          <input v-model.number="posForm.cost" class="pos-in" type="number" min="1" step="any" placeholder="成本/发（空=现价）" aria-label="成本单价，留空按现价记入">
          <button class="pos-add-btn" type="submit">{{ positions.some((p) => p.name === posForm.name) ? '更新' : '记入囤货' }}</button>
          <p v-if="posFormErr" class="pos-err" role="alert">{{ posFormErr }}</p>
        </form>
      </section>

      <!-- 买入信号 -->
      <section v-if="buyList.length" class="block reveal">
        <div class="block-h">
          <span class="bht">BUY SIGNALS</span><span class="bhline"></span>
          <span class="bhc">{{ buyList.length }} 种 · 按预期收益率排序</span>
        </div>
        <div class="sig-grid">
          <SignalCard v-for="i in buyList.slice(0, 6)" :key="i.name" :item="i" />
        </div>
        <p v-if="buyList.length > 6" class="more-tip">其余 {{ buyList.length - 6 }} 种买入信号见下方全表（筛选「买入」）。</p>
      </section>
      <p v-else class="no-buy-tip">
        当前没有触发买入条件的弹种（7 天低位 + 税后利润 ≥ 8%）。低位「关注」中的弹种见全表。
      </p>

      <!-- 卖出信号（迷你卡，点击直达全表走势） -->
      <section v-if="sellList.length" class="block reveal">
        <div class="block-h">
          <span class="bht">SELL SIGNALS</span><span class="bhline"></span>
          <span class="bhc">{{ sellList.length }} 种贴近 7 天高位 · 点击查看走势</span>
        </div>
        <div class="sell-grid">
          <SellCard
            v-for="i in sellList.slice(0, 12)" :key="i.name"
            :item="i" @open="openFromSell(i)"
          />
          <button
            v-if="sellList.length > 12" class="sell-more"
            aria-label="筛选全部卖出信号" @click="showAllSell"
          >+{{ sellList.length - 12 }} 种</button>
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
                  <i v-if="s.dot" class="chip-dot" :style="{ background: s.dot }"></i><svg v-if="s.star" class="chip-star" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.6 9.59 6.02 14.28 6.16 10.57 9.03 11.88 13.54 8 10.9 4.12 13.54 5.43 9.03 1.72 6.16 6.41 6.02Z"/></svg>{{ s.label }}
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
                  <th class="c-pen">穿透</th>
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
                    class="row data-row" :class="{ open: expanded === i.name }"
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
                      ><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.6 9.59 6.02 14.28 6.16 10.57 9.03 11.88 13.54 8 10.9 4.12 13.54 5.43 9.03 1.72 6.16 6.41 6.02Z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/></svg></button>
                      <span class="a-icw" aria-hidden="true">
                        <img
                          v-if="i.pic" class="a-ic"
                          :src="picThumb(i.pic, 96)" alt=""
                          width="26" height="18" loading="lazy" decoding="async"
                          @error="hideImg"
                        >
                        <i class="a-gd" :style="{ background: gradeVar(i.grade) }" :title="`品级 ${i.grade}`"></i>
                      </span>
                      <span class="a-name">{{ i.name }}</span>
                      <i class="row-chev" aria-hidden="true"><svg viewBox="0 0 16 16"><path d="M4 6.2 8 10.2 12 6.2" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></i>
                    </td>
                    <!-- 穿透（TTK 联动）：无映射显「—」，等级语义与判定矩阵见 TTK 页 -->
                    <td class="c-pen">
                      <PenBadge v-if="penOf(i.name) != null" :p="penOf(i.name)" />
                      <template v-else>—</template>
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
                    <td><Sparkline :curve="i.curve" :width="130" :height="30" :end-color="SIG_COLOR[i.signal] || 'var(--faint)'" /></td>
                  </tr>
                  <tr v-if="expanded === i.name" class="expander">
                    <td colspan="8">
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
                      <PriceChart :curve="i.curve" :p25="i.p25" :p75="i.p75" :current="i.current" />
                      <p class="exp-note">
                        口径：买入参考 {{ fmt(i.p25) }}（P25）/ 目标挂卖 {{ fmt(i.targetSell) }}（P75，税后到手 {{ fmt(i.netSell) }}）/
                        税率 {{ (i.taxRate * 100).toFixed(0) }}%。价格回到 P75 即可挂卖；急用钱可按现价直接出。
                      </p>
                      <p v-if="etaLine(i)" class="exp-note eta-note">
                        <b>预计卖出</b>：{{ etaLine(i) }}（历史统计，不代表未来）。
                      </p>
                    </td>
                  </tr>
                </template>
                <tr v-if="!filtered.length">
                  <td colspan="8" class="empty-cell">
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
              <li><b>预计卖出</b>：统计近 7 天小时曲线——「从当前价位档涨到 P75 挂卖价」的完整上涨段给出中位/最快历时；同小时均价聚合给出日内高位时段。历史统计不代表未来。</li>
              <li><b>能赚多少</b>：每发利润 = 目标挂卖价 × (1−税率) − 当前买入价；税率按税后价实测反推（约 15%，逐弹计算）。</li>
              <li><b>穿透</b>：来自 TTK 弹药数据（穿透等级决定对各级护甲的伤害通过率，判定矩阵见 TTK 页）。「—」= 无穿透数据（弓弩用弹 / 国服与通用命名差异 / 一名多弹无法确定对应），宁缺勿错。</li>
              <li><b>数据</b>：{{ dataLine }}</li>
              <li><b>提醒</b>：交易行价格受版本、活动与大盘供需影响，历史分位不代表未来走势；利润测算未计挂单时间成本。</li>
            </ul>
          </section>
        </div>
      </section>

      <!-- 全市场日内节律（数据驱动的「现在几点该买该卖」，插在倒卖手册之上：
           静态 WINDOWS 给共识时段，这里给当前快照的实时水位判读，两者互补） -->
      <MarketClock :items="items" />

      <!-- 倒卖手册：社区攻略整理的实操动线（买/卖/版本窗口/卡邮件 + 风险红线）。
           放在 .tbl-zone 之外：不影响表容器 sticky 的包含块余量 -->
      <Playbook />
    </template>
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
.notify-hint { color: var(--faint); font-size: var(--fs-2xs); margin: 6px 0 0; }

.state-tip { color: var(--dim); font-size: var(--fs-md); padding: var(--sp-6) 0; }
.stale-tip { color: var(--warn); }
/* 过期提示内嵌的「立即刷新」：主按钮 .retry 的小一号内联变体 */
.stale-tip .retry { font-size: var(--fs-xs); padding: 3px 14px; margin-left: 10px; vertical-align: 1px; }
.state-card {
  background: var(--card); border: 1px dashed var(--line2); border-radius: var(--radius);
  padding: var(--sp-6); color: var(--tx); margin: var(--sp-4) 0;
}
.state-card .dim { color: var(--faint); font-size: var(--fs-sm); }
/* 主要按钮（重试/清筛选）：--accent-bg 底 + --accent-dim 边，hover 提底 --accent-soft，
   按下 scale(.98)，禁用降透明；键盘走全局 :focus-visible 外框 */
.retry,
.empty-clear,
.pos-add-btn {
  background: var(--accent-bg); color: var(--accent); border: 1px solid var(--accent-dim);
  border-radius: var(--radius); padding: 6px 18px; cursor: pointer; font-size: var(--fs-sm);
  transition: background-color var(--t-med) var(--ease), transform var(--t-fast) var(--ease);
}
.retry:hover,
.empty-clear:hover,
.pos-add-btn:hover { background: var(--accent-soft); }
.retry:active,
.empty-clear:active,
.pos-add-btn:active { transform: scale(.98); }
.retry:disabled,
.empty-clear:disabled,
.pos-add-btn:disabled { opacity: .45; cursor: default; }
.empty-cell { text-align: center; color: var(--dim); padding: var(--sp-6) 0; }

/* ---------- 行情脉搏总览条：单面板四格，hairline 分隔（移动端 2×2 换分隔轴向） ---------- */
.pulse {
  display: grid; grid-template-columns: repeat(4, 1fr);
  margin-top: var(--sp-6);
  background: linear-gradient(180deg, var(--card2) 0%, var(--card) 80%);
  border: 1px solid var(--line); border-radius: var(--radius-lg);
  box-shadow: var(--edge-light);
  overflow: hidden;
}
.stat { display: flex; flex-direction: column; gap: 2px; padding: var(--sp-4) var(--sp-5); min-width: 0; }
.stat + .stat { border-left: 1px solid var(--line2); }
.st-k {
  display: flex; align-items: center; gap: 7px;
  font-family: var(--mono); font-size: var(--fs-2xs);
  color: var(--dim); letter-spacing: .12em;
}
.st-dot { width: 6px; height: 6px; transform: rotate(45deg); flex: none; }
.st-dot.ok { background: var(--ok); }
.st-dot.danger { background: var(--danger); }
.st-dot.info { background: var(--info); }
.st-dot.mute { background: var(--faint); }
.st-v {
  font-family: var(--mono); font-size: var(--fs-display); font-weight: 700;
  line-height: 1.15; color: var(--tx-strong);
  font-variant-numeric: tabular-nums;
}
.st-v.ok { color: var(--ok); }
.st-v.danger { color: var(--danger); }
.st-v.info { color: var(--info); }
.st-s {
  font-size: var(--fs-2xs); color: var(--faint);
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
@media (max-width: 680px) {
  .pulse { grid-template-columns: repeat(2, 1fr); }
  .stat { padding: var(--sp-3) var(--sp-4); }
  .stat + .stat { border-left: 0; }
  .stat:nth-child(2n) { border-left: 1px solid var(--line2); }
  .stat:nth-child(n+3) { border-top: 1px solid var(--line2); }
  .st-s { white-space: normal; }
}

/* ---------- 我的囤货台账（纯本地记录）：汇总条 + 行内可编辑列表 + 录入表单 ---------- */
.pos-sum {
  display: flex; flex-wrap: wrap; gap: 6px 26px;
  padding: 10px 14px; margin-bottom: var(--sp-3);
  background: linear-gradient(90deg, rgba(45, 212, 191, .08), rgba(45, 212, 191, .01) 70%);
  background: linear-gradient(90deg, color-mix(in srgb, var(--accent) 8%, transparent), color-mix(in srgb, var(--accent) 1%, transparent) 70%);
  border-left: 2px solid var(--accent-dim); border-radius: var(--radius-sm);
  font-size: var(--fs-xs); color: var(--dim);
}
.pos-sum b {
  font-family: var(--mono); color: var(--tx-strong);
  font-variant-numeric: tabular-nums;
}
.pos-pos { color: var(--ok); }
.pos-neg { color: var(--danger); }

.pos-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.pos-list li {
  display: flex; align-items: center; flex-wrap: wrap; gap: 6px 16px;
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius);
  padding: 8px 12px;
}
/* 现价已达挂卖价（targetSell）：accent 边条 + 微底，提示可出 */
.pos-list li.hit {
  border-color: var(--accent-dim);
  background: var(--accent-bg);
  box-shadow: inset 2px 0 0 var(--accent);
}
.pos-name { display: inline-flex; align-items: center; gap: 8px; min-width: 0; flex: 1 1 150px; }
.pos-title { color: var(--tx-strong); font-size: var(--fs-sm); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.pos-badge {
  flex: none;
  font-family: var(--mono); font-size: var(--fs-2xs);
  color: var(--danger);
  border: 1px solid rgba(217, 106, 89, .4); background: rgba(217, 106, 89, .1);
  border-color: color-mix(in srgb, var(--danger) 40%, transparent);
  background: color-mix(in srgb, var(--danger) 10%, transparent);
  border-radius: var(--radius-pill); padding: 1px 8px;
}
.pos-badge.gone {
  color: var(--faint); border-color: var(--line2); background: none;
}
.pos-k {
  display: block;
  font-family: var(--mono); font-size: var(--fs-2xs); color: var(--faint); letter-spacing: .08em;
}
.pos-field { display: inline-flex; flex-direction: column; gap: 2px; }
.pos-in {
  width: 96px; background: var(--deep); border: 1px solid var(--line); border-radius: var(--radius);
  color: var(--tx); font-family: var(--mono); font-size: var(--fs-xs); padding: 3px 8px;
  transition: border-color var(--t-fast) var(--ease);
}
/* 键盘可达走全局 :focus-visible 外框；:focus 只做边框提亮 */
.pos-in:focus { border-color: var(--accent-dim); }
/* number 输入的步进箭头占宽且挤不进窄列：隐藏（键盘直输 / 滚轮仍可调） */
.pos-in::-webkit-outer-spin-button, .pos-in::-webkit-inner-spin-button { -webkit-appearance: none; margin: 0; }
.pos-in[type="number"] { -moz-appearance: textfield; appearance: textfield; }
.pos-cell { display: inline-flex; flex-direction: column; gap: 2px; }
.pos-v { font-size: var(--fs-xs); color: var(--tx); font-variant-numeric: tabular-nums; }
.pos-del {
  flex: none; margin-left: auto;
  background: none; border: 1px solid transparent; border-radius: var(--radius-sm);
  color: var(--faint); font-size: var(--fs-2xs); padding: 3px 8px; cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
}
.pos-del:hover, .pos-del:active { color: var(--danger); border-color: var(--line-hover); }
/* 二次确认待定态：danger 实感（真值 rgba 兜底，写法同 pos-badge） */
.pos-del.arm {
  color: var(--danger);
  border-color: rgba(217, 106, 89, .55);
  background: rgba(217, 106, 89, .14);
  border-color: color-mix(in srgb, var(--danger) 55%, transparent);
  background: color-mix(in srgb, var(--danger) 14%, transparent);
}
/* iOS Safari 聚焦字号 <16px 的输入会整页自动放大（viewport 未锁 maximum-scale，
   锁了伤无障碍）：移动端把本页输入临时升到 16px，桌面视觉不变 */
@media (max-width: 680px) {
  .search, .pos-in { font-size: var(--fs-lg); }
}

.pos-add { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin-top: var(--sp-3); }
.pos-add .pos-in { background: var(--card); }
.pos-add-name { flex: 1 1 170px; width: auto; }
.pos-err { width: 100%; margin: 0; color: var(--warn); font-size: var(--fs-xs); }

.sig-grid {
  display: grid; grid-template-columns: repeat(auto-fill, minmax(330px, 1fr)); gap: var(--sp-4);
}
.more-tip { color: var(--faint); font-size: var(--fs-xs); margin-top: var(--sp-3); }
.no-buy-tip {
  margin-top: var(--sp-6);
  border: 1px dashed var(--line2); border-radius: var(--radius);
  padding: var(--sp-4) var(--sp-5);
  color: var(--dim); font-size: var(--fs-md);
}

/* ---------- 卖出迷你卡网格（卡片本体样式在 SellCard.vue；此处只管排布） ---------- */
.sell-grid {
  display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: var(--sp-2) var(--sp-3);
}
.sell-more {
  display: flex; align-items: center; justify-content: center;
  min-height: 54px;
  border: 1px dashed var(--line2); border-radius: var(--radius);
  background: none; color: var(--dim);
  font-family: var(--mono); font-size: var(--fs-xs);
  cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
}
.sell-more:hover,
.sell-more:active { color: var(--tx); border-color: var(--line-hover); }

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
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease), background-color var(--t-fast) var(--ease);
}
/* 按下同 hover（chip/次要按钮规格，与 radar 页对齐）；置于 .on 之前——选中项按下保持选中观感 */
.chip:hover,
.chip:active { color: var(--tx); border-color: var(--line-hover); }
.chip.on { color: var(--accent); border-color: var(--accent-dim); background: var(--accent-bg); }
.chip-dot { width: 6px; height: 6px; border-radius: 50%; }
.chip-star { width: 12px; height: 12px; fill: currentColor; flex: none; }
.chip.refresh { margin-left: auto; }
.chip.refresh:disabled { opacity: .6; cursor: default; }
/* 方向标记（inline SVG）：继承 chip 的 --accent 文字色 */
.dir { width: 10px; height: 10px; margin-left: 2px; color: var(--accent); flex: none; }
.refresh-tip { font-family: var(--mono); font-size: var(--fs-xs); margin-top: 6px; }
.refresh-tip.ok { color: var(--dim); }
.refresh-tip.warn { color: var(--warn); }
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
/* 右缘渐隐：仅容器真溢出且未滑到底时出现（桌面无溢出永不显示）。
   mask 直接挂在滚动容器上（相对视口右缘、不随内容横滑）——绝对定位的
   ::after 属于滚动内容，横滑 300px 后会漂进表格中部，形同渲染 bug */
.tbl-scroll.can-scroll:not(.at-end) {
  -webkit-mask-image: linear-gradient(to right, #000 calc(100% - 36px), transparent);
  mask-image: linear-gradient(to right, #000 calc(100% - 36px), transparent);
}

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
/* 行内弹药图标：官方 pic 缩略 + 品级菱形角标压角（替代旧 g-dot，身份与品级合一） */
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
.a-name { color: var(--tx-strong); }
.row-chev {
  display: inline-flex; align-items: center; vertical-align: middle;
  color: var(--faint); margin-left: 6px;
  transition: transform var(--t-fast) var(--ease), color var(--t-fast) var(--ease);
}
.row-chev svg { width: 12px; height: 12px; display: block; }
.row.open .row-chev { transform: rotate(180deg); color: var(--accent); }

.rank-cell { display: flex; align-items: center; justify-content: flex-end; gap: 8px; }
.rb-num { font-family: var(--mono); font-size: var(--fs-xs); color: var(--dim); }
.rb-num.low { color: var(--ok); }
.rb-num.high { color: var(--danger); }
/* 分位条：两端阈值刻度（25% 买入线 / 80% 卖出线，与 METHOD 口径一致），
   填充按所在区间染渐变绿/红，中性段用暗灰 */
.rank-bar { position: relative; width: 110px; height: 7px; background: var(--line2); border-radius: 4px; }
.rb-tick {
  position: absolute; top: -2px; bottom: -2px; width: 1px;
  background: var(--line-hover);
}
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
  /* 穿透列与 7 天区间列同法降级：移动端窄屏隐藏（穿透徽标仍可见于 TTK 页与详情） */
  .c-pen { display: none; }
}

/* 信号徽章：彩色文字 + 同色系淡底（color-mix 派生，rgba 真值兜底，写法同 ttk PenMatrix），
   扫读时按颜色块成组 */
.sig {
  display: inline-block; font-family: var(--mono); font-size: var(--fs-2xs);
  letter-spacing: .1em; padding: 2px 10px; border-radius: var(--radius-pill);
  border: 1px solid var(--line2); color: var(--dim); background: var(--card);
}
.sig.buy {
  color: var(--ok);
  border-color: rgba(133, 181, 120, .4); background: rgba(133, 181, 120, .1);
  border-color: color-mix(in srgb, var(--ok) 40%, transparent);
  background: color-mix(in srgb, var(--ok) 10%, transparent);
}
.sig.sell {
  color: var(--danger);
  border-color: rgba(217, 106, 89, .4); background: rgba(217, 106, 89, .1);
  border-color: color-mix(in srgb, var(--danger) 40%, transparent);
  background: color-mix(in srgb, var(--danger) 10%, transparent);
}
.sig.watch {
  color: var(--info);
  border-color: rgba(97, 159, 206, .4); background: rgba(97, 159, 206, .1);
  border-color: color-mix(in srgb, var(--info) 40%, transparent);
  background: color-mix(in srgb, var(--info) 10%, transparent);
}
td.profit { color: var(--ok); font-weight: 600; }
/* 当前价是表格主列：字号升一档并加粗（压过 .mono 的 fs-xs） */
.tbl td.price-cell { font-size: var(--fs-md); color: var(--tx-strong); font-weight: 700; }

/* 顶部预留动作条带（按钮带约占 td 顶 10~37px）：图表「现在」标注挂在曲线右端，
   现价贴近 7 天高点时会落到同一右上角，不预留就被不透明按钮盖住 */
.expander td {
  position: relative; background: var(--card2); border-top: 1px solid var(--accent-dim);
  padding-top: 44px;
}
/* 右上动作组（收起 / 记入囤货）：定位由容器承担，按钮本体静态排列 */
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
.exp-note { color: var(--faint); font-size: var(--fs-xs); margin: 10px 2px 2px; line-height: 1.8; }
.exp-note b { color: var(--dim); }
/* 预计卖出脚注：--accent 预测语义左边条（真值 rgba 兜底，accent = rgb(45,212,191)） */
.eta-note {
  border-left: 2px solid var(--accent-dim);
  padding-left: 10px;
  color: var(--dim);
}
.eta-note b { color: var(--accent); }

.method {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-lg);
  padding: var(--sp-4) var(--sp-5);
  list-style: none; color: var(--dim); font-size: var(--fs-sm); line-height: 1.9;
}
.method li { padding-left: 16px; position: relative; }
.method li::before { content: "◆"; position: absolute; left: 0; color: var(--accent-dim); font-size: 8px; top: 7px; }
.method b { color: var(--tx); }

/* 本页全部微交互过渡的 reduced-motion 关闭（live-dot 脉冲另有独立规则） */
@media (prefers-reduced-motion: reduce) {
  .chip, .search, .search-clear, .sell-more, .exp-close, .star, .row-chev,
  .retry, .empty-clear, .pos-add-btn, .pos-in, .pos-del { transition: none; }
  .retry:active, .empty-clear:active, .pos-add-btn:active { transform: none; }
}
</style>
