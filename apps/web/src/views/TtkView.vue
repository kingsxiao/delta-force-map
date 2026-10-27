<script setup>
/* ============================================================
   TtkView — TTK 排行 · 全枪械（/ttk）
   自 legacy/ttk.html 迁移：数据/模型在 src/data/ttk/*（68 枪全组合对拍 7791 例逐值一致），
   交互口径：部位（胸/腹/头）多选、目标护甲 0-6 多选、类别（7 类武器）多选、
   弹药模式（每枪最佳/全部组合）单选 + 穿透等级多选、排序（TTK/发数）单选；
   多选即叠加场景：列表按「枪 × 弹 × 部位 × 护甲」展开，
   「每枪最佳弹药」模式每枪每场景取最快一发行。
   排行行点开懒加载逐发模拟、弹药库全表（默认收起）、穿透×护甲判定矩阵。
   枪名搜索（zh/en 不区分大小写子串）只保留命中枪的行；六组筛选 + 搜索词序列化进
   hash query（?p&a&cls&pen&mode&sort&q，可分享链接），进入时还原（query 属路由状态，
   不属被禁的裸锚点 hash）。
   入场统一走 useReveal；champs 容器挂 reveal-group 行级级联（§7.3，≤4 卡，
   类别筛选改卡组构成时重进级联＝状态反馈）；rank-list 的级联只播一次——
   容器 .in 后新插入子项会自动播放，首次筛选重建即撤下 reveal-group，
   此后大表重建瞬时（红线：入场动画不得在每次筛选时整列重播，见 watch(state)）。
   ============================================================ */
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useReveal } from '../composables/useReveal'
import ControlSeg from './ttk/ControlSeg.vue'
import ChampCards from './ttk/ChampCards.vue'
import RankRow from './ttk/RankRow.vue'
import AmmoTable from './ttk/AmmoTable.vue'
import PenMatrix from './ttk/PenMatrix.vue'
import PenBadge from './ttk/PenBadge.vue'
import CollapseCol from '../components/CollapseCol.vue'
import TierBoard from './ttk/TierBoard.vue'
import BalanceLog from './ttk/BalanceLog.vue'
import { CAL } from '../data/ttk/calibers.js'
import { GUNS } from '../data/ttk/guns.js'
import { DUR, HEAD_DUR, PARTS } from '../data/ttk/armor.js'
import { combo } from '../data/ttk/model.js'
import { fmtAge } from '@shared/js/marketMeta.js'
import { PART_CHAR, scenLabel, fmtMs } from './ttk/format.js'

/* ---------- 分段控件条目（legacy segDefs L714-742 原样，共六组实例） ---------- */
const PART_SEGS = [
  { v: 'chest', label: '胸部' },
  { v: 'belly', label: '腹部' },
  { v: 'head', label: '头部' },
]
/* 等级点色走 base.css --lv* 语义变量（内联 style 支持 var()） */
const ARMOR_SEGS = [
  { v: 0, label: '无甲', dot: 'transparent', cls: 'none' },
  { v: 1, label: '1', dot: 'var(--lv1)' },
  { v: 2, label: '2', dot: 'var(--lv2)' },
  { v: 3, label: '3', dot: 'var(--lv3)' },
  { v: 4, label: '4', dot: 'var(--lv4)' },
  { v: 5, label: '5', dot: 'var(--lv5)' },
  { v: 6, label: '6', dot: 'var(--lv6)' },
]
/* 类别元信息（7 类武器，legacy CLS_META L704-712 原样）：类别段与场景最快卡共用 */
const CLS_META = [
  { k: 'ar', zh: '步枪', en: 'AR' },
  { k: 'smg', zh: '冲锋枪', en: 'SMG' },
  { k: 'dmr', zh: '射手步枪', en: 'DMR' },
  { k: 'snp', zh: '狙击枪', en: 'SNIPER' },
  { k: 'lmg', zh: '轻机枪', en: 'LMG' },
  { k: 'sg', zh: '霰弹枪', en: 'SG' },
  { k: 'pst', zh: '手枪', en: 'PISTOL' },
]
const CLASS_SEGS = [{ v: 'all', label: '全部' }].concat(CLS_META.map((m) => ({ v: m.k, label: m.zh })))
const AMMO_MODE_SEGS = [
  { v: 'best', label: '每枪最佳弹药', title: '每枪取当前筛选下最快的一种弹药' },
  { v: 'full', label: '全部枪弹组合', title: '每把枪的每种可用弹药各占一行' },
]
const PEN_SEGS = [
  { v: 'all', label: '全部', title: '不限穿透等级' },
  { v: 0, label: '0', dot: 'var(--lv0)', title: '0 级穿透弹' },
  { v: 1, label: '1', dot: 'var(--lv1)', title: '1 级穿透弹' },
  { v: 2, label: '2', dot: 'var(--lv2)', title: '2 级穿透弹' },
  { v: 3, label: '3', dot: 'var(--lv3)', title: '3 级穿透弹' },
  { v: 4, label: '4', dot: 'var(--lv4)', title: '4 级穿透弹' },
  { v: 5, label: '5', dot: 'var(--lv5)', title: '5 级穿透弹（金弹）' },
  { v: 6, label: '6', dot: 'var(--lv6)', title: '6 级穿透弹' },
  { v: 7, label: '7', dot: 'var(--lv6)', title: '7 级穿透弹（全游戏仅 AWM / M82 可用）' },
]
const SORT_SEGS = [
  { v: 'ttk', label: 'TTK' },
  { v: 'btk', label: '发数' },
]
/* 展示层「实战修正」（借鉴 DFTTK 扳机延迟口径）：等量叠加不改名次/模型，
   只让展示 TTK 更贴近实战节奏；展开详情仍为纯理论值 */
const DELAY_SEGS = [
  { v: 0, label: '理论', title: '纯射击时间' },
  { v: 80, label: '+80ms', title: '叠加 80ms 扳机延迟（快手连点）' },
  { v: 150, label: '+150ms', title: '叠加 150ms 扳机延迟（普通反应）' },
]

/* ---------- 状态：部位/护甲/类别/穿透等级均为多选（数组），弹药模式/排序单选，q 枪名搜索词 ---------- */
const state = reactive({ parts: ['chest'], armors: [5], cls: [], ammoMode: 'best', pens: [], sort: 'ttk', delay: 0, q: '' })

/* 多选更新回调：部位/护甲至少保留一项；
   类别/穿透等级用"全部"芯片（空数组 = 全部）：新增具体项则保留，新增的是"全部"则清空。
   注意 modelValue 里合成的 'all' 与用户新点的项无法靠数组形状区分，必须比对新增方向 */
function pickWithAll(prev, v) {
  const added = v.find((x) => x !== 'all' && !prev.includes(x))
  if (added !== undefined) return v.filter((x) => x !== 'all')
  if (v.includes('all')) return []
  return v
}
function setParts(v) { if (v.length) state.parts = v }
function setArmors(v) { if (v.length) state.armors = v }
function setCls(v) { state.cls = pickWithAll(state.cls, v) }
function setPens(v) { state.pens = pickWithAll(state.pens, v) }

/* ---------- hash query 序列化：六组筛选 + 搜索词 → ?p&a&cls&pen&mode&sort&q（可分享链接） ----------
   与默认值相同的组不写入（默认视图保持干净的 /#/ttk，分享链接只带差异项）；
   codec 为纯函数（buildQuery/applyQuery 不碰 Vue，便于对拍）；非法值一律丢弃回默认，
   parts/armors 至少保留一项（与 setParts/setArmors 守卫同口径） */
const Q_DEFAULTS = { p: 'chest', a: '5', cls: '', pen: '', mode: 'best', sort: 'ttk', d: '0', q: '' }
function buildQuery(s) {
  const vals = {
    p: s.parts.join(','),
    a: s.armors.join(','),
    cls: s.cls.join(','),
    pen: s.pens.join(','),
    mode: s.ammoMode,
    sort: s.sort,
    d: String(s.delay),
    q: s.q.trim(),
  }
  const out = {}
  for (const k of Object.keys(vals)) if (vals[k] !== Q_DEFAULTS[k]) out[k] = vals[k]
  return out
}
/* query 取串防御：缺参 / 空串 / 数组形态（同名参数重复）一律视为未提供——
   直接 String().split(',') 会得到 ['']，对数字参数 .map(Number) 恰好变成合法的 0 */
const qList = (v) => (typeof v === 'string' && v ? v.split(',') : [])
function applyQuery(s, query) {
  const parts = qList(query.p).filter((x) => PART_SEGS.some((sg) => sg.v === x))
  if (parts.length) s.parts = parts
  const armors = qList(query.a).map(Number).filter((x) => ARMOR_SEGS.some((sg) => sg.v === x))
  if (armors.length) s.armors = armors
  s.cls = qList(query.cls).filter((x) => CLS_META.some((m) => m.k === x))
  s.pens = qList(query.pen).map(Number).filter((x) => Number.isInteger(x) && x >= 0 && x <= 7)
  if (query.mode === 'best' || query.mode === 'full') s.ammoMode = query.mode
  if (query.sort === 'ttk' || query.sort === 'btk') s.sort = query.sort
  const dv = Number(query.d)
  if (query.d !== undefined && DELAY_SEGS.some((sg) => sg.v === dv)) s.delay = dv
  if (typeof query.q === 'string' && query.q.trim()) s.q = query.q.trim().slice(0, 40)
}

/* 进入时按当前 query 还原一次（setup 阶段、watch 注册之前，不触发同步） */
const route = useRoute()
const router = useRouter()
applyQuery(state, route.query)

/* 渲染上限（perf）：「全部枪弹组合」× 全部位 × 全护甲最坏 7791 行一次性 v-for 重建，移动端必卡；
   首批 RANK_PAGE 行，其余靠「显示更多」分批递增 */
const RANK_PAGE = 200
const rankLimit = ref(RANK_PAGE)

/* 任意筛选/排序变化即重建列表：展开行全部收起（legacy renderAll 重建 DOM 的同口径行为），
   渲染上限一并重置——切筛选/排序后从首批行重新看起；query 随状态回写
   （router.replace 不留历史栈，打字/切筛选不产生可回退记录） */
const openKeys = reactive(new Set())
/* rank-list 级联只播一次：.reveal-group.in 会对重建插入的子项自动重播入场级联
   （useReveal §7.3 机制），而搜索每键入一字、筛选每切一组都会重建整批排行行——
   200 行整列重播即红线「入场动画不得在每次筛选时整列重播」。首次筛选重建时
   撤下容器的 reveal-group：初始滚入级联保留，此后大表重建瞬时（原则 3） */
const rankEl = ref(null)
let rankCascadeUsed = false
watch(state, () => {
  openKeys.clear()
  rankLimit.value = RANK_PAGE
  if (!rankCascadeUsed && rankEl.value) {
    rankCascadeUsed = true
    rankEl.value.classList.remove('reveal-group')
  }
  router.replace({ path: route.path, query: buildQuery(state) })
})

/* ---------- 计算：多选场景笛卡尔展开（枪 × 弹 × 部位 × 护甲） ---------- */
/* 枪名匹配：zh / en 不区分大小写子串（如「腾龙」「m4」「m7」，命中只保留对应枪的行） */
function gunMatch(g, qRaw) {
  if (!qRaw) return true
  const q = qRaw.toLowerCase()
  return g.zh.toLowerCase().includes(q) || g.en.toLowerCase().includes(q)
}
const filteredGuns = computed(() => {
  const q = state.q.trim()
  return GUNS.filter((g) => (!state.cls.length || state.cls.includes(g.cls)) && gunMatch(g, q))
})

const allCombos = computed(() => {
  const out = []
  for (const g of filteredGuns.value) {
    for (const am of CAL[g.cal].ammo) {
      if (state.pens.length && !state.pens.includes(am.pen)) continue
      for (const p of state.parts) {
        for (const al of state.armors) {
          const r = combo(g, am, al, PARTS[p])
          out.push({ ...r, part: p, armor: al })
        }
      }
    }
  }
  return out
})

/* 多场景时行内标注归属场景（部位 × 护甲任一维多选即开启） */
const multiScen = computed(() => state.parts.length * state.armors.length > 1)

/* 排行：'best' 模式每枪每场景取最快一发行；'full' 模式全部组合各占一行。
   同键排序；并列时保留先出现者（口径组序）——与 legacy 严格小于口径一致 */
const rankRows = computed(() => {
  const combos = allCombos.value
  let rows
  if (state.ammoMode === 'best') {
    const byKey = {}
    for (const c of combos) {
      const k = c.gun.en + '|' + c.part + '|' + c.armor
      if (!byKey[k] || c.ttk < byKey[k].ttk) byKey[k] = c
    }
    rows = Object.keys(byKey).map((k) => byKey[k])
  } else {
    rows = combos.slice() // 不改动 allCombos 缓存顺序
  }
  rows.sort((a, b) => {
    if (state.sort === 'btk') return a.btk - b.btk || a.ttk - b.ttk || b.gun.dmg - a.gun.dmg
    return a.ttk - b.ttk || a.btk - b.btk || b.gun.dmg - a.gun.dmg
  })
  return rows
})

/* 条宽基准取全表最小「正」TTK，而非首行：头部×无甲 btk=1 → ttk=0，首行取 0 会触发
   RankRow 满条守卫（全列表 100% 满条）；切「发数」排序后首行也未必最快、基准错位。
   全表无正 TTK（如仅剩 ttk=0 的组合）退 1，0 值行仍由 RankRow 守卫画满 */
const bestTtk = computed(() => {
  let m = 0
  for (const r of rankRows.value) if (r.ttk > 0 && (!m || r.ttk < m)) m = r.ttk
  return m || 1
})

/* ---------- T0-T3 强度分档带（借鉴 DFTTK 首页分档总览；固定基准：5 级甲 · 胸部 · 每枪最佳弹） ----------
   分档只随枪械面板变化（不随筛选联动），作稳定「强度标签」：排行行内徽标 + 顶部速览带。
   切点：前 8% T0 / 至 25% T1 / 至 60% T2 / 其余 T3（68 枪约 5 / 12 / 24 / 27 把）。 */
const TIER_DEFS = [
  { t: 'T0', label: '顶级', cut: 0.08, color: 'var(--lv5)' },
  { t: 'T1', label: '强势', cut: 0.25, color: 'var(--accent)' },
  { t: 'T2', label: '主流', cut: 0.60, color: 'var(--lv3)' },
  /* T3 文字色用 --dim 不用 --lv0：--lv0(#79828b) 在卡片底 --card(#171d24) 上 4.35:1 < AA 4.5，
     .tb-t（16px/700）不到 18.66px 大字豁免线；--dim 全场景 ≥6.1:1。--lv0 语义留给护甲等级 0 不动 */
  { t: 'T3', label: '入门', cut: 1, color: 'var(--dim)' },
]
const tierBase = computed(() => {
  const rows = []
  for (const g of GUNS) {
    let best = null
    for (const am of CAL[g.cal].ammo) {
      const r = combo(g, am, 5, PARTS.chest)
      if (!best || r.ttk < best.ttk) best = r
    }
    if (best) rows.push({ gun: g, ttk: best.ttk })
  }
  rows.sort((a, b) => a.ttk - b.ttk)
  return rows
})
function tierDefOf(i, n) {
  const r = (i + 1) / n
  for (const d of TIER_DEFS) if (r <= d.cut) return d
  return TIER_DEFS[TIER_DEFS.length - 1]
}
const tierGun = computed(() => {
  const m = {}
  const rows = tierBase.value
  rows.forEach((row, i) => { m[row.gun.en] = tierDefOf(i, rows.length).t })
  return m
})
const tiers = computed(() => {
  const rows = tierBase.value
  const groups = TIER_DEFS.map((d) => ({ ...d, guns: [] }))
  rows.forEach((row, i) => groups[TIER_DEFS.indexOf(tierDefOf(i, rows.length))].guns.push(row))
  return groups.map((g) => ({
    t: g.t,
    label: g.label,
    color: g.color,
    count: g.guns.length,
    from: g.guns.length ? fmtMs(g.guns[0].ttk) : '—',
    to: g.guns.length ? fmtMs(g.guns[g.guns.length - 1].ttk) : '—',
    names: g.guns.map((x) => x.gun.zh),
  }))
})
function pickGun(name) {
  state.q = name
  requestAnimationFrame(() => {
    const el = document.getElementById('rank')
    if (!el) return
    // RM 让位：scrollIntoView 显式传 smooth 会越过 CSS scroll-behavior 的 RM 兜底
    // （base.css reduce 下 scroll-behavior:auto 只约束未指定 behavior 的调用）
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    el.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth', block: 'start' })
  })
}

const rowKey = (c) => c.gun.en + '|' + c.am.n + '|' + c.part + '|' + c.armor

/* 实际渲染的行 = 排行前 rankLimit 行（截断只裁尾、不改序，:rank 从 1 连续编号不受影响） */
const shownRows = computed(() => rankRows.value.slice(0, rankLimit.value))
const toggleRow = (c) => {
  const k = rowKey(c)
  if (openKeys.has(k)) openKeys.delete(k)
  else openKeys.add(k)
}

const rankCountText = computed(() => {
  const bits = [rankRows.value.length + ' 行']
  if (state.pens.length)
    bits.push('弹药：仅 ' + [...state.pens].sort((a, b) => a - b).join('/') + ' 级穿透弹')
  if (state.q.trim()) bits.push('搜索：' + state.q.trim())
  const ps = state.parts
  const as = [...state.armors].sort((a, b) => a - b)
  const pTxt = ps.length === 3 ? '全部位' : ps.map((p) => PART_CHAR[p]).join('+')
  const aTxt = as.length === 7 ? '0-6 级' : as.join(' / ') + ' 级'
  let tgt
  if (ps.length === 1 && as.length === 1) {
    tgt = as[0] > 0
      ? (ps[0] === 'head'
          ? as[0] + ' 级头（满耐久 ' + HEAD_DUR[as[0]] + '）'
          : as[0] + ' 级甲（满耐久 ' + DUR[as[0]] + '）')
      : '无甲'
  } else {
    tgt = as.length === 7 ? aTxt + ' · ' + pTxt : aTxt + ' ' + pTxt
  }
  bits.push('目标：' + tgt)
  if (ps.length === 1)
    bits.push('命中：' + PARTS[ps[0]].label + '（×' + (ps[0] === 'head' ? '1.9' : ps[0] === 'belly' ? '0.9' : '1.0') + '）')
  return bits.join(' · ')
})

/* 场景最快卡（§6.3：收敛为 ALL + ≤3 张，一行 4 卡）：有类别筛选取所选类别前 3，
   无类别筛选固定 步枪 / 冲锋枪 / 狙击枪 三张 */
const champPicks = computed(() => {
  const combos = allCombos.value
  if (!combos.length) return []
  const best = (list) => list.reduce((m, c) => (c.ttk < m.ttk ? c : m), list[0])
  const picks = [{ label: '场景最快 · ALL', c: best(combos), top: true }]
  const ks = state.cls.length
    ? CLS_META.filter((m) => state.cls.includes(m.k)).slice(0, 3).map((m) => m.k)
    : ['ar', 'smg', 'snp']
  for (const k of ks) {
    const m = CLS_META.find((x) => x.k === k)
    const list = combos.filter((c) => c.gun.cls === k)
    if (list.length) picks.push({ label: m.zh + '最快 · ' + m.en, c: best(list) })
  }
  for (const p of picks) p.scen = scenLabel(p.c)
  return picks
})

/* 控制面板提示 */
const hintText = computed(() => {
  const bits = []
  if (state.parts.length === 1 && PARTS[state.parts[0]].hint) bits.push(PARTS[state.parts[0]].hint)
  if (state.armors.includes(6)) {
    if (state.parts.includes('head'))
      bits.push('6 级头只有 6 级弹可对穿（同级 50%）；5 级金弹打红盔已是低一级，需先击碎头盔 60 点耐久。')
    else if (state.parts.length === 1)
      bits.push('6 级甲只有 6 级弹可对穿（同级 50%）；5 级弹打红甲已是低一级，需先击碎护甲 150 点耐久。')
  }
  if (state.pens.length) {
    bits.push(
      '已限定 ' + [...state.pens].sort((a, b) => a - b).join('/') + ' 级穿透弹：' +
      (state.ammoMode === 'best' ? '每枪取所选等级中最快的一发弹，展开行可对比该枪的全部入选弹药。' : '每行一条枪弹组合。'))
    const miss = filteredGuns.value
      .filter((g) => !CAL[g.cal].ammo.some((am) => state.pens.includes(am.pen)))
      .map((g) => g.zh)
    if (miss.length) {
      const show = miss.slice(0, 8).join('、') + (miss.length > 8 ? ' 等 ' + miss.length + ' 把' : '')
      bits.push('以下 ' + miss.length + ' 把枪没有所选等级的弹药，未进入排行：' + show + '。')
    }
  }
  if (state.delay > 0)
    bits.push('已叠加 ' + state.delay + 'ms 扳机延迟（展示口径）：等量平移不改变名次，展开详情仍为纯理论值。')
  if (state.parts.length === 1 && state.parts[0] === 'chest' && state.armors.length === 1 && state.armors[0] > 0)
    bits.push('护甲满耐久按 ' + DUR[state.armors[0]] + ' 计；残甲目标更快倒地。')
  return bits.join(' ')
})

/* ---------- 弹药库（装配一次、展开态不随筛选重置；默认全收起，§6.3） ---------- */
const ammoKeys = Object.keys(CAL)
const ammoTotal = ammoKeys.reduce((s, k) => s + CAL[k].ammo.length, 0)
const ammoCountText = ammoKeys.length + ' 种口径 · ' + ammoTotal + ' 种弹药'
const ammoOpen = reactive(Object.fromEntries(ammoKeys.map((k) => [k, false])))
const ammoAllOpen = computed(() => ammoKeys.every((k) => ammoOpen[k]))
function toggleAllAmmo() {
  const next = !ammoAllOpen.value
  for (const k of ammoKeys) ammoOpen[k] = next
}

/* ---------- 行情联动（本页唯一的网络请求，一次性拉取同源 /ammo/market.json） ----------
   现价是增量信息不是本页地基：加载失败 / 快照缺失时现价列一律显「—」，
   伤害与 TTK 数据不受任何影响。同源相对路径两种部署形态（npm run serve
   静态托管 / 纯静态托管）均可达；纯静态部署下快照可能很旧——按快照
   fetchedAt 标注数据龄，不裸显无时间锚的旧价误导买卖决策。 */
const market = ref(null) // market.json 快照（null = 未加载完 / 失败）
const marketFailed = ref(false)
const priceByName = computed(() => {
  const m = {}
  for (const i of market.value?.items || []) m[i.name] = i
  return m
})
/* 传给 AmmoTable / RankRow 的窄接口：名字 → 行情条目（弹名对齐见 ammo-market-alias.js） */
const prices = computed(() => ({ byName: priceByName.value, ok: !!market.value }))
const marketAgeText = computed(() => {
  if (marketFailed.value) return '行情不可用'
  if (!market.value) return '行情加载中'
  const t = Date.parse(market.value.fetchedAt)
  return Number.isFinite(t) ? '行情 ' + fmtAge((Date.now() - t) / 60000) + '前' : '行情快照'
})

/* ---------- 静态折叠块开关（legacy 初始态：矩阵/护甲表/方法开，头盔/来源收） ---------- */
const matrixOpen = ref(true)
const armorTblOpen = ref(true)
const helmetOpen = ref(false)
const methodOpen = ref(true)
const sourceOpen = ref(false)

/* ---------- 入场（§6.4：三页统一走 useReveal）与页标题 ---------- */
const rootEl = ref(null)
const PAGE_TITLE = '三角洲行动 · TTK 排行（全枪械）'
const { observeRoot } = useReveal()
let prevTitle = ''

onMounted(() => {
  prevTitle = document.title
  document.title = PAGE_TITLE
  observeRoot(rootEl.value)
  // 行情快照一次性拉取（失败静默兜底：现价列全显「—」，marketAgeText 报「行情不可用」）
  fetch(`${import.meta.env.BASE_URL}ammo/market.json`)
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
    .then((j) => {
      if (j && Array.isArray(j.items)) market.value = j
      else throw new Error('数据格式异常')
    })
    .catch(() => { marketFailed.value = true })
})

onBeforeUnmount(() => {
  document.title = prevTitle
})
</script>

<template>
  <div ref="rootEl" class="ttk-page">
    <!-- 页头（紧凑单行，走 base.css .compact-head）：返回链接已删（全局顶栏常驻）；
         口径细节见文末「计算口径」一节 -->
    <div class="wrap compact-head">
      <h1>TTK 排行 · 全枪械</h1>
      <p class="meta">全枪械 × 全弹药 × 部位与护甲逐发模拟 · 多选筛选即时重算 · 数值以游戏内当前面板为准</p>
    </div>

    <div id="top" class="wrap">
      <section aria-label="TTK 排行">
        <!-- 控制面板：六组筛选收敛为三行（视觉验收：原六行占满 900px 首屏、排行表不可见；
             两项的「排序」单独成行右侧留白大）：行1 部位+护甲 · 行2 类别+穿透 · 行3 弹药+排序+枪械搜索。
             弹药与穿透仍不同行（§6.3 两组同款控件并排分不清）；排序并入弹药行——同为两项单选、成对易读；
             枪械搜索并入行 3（同属收窄结果集的单值操作，规格同 AmmoMarket / MarketRadar 的 .search） -->
        <div class="ctrl reveal">
          <div class="ctrl-rows">
            <div class="ctrl-row">
              <div class="ctrl-cell">
                <span class="ctrl-label">部位</span>
                <ControlSeg multiple name="部位" :model-value="state.parts" :items="PART_SEGS" @update:model-value="setParts" />
              </div>
              <div class="ctrl-cell">
                <span class="ctrl-label">目标护甲</span>
                <ControlSeg multiple name="目标护甲" :model-value="state.armors" :items="ARMOR_SEGS" @update:model-value="setArmors" />
              </div>
            </div>
            <div class="ctrl-row">
              <div class="ctrl-cell">
                <span class="ctrl-label">类别</span>
                <ControlSeg multiple name="类别" :model-value="state.cls.length ? state.cls : ['all']" :items="CLASS_SEGS" @update:model-value="setCls" />
              </div>
              <div class="ctrl-cell">
                <span class="ctrl-label">穿透</span>
                <ControlSeg multiple name="穿透等级" :model-value="state.pens.length ? state.pens : ['all']" :items="PEN_SEGS" @update:model-value="setPens" />
              </div>
            </div>
            <div class="ctrl-row">
              <div class="ctrl-cell">
                <span class="ctrl-label">弹药</span>
                <ControlSeg v-model="state.ammoMode" name="弹药模式" :items="AMMO_MODE_SEGS" />
              </div>
              <div class="ctrl-cell">
                <span class="ctrl-label">排序</span>
                <ControlSeg v-model="state.sort" name="排序" :items="SORT_SEGS" />
              </div>
              <div class="ctrl-cell">
                <span class="ctrl-label">修正</span>
                <ControlSeg v-model="state.delay" name="实战修正" :items="DELAY_SEGS" />
              </div>
              <div class="ctrl-cell">
                <span class="ctrl-label">枪械</span>
                <input v-model.trim="state.q" class="search" type="search" placeholder="搜枪名，如 腾龙 / m7" aria-label="搜索枪名" />
              </div>
              <!-- 行尾右对齐说明（视觉验收：该行选项最少、右侧留白明显大于其余行，用文案补齐行尾） -->
              <span class="ctrl-note">多选叠加 · 即时重算</span>
            </div>
          </div>
          <!-- 提示条进出（MOTION §3-F）：外壳 grid-rows 0fr→1fr 承接吸顶面板高度变化
               （红线允许的折叠技法，同 CollapseCol）；内文走全局 swap 淡入淡出 -->
          <div class="ctrl-hint-slot" :class="{ on: !!hintText }">
            <div class="ctrl-hint-clip">
              <Transition name="swap">
                <p v-if="hintText" class="ctrl-hint">{{ hintText }}</p>
              </Transition>
            </div>
          </div>
        </div>

        <!-- reveal-group：行级级联（§7.3）；并挂 reveal 适配 useReveal 现行选择器
             （其扩入 .reveal-group 后容器上的 reveal 可去；两容器同此口径）。
             本容器另受 watch(state) 管控：首次筛选重建即撤下 reveal-group，
             防止 200 行排行在每次筛选/搜索键入时整列重播入场级联（红线） -->
        <ChampCards class="reveal reveal-group" :picks="champPicks" :delay="state.delay" />

        <TierBoard class="reveal" :tiers="tiers" @pick="pickGun" />

        <div class="rank-meta reveal">
          <span class="rank-count">{{ rankCountText }}</span>
        </div>

        <div id="rank" ref="rankEl" class="rank-list reveal reveal-group">
          <div class="rk-head">
            <span>#</span>
            <!-- span2：跨「缩略图 + 枪名」两轨。行内 8 轨（含缩略图列），表头若不跨列，
                 其后所有列头整体左移一轨、对不上数据列 -->
            <span class="span2">武器 / 口径</span>
            <span>弹药</span>
            <span class="num hide-m">射速</span>
            <span class="num hide-m">单发伤</span>
            <span class="num">击杀发数</span>
            <span class="th-ta">TTK<small>条越长越快</small></span>
          </div>
          <template v-if="rankRows.length">
            <RankRow
              v-for="(c, i) in shownRows"
              :key="rowKey(c)"
              :c="c"
              :rank="i + 1"
              :best="bestTtk"
              :tier="tierGun[c.gun.en] || ''"
              :delay="state.delay"
              :show-scen="multiScen"
              :open="openKeys.has(rowKey(c))"
              :combos="allCombos"
              :prices="prices"
              @toggle="toggleRow(c)"
            />
            <!-- 渲染上限兜底：截断时露出文本链「显示更多」，每点一次多渲一批（§5.3 无底无边框规格） -->
            <button
              v-if="shownRows.length < rankRows.length"
              type="button"
              class="rk-more"
              @click="rankLimit += RANK_PAGE"
            >
              显示更多 · 还剩 {{ rankRows.length - shownRows.length }} 行
            </button>
          </template>
          <!-- 空态淡入淡出（MOTION §3-H）：Transition 常驻挂载、内层 v-if 切换，
               enter/leave 都能播放；与行区互斥（rankRows.length），两分支各自独立渲染 -->
          <Transition name="swap">
            <div v-if="!rankRows.length" class="rk-empty">
              <template v-if="filteredGuns.length">当前筛选下没有可用枪弹：该类别没有所选穿透等级（{{ state.pens.length ? state.pens.join('/') : '0-7' }}）的弹药，换一个等级或类别再试。</template>
              <template v-else>没有匹配「{{ state.q.trim() }}」的枪械：搜索按中文名 / 英文名不区分大小写匹配（如 腾龙 / m4 / m7），清空搜索框恢复全表。</template>
            </div>
          </Transition>
        </div>
        <p class="rank-footnote">点击任意一行，展开该枪全部弹药的逐发对比（受当前穿透筛选限定）。TTK 为首发命中后击倒所需的纯射击时间，不含首发出膛、腰射散布、换弹与网速，是站位对枪的理论上限；实战受距离衰减、命中率与压枪影响，通常显著更慢。</p>
      </section>

      <!-- 弹药库 -->
      <h3 id="ammo" class="block-h reveal">
        <span class="bht">弹药库</span><span class="bhline"></span><span class="bhc">{{ ammoCountText }} · {{ marketAgeText }}</span>
      </h3>
      <p class="sec-lede">全枪械涉及的 {{ ammoKeys.length }} 种口径全部弹药。穿透等级决定对各级护甲的伤害通过率（见下方矩阵），肉伤 / 甲伤系数乘算武器面板。表中「参考单发」为该口径基准枪的面板数值，实际随具体武器浮动。</p>
      <div class="ammo-tools">
        <button type="button" class="ammo-toggle" @click="toggleAllAmmo">{{ ammoAllOpen ? '收起全部' : '展开全部' }}</button>
      </div>
      <div class="ammo-list">
        <AmmoTable
          v-for="k in ammoKeys"
          :key="k"
          :cal-key="k"
          :cal="CAL[k]"
          :prices="prices"
          :open="ammoOpen[k]"
          @toggle="ammoOpen[k] = !ammoOpen[k]"
        />
      </div>
      <p class="ammo-market-note reveal">「现价·7 天分位」列为交易行快照（{{ marketAgeText }}；静态部署下快照可能滞后，买卖决策以行情页实时数据为准），点击可跳行情页查看该弹 7 天走势与买卖信号。「—」= 该弹未上架交易行或命名无法一一对应（禁交易弹 / 国服命名差异 / 弓弩用弹）。</p>

      <!-- 版本平衡调整（DFTTK 公告静态镜像，自托管；前端零外部请求） -->
      <h3 id="balance" class="block-h reveal">
        <span class="bht">版本平衡调整</span><span class="bhline"></span><span class="bhc">镜像快照</span>
      </h3>
      <p class="sec-lede">烽火地带版本平衡与数据修正记录。数据一次性镜像自 DFTTK 公告静态 JSON 并自托管（抓取时间见折叠块右侧注释），前端运行时不请求任何外部站点；赛季更新后在仓库根目录运行 npm run dfttk:snapshot 刷新快照。</p>
      <BalanceLog class="reveal" />

      <!-- 穿透 × 护甲 判定矩阵 -->
      <h3 class="block-h reveal">
        <span class="bht">穿透 × 护甲 判定矩阵</span><span class="bhline"></span><span class="bhc">核心机制</span>
      </h3>
      <p class="sec-lede">弹药穿透等级与护甲（头盔）等级比对后决定肉体伤害通过率——这是整张 TTK 排行背后的唯一判定规则。甲破之后，任何子弹都造成 100% 伤害。</p>
      <div class="blocks reveal">
        <PenMatrix :open="matrixOpen" @toggle="matrixOpen = !matrixOpen" />
      </div>

      <!-- 护甲与头盔 -->
      <h3 id="armor" class="block-h reveal">
        <span class="bht">护甲与头盔</span><span class="bhline"></span><span class="bhc">耐久与减伤</span>
      </h3>
      <p class="sec-lede">护甲与头盔共用同一套 1-6 级判定，但耐久各表：躯干按护甲满耐久、头部按头盔满耐久（主流型号口径，见「头盔与部位覆盖」）。实战中残耐久甲会被更快击碎，TTK 介于满耐久与无甲之间。</p>
      <div class="blocks reveal">
        <CollapseCol :open="armorTblOpen" label="护甲等级一览" note="满耐久口径" @toggle="armorTblOpen = !armorTblOpen">
          <div class="tbl-wrap">
            <table class="tbl">
              <thead>
                <tr><th>等级</th><th class="num">满耐久（本页口径）</th><th>代表护甲</th><th>覆盖与说明</th><th>负面</th></tr>
              </thead>
              <tbody>
                <tr class="data-row">
                  <td><PenBadge :p="1" /></td><td class="mono num">25</td><td class="dimtx">尼龙防弹衣</td>
                  <td class="dimc">仅胸，聊胜于无</td><td class="dimc">无</td>
                </tr>
                <tr class="data-row">
                  <td><PenBadge :p="2" /></td><td class="mono num">40</td><td class="dimtx">TG 战术防弹衣</td>
                  <td class="dimc">不护腹部</td><td class="dimc">无</td>
                </tr>
                <tr class="data-row">
                  <td><PenBadge :p="3" /></td><td class="mono num">75</td><td class="dimtx">TG-H 战术防弹衣</td>
                  <td class="dimc">胸 + 腹双护，低档性价比之王</td><td class="dimc">瞄准 -3% · 移速 -1%</td>
                </tr>
                <tr class="data-row">
                  <td><PenBadge :p="4" /></td><td class="mono num">110</td><td class="dimtx">DT-AVS / MK-2 战术背心</td>
                  <td class="dimc">DT-AVS 单品 100，按档位上限计</td><td class="dimc">瞄准 -4% · 移速 -3%</td>
                </tr>
                <tr class="data-row">
                  <td><PenBadge :p="5" solid /></td><td class="mono num">125</td><td class="dimtx">FS 复合防弹衣</td>
                  <td class="dimc">金甲；主流金头耐久 50（铁壁 75）</td><td class="dimc">瞄准 -5% · 移速 -3%</td>
                </tr>
                <tr class="data-row">
                  <td><PenBadge :p="6" solid /></td><td class="mono num">150</td><td class="dimtx">HA-2 重型 / 特里克 MAS2.0</td>
                  <td class="dimc">红甲；仅 6 级弹可对穿（同级 50%）</td><td class="dimc">瞄准 -6% · 移速 -5%</td>
                </tr>
              </tbody>
            </table>
          </div>
        </CollapseCol>

        <CollapseCol :open="helmetOpen" label="头盔与部位覆盖" note="眩晕机制" @toggle="helmetOpen = !helmetOpen">
          <div class="method">
            <div class="m-row">
              <span class="m-num">01</span>
              <div class="m-body">头盔与护甲同一等级体系、同一穿透判定，但<strong>耐久远低于同档护甲</strong>（6 级头最硬也只有 60，6 级甲可达 150）。本页「头部」场景假设目标佩戴与所选护甲同级的头盔，按主流型号满耐久计：3 级 40（DAS / MC201）、4 级 48（GT1；D6 上限 55）、5 级 50（GN 重型；Mask-1 铁壁特例 75）、6 级 60（GT5 指挥官 / H70）。头盔型号间耐久差异极大，残耐久头会被更快击穿。</div>
            </div>
            <div class="m-row">
              <span class="m-num">02</span>
              <div class="m-body">部分头盔<strong>不防护面部与耳部</strong>：裸脸 / 裸耳被击中即使不掉血（被头盔等级挡下）也会触发<strong>眩晕</strong>（屏幕干扰），实战中会显著拉长对方反应时间。</div>
            </div>
            <div class="m-row">
              <span class="m-num">03</span>
              <div class="m-body">护甲只覆盖躯干（因型号而异覆盖胸 / 腹），<strong>四肢永远裸露</strong>（伤害 ×0.4，但可被打出流血 / 黑肢）。修复护甲会损失耐久上限；破损甲只要耐久尚存，减伤判定与全新一致。</div>
            </div>
          </div>
        </CollapseCol>
      </div>

      <!-- 计算口径 -->
      <h3 id="method" class="block-h reveal">
        <span class="bht">计算口径</span><span class="bhline"></span><span class="bhc">6 步模型</span>
      </h3>
      <div class="blocks reveal">
        <CollapseCol :open="methodOpen" label="TTK 是怎么算出来的" note="逐发模拟" @toggle="methodOpen = !methodOpen">
          <div class="method">
            <div class="m-row">
              <span class="m-num">01</span>
              <div class="m-body"><strong>人体模型</strong>：单一血池 100 点，无部位血量（不同于塔科夫）。部位伤害倍率：头部 ×1.9、胸部 ×1.0、腹部 ×0.9、四肢 ×0.4。血池归零即倒。个别武器有专属倍率（RM277、MK4 胸腹同伤），已按武器单独修正。</div>
            </div>
            <div class="m-row">
              <span class="m-num">02</span>
              <div class="m-body"><strong>单发伤害</strong>：单发肉伤 = 武器面板伤害 × 弹药肉伤系数（RIP 等肉弹 ×1.30，亚音速 ×1.05，其余 ×1.00）× 部位倍率。对甲耐久伤害 = 武器面板甲伤 × 弹药甲伤系数。</div>
            </div>
            <div class="m-row">
              <span class="m-num">03</span>
              <div class="m-body"><strong>穿透判定</strong>：弹药穿透等级对比护甲等级——低于甲 <strong>0%</strong>（只碎甲不掉血）、同级 <strong>50%</strong>、高 1 级 <strong>75%</strong>、高 2 级及以上 <strong>100%</strong>。判定矩阵见上一节。</div>
            </div>
            <div class="m-row">
              <span class="m-num">04</span>
              <div class="m-body"><strong>碎甲过程</strong>：护甲有耐久时先被甲伤削减；耐久不足以吃满一发时，该发按剩余耐久比例部分穿透（k 值规则），甲碎后全额掉血。目标按满耐久计：躯干护甲 4/5/6 级 = 110 / 125 / 150，头盔按主流型号 4/5/6 级 = 48 / 50 / 60。不计最后一发的伤害溢出，实战 TTK 只会更快。</div>
            </div>
            <div class="m-row">
              <span class="m-num">05</span>
              <div class="m-body"><strong>TTK 公式</strong>：
                <div class="m-formula">TTK = 60000 ÷ RPM × (BTK − 1) <span class="c">// 逐发匀速展开：每发间隔 60000/RPM，首发命中即刻出膛不计入时间</span></div>
                <div class="m-body"><strong>三连发武器（M16A4 / MK4 / 93R）</strong>：面板射速为计入两轮 burst 之间间隔的<strong>持续平均值</strong>（burst 内部射速更高，MK4 约接近 MP7 的 ~950）。本页按面板均值匀速近似：跨 burst 的多发击倒平均误差很小；单个 burst 内的击杀（≤3 发）实际比本页数字更快。burst 组间再开火间隔不作单独建模。</div>
              </div>
            </div>
            <div class="m-row">
              <span class="m-num">06</span>
              <div class="m-body"><strong>假设与未计入项</strong>：近距离（无距离衰减）；满耐久护甲；不计跳弹、配件对伤害 / 射速的改动、腰射散布与后坐压枪、换弹与切枪；三连发武器的 burst 内部射速与组间再开火间隔不单独建模（见 TTK 公式一节的近似口径）；霰弹枪按整弹（8 弹丸合计）伤害建模，不计弹丸散布与逐弹丸穿透；栓狙按栓动循环射速近似；S8-S11 平衡补丁可能使个别武器面板 ±1-3。列表中的单发伤害为穿透全额后的值，碎甲期间实际通过率见详情卡。</div>
            </div>
          </div>
        </CollapseCol>

        <CollapseCol :open="sourceOpen" label="已知限制" note="以游戏内为准" @toggle="sourceOpen = !sourceOpen">
          <div class="src-body">
            <p class="src-p"><strong>已知限制</strong>：面板数值可能与游戏内当前值有出入，MCX LT 甲伤缺实测（取同口径 K437 参考值 35）；.300 BLK 超音速 / 超压弹、5.45 超压、12.7x55 等新弹型号与穿透等级未完全验证；S8-S11 对 SG552、PTR-32、KC17、M7、ASh-12 等有平衡性调整，数值请以游戏内当前面板为准。AA-12 甲伤与弹匣、Marlin RN 弹等级、部分手枪上线赛季未验证；S9-S11 赛季限定功能弹（CT 修脚、5.8 +P 超压、PLY、AP ST、.45 Super 金弹）因穿透等级 / 系数未披露未收录。版本更新后请以游戏内训练场实测校准。</p>
          </div>
        </CollapseCol>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* ---------- 页头走 base.css .compact-head（单行式） ---------- */

/* 数据页底部留白：与 ammo / radar .page 同取 --sp-10（80px） */
.ttk-page { padding-bottom: var(--sp-10); }

/* ---------- 区块导语 ---------- */
.sec-lede {
  max-width: 760px;
  color: var(--dim);
  font-size: var(--fs-sm);
  line-height: 1.85;
  margin: -6px 0 18px;
}

/* ---------- 控制面板（吸顶，§5.10：实底弃 blur）---------- */
.ctrl {
  position: sticky;
  top: 8px;
  z-index: 30;
  background: var(--panel-solid);
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  padding: 11px 14px 9px;
  margin: var(--sp-4) 0 0;
  box-shadow: var(--shadow-md);
}
/* 三行各占一横行（column），行内两组并排；收紧行距/内边距压缩面板总高 */
.ctrl-rows {
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
}
.ctrl-row {
  display: flex;
  align-items: center;
  gap: var(--sp-2) 14px;
  flex-wrap: wrap;
  min-width: 0;
}
/* label+控件包成 ctrl-cell 整组换行：中窄宽度下组内标签不孤行 */
.ctrl-cell {
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
}
/* 末行行尾右对齐说明：补齐「弹药+排序」行（选项最少）的右侧留白；行内放不下时整条换行右贴 */
.ctrl-note {
  margin-left: auto;
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  letter-spacing: .1em;
  color: var(--faint);
  white-space: nowrap;
}
.ctrl-label {
  font-family: var(--mono);
  font-size: var(--fs-micro);
  letter-spacing: .24em;
  color: var(--faint);
  flex: none;
}
.ctrl-hint {
  margin-top: 9px;
  font-size: var(--fs-xs);
  color: var(--faint);
  line-height: 1.6;
}
/* 提示条槽（MOTION §3-F）：外壳 grid-rows 0fr→1fr 承接高度——吸顶面板高随提示
   出现/收起平滑变化、下方内容不跳；clip 是折叠裁剪层（同 CollapseCol .col-inner 口径，
   .ctrl-hint 的 margin-top 落在 clip 内随 0fr 一并裁掉） */
.ctrl-hint-slot {
  display: grid;
  grid-template-rows: 0fr;
  transition: grid-template-rows var(--t-panel) var(--ease);
}
.ctrl-hint-slot.on { grid-template-rows: 1fr; }
.ctrl-hint-clip { overflow: hidden; min-height: 0; }

/* ---------- 枪械搜索框（规格同 AmmoMarket / MarketRadar 的 .search：胶囊输入、只改边框） ---------- */
.search {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-pill);
  color: var(--tx); font-size: var(--fs-xs); padding: 5px 14px; width: 170px;
  font-family: var(--sans); /* 表单控件不吃 body 字阶，显式声明（同 .qty-in 显式 --mono 的口径） */
  transition: border-color var(--t-fast) var(--ease);
}
/* 键盘可达走全局 :focus-visible 外框；:focus 只做边框提亮，不抹 outline */
.search:focus { border-color: var(--accent-dim); }

/* ---------- 弹药库「展开全部 / 收起全部」（文本链按钮，§5.3：无底无边框） ---------- */
.ammo-tools {
  display: flex;
  justify-content: flex-end;
  margin-bottom: var(--sp-2);
}
.ammo-toggle {
  border: 0;
  background: none;
  padding: 0;
  font-family: var(--mono);
  font-size: var(--fs-xs);
  letter-spacing: .08em;
  color: var(--accent);
  cursor: pointer;
}
/* 按下同 hover（文本链按钮规格，与 .src-note a / .pb-src a 统一） */
.ammo-toggle:hover,
.ammo-toggle:active { text-decoration: underline; }
/* 弹药库现价列口径说明（数据龄 / 「—」语义），规格同 .rank-footnote */
.ammo-market-note {
  margin: var(--sp-3) 0 0;
  font-size: var(--fs-xs);
  color: var(--faint);
  line-height: 1.7;
}

/* ---------- rank-meta / 列表外壳（上距 16：champs 与计数行同屏收紧） ---------- */
.rank-meta {
  display: flex;
  align-items: baseline;
  gap: 14px;
  flex-wrap: wrap;
  margin: var(--sp-4) 0 var(--sp-3);
}
.rank-count {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  color: var(--faint);
  letter-spacing: .05em;
}
.rank-list {
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  background: var(--card);
  overflow: hidden;
}
/* 表头（§5.4：底色 card2 比行亮、padding 与行 11px 对齐消除基线错位；栅格值与 RankRow 内 .rk-row 保持同值，
   枪名/TTK 轨配比随 RankRow 同步调整为 1.35fr/1fr——枪名副行 302px 全显） */
.rk-head {
  display: grid;
  grid-template-columns: 40px 52px minmax(138px, 1.35fr) minmax(126px, 1fr) 52px 60px 62px minmax(140px, 1fr);
  gap: 12px;
  align-items: center;
  padding: 10px 34px 10px 16px;
  border-bottom: 1px solid var(--line);
  background: var(--card2);
}
.rk-head span {
  font-family: var(--mono);
  font-size: var(--fs-micro);
  letter-spacing: .18em;
  color: var(--faint);
  white-space: nowrap;
}
/* 「武器 / 口径」表头跨缩略图+枪名两轨（与行内 8 轨对齐，见模板注释；820 断点同样生效） */
.rk-head .span2 { grid-column: span 2; }
.rk-head .num { text-align: right; }
.rk-head .th-ta { text-align: right; }
.rk-head .th-ta small {
  font-size: var(--fs-micro);
  letter-spacing: .08em;
  color: var(--faint);
  display: block;
}
/* 不再叠 opacity：--faint 在 --card2 上恰 4.63:1（AA 下限），再打折会跌破可读底线 */
.rk-empty {
  padding: 28px 16px;
  text-align: center;
  font-size: var(--fs-xs);
  color: var(--faint);
  line-height: 1.7;
}
/* 空态离场瞬时（复核修正）：swap 的 leave 淡出会让「没有匹配」提示与瞬时渲染的
   行区在表格底部同屏 250ms（Transition 只包空态分支、行区在其外，无 mode 互斥），
   出现「有结果却显示无结果」的矛盾画面——进场保留 swap 淡入，离场即时消失；
   本条 scoped（0,2,0）压过全局 .swap-leave-active（0,1,0） */
.rk-empty.swap-leave-active { transition: none; }
/* 「显示更多」（文本链按钮规格同 .ammo-toggle，§5.3：无底无边框）；列表内整行居中收尾 */
.rk-more {
  display: block;
  width: 100%;
  border: 0;
  background: none;
  padding: var(--sp-3) var(--sp-4);
  font-family: var(--mono);
  font-size: var(--fs-xs);
  letter-spacing: .08em;
  color: var(--accent);
  cursor: pointer;
}
.rk-more:hover,
.rk-more:active { text-decoration: underline; }
.rank-footnote {
  margin-top: var(--sp-3);
  font-size: var(--fs-xs);
  color: var(--faint);
  line-height: 1.7;
}

/* ---------- 折叠块容器 / 表格 / 方法与来源（表格基座走 base.css 全局 .tbl） ---------- */
.blocks { margin-bottom: 14px; }
.tbl-wrap {
  overflow-x: auto;
  padding: var(--sp-3) var(--sp-4);
}
.tbl { min-width: 640px; }

.method { padding: var(--sp-3) var(--sp-4); }
.m-row {
  display: flex;
  gap: 13px;
  padding: 11px 2px;
  border-bottom: 1px solid var(--line2);
}
.m-row:last-child { border-bottom: 0; }
.m-num {
  flex: none;
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  color: var(--accent);
  padding-top: 3px;
  min-width: 22px;
}
.m-body {
  font-size: var(--fs-sm);
  color: var(--dim);
  line-height: 1.85;
  min-width: 0;
}
.m-body strong { color: var(--tx-strong); }
.m-formula {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  background: var(--bg2);
  border: 1px solid var(--line2);
  border-radius: var(--radius);
  padding: 10px 14px;
  margin: 9px 0 2px;
  color: var(--tx-strong);
  line-height: 1.9;
  overflow-x: auto;
  white-space: nowrap;
}
.m-formula .c { color: var(--faint); }
.src-body { padding: var(--sp-3) var(--sp-4); }
.src-p {
  font-size: var(--fs-xs);
  color: var(--faint);
  line-height: 1.85;
  margin-bottom: 13px;
}
.src-p:last-child { margin-bottom: 0; }
.src-p a {
  color: var(--dim);
  text-decoration: none;
  border-bottom: 1px solid var(--line);
}
.src-p a:hover,
.src-p a:active {
  color: var(--accent);
  border-color: var(--accent-dim);
}
.src-p strong { color: var(--dim); }

/* ---------- 响应式（断点收敛为 820 / 680，§4.1） ---------- */
@media (max-width: 680px) {
  .ctrl {
    padding: 12px 12px 10px;
  }
  .ctrl-rows { gap: 10px 0; }
  .ctrl-row {
    flex-wrap: wrap;
    width: 100%;
  }
  /* 每组（label+控件）整组占一横行，与旧六行结构的手机端堆叠形态一致 */
  .ctrl-cell { width: 100%; flex-wrap: wrap; }
  /* 搜索框随整组占满一行（label 已换行在上方） */
  .search { width: 100%; }
  /* 手机端控件已纵向堆叠、无行尾留白问题，说明文案退场（信息由 .ctrl-hint 承担） */
  .ctrl-note { display: none; }
  .ctrl-label {
    width: 100%;
    margin-bottom: 3px;
  }
}
@media (max-width: 820px) {
  /* ≤820 断点：表头换窄栅格（padding 与行触达口径一致，§5.4） */
  .rk-head {
    grid-template-columns: 26px 44px minmax(0, 1.2fr) minmax(0, 1fr) 42px 82px;
    gap: 7px;
    padding: 10px 12px;
  }
  .rk-head .hide-m { display: none; }
}
@media (max-width: 680px) {
  .ctrl {
    padding: 11px 12px 9px;
    /* 手机解除吸顶（同 AmmoMarketView .ctl-sticky 口径）：六组控件全宽堆叠后面板高近半屏，
       常驻吸顶会长期遮挡排行内容；滚动回顶部即可改筛选 */
    position: static;
  }
  .ctrl-rows { gap: 7px; }
  .ctrl-row { gap: var(--sp-2); }
  .m-formula { white-space: normal; }
  .rank-meta {
    flex-direction: column;
    align-items: flex-start;
    gap: var(--sp-2);
  }
  /* ≤680 行改两行式卡片（RankRow），列头与任何一轨都不再对应（先例：详情 .drow.capt 同断点隐藏）；
     数字自带单位（发 / ms），表头退场比错位列头更诚实 */
  .rk-head { display: none; }
}

/* RM 统一兜底（本页 scoped 部分）：全局 .swap/.sk 的关停在 motion.css 文件尾；
   这里只补页面自有过渡——搜索框边框提亮、提示条槽高度动画 */
@media (prefers-reduced-motion: reduce) {
  .search { transition: none; }
  .ctrl-hint-slot { transition: none; }
}
</style>
