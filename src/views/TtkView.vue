<script setup>
/* ============================================================
   TtkView — TTK 击杀时间排行（/ttk）
   自 legacy/ttk.html 迁移：数据/模型在 src/data/ttk/*（68 枪全组合对拍 7791 例逐值一致），
   交互口径：部位（胸/腹/头）多选、目标护甲 0-6 多选、类别（7 兵种）多选、
   子弹模式（最佳/全部）单选 + 穿透等级多选、排序（TTK/发数，#ctrl 内 segSort 与
   rank-meta 内 segSort2 双控件同绑 state.sort）；
   多选即叠加场景：列表按"枪 × 弹 × 部位 × 护甲"展开，
   "每枪最佳弹药"模式每枪每场景取最快一发行。
   排行行点开懒加载逐发模拟、弹药库全表、穿透×护甲判定矩阵。
   ============================================================ */
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import ControlSeg from './ttk/ControlSeg.vue'
import ChampCards from './ttk/ChampCards.vue'
import RankRow from './ttk/RankRow.vue'
import AmmoTable from './ttk/AmmoTable.vue'
import PenMatrix from './ttk/PenMatrix.vue'
import PenBadge from './ttk/PenBadge.vue'
import CollapseCol from '../components/CollapseCol.vue'
import { CAL } from '../data/ttk/calibers.js'
import { GUNS } from '../data/ttk/guns.js'
import { DUR, HEAD_DUR, PARTS } from '../data/ttk/armor.js'
import { combo } from '../data/ttk/model.js'
import { PART_CHAR, scenLabel } from './ttk/format.js'

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
/* 兵种元信息（legacy CLS_META L704-712 原样）：类别段与场景最快卡共用 */
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
  { v: 'best', label: '每枪最佳弹药', title: '每把枪在每个场景取符合筛选的弹药中最快的一发弹' },
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
  { v: 7, label: '7', dot: 'linear-gradient(135deg, var(--lv6), color-mix(in srgb, var(--lv6) 62%, var(--bg)))', title: '7 级穿透弹（全游戏仅 AWM / M82 可用）' },
]
const SORT_SEGS = [
  { v: 'ttk', label: 'TTK' },
  { v: 'btk', label: '发数' },
]

/* ---------- 状态：部位/护甲/类别/穿透等级均为多选（数组），子弹模式与排序单选 ---------- */
const state = reactive({ parts: ['chest'], armors: [5], cls: [], ammoMode: 'best', pens: [], sort: 'ttk' })

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

/* 任意筛选/排序变化即重建列表：展开行全部收起（legacy renderAll 重建 DOM 的同口径行为） */
const openKeys = reactive(new Set())
watch(state, () => openKeys.clear())

/* ---------- 计算：多选场景笛卡尔展开（枪 × 弹 × 部位 × 护甲） ---------- */
const filteredGuns = computed(() =>
  state.cls.length ? GUNS.filter((g) => state.cls.includes(g.cls)) : GUNS)

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

const bestTtk = computed(() => (rankRows.value.length ? rankRows.value[0].ttk : 1))

const rowKey = (c) => c.gun.en + '|' + c.am.n + '|' + c.part + '|' + c.armor
const toggleRow = (c) => {
  const k = rowKey(c)
  if (openKeys.has(k)) openKeys.delete(k)
  else openKeys.add(k)
}

const rankCountText = computed(() => {
  const bits = [rankRows.value.length + ' 行']
  if (state.pens.length)
    bits.push('弹药：仅 ' + [...state.pens].sort((a, b) => a - b).join('/') + ' 级穿透弹')
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

/* 场景最快卡（legacy renderChamps L917-941：ALL + 所选类别各一张） */
const champPicks = computed(() => {
  const combos = allCombos.value
  const best = (list) => list.reduce((m, c) => (c.ttk < m.ttk ? c : m), list[0])
  const picks = []
  if (combos.length) picks.push({ label: '场景最快 · ALL', c: best(combos), top: true })
  for (const m of CLS_META) {
    if (state.cls.length && !state.cls.includes(m.k)) continue
    const list = combos.filter((c) => c.gun.cls === m.k)
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
      bits.push('6 级头只有 6 级弹可对穿（同级 50%）；5 级金弹打红盔已是低一级，需先碎 60 耐久头盔。')
    else if (state.parts.length === 1)
      bits.push('6 级甲只有 6 级弹可对穿（同级 50%）；5 级弹打红甲已是低一级，需先碎甲 150 耐久。')
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
      bits.push(miss.length + ' 把枪无所选等级弹药未入列：' + show + '。')
    }
  }
  if (state.parts.length === 1 && state.parts[0] === 'chest' && state.armors.length === 1 && state.armors[0] > 0)
    bits.push('护甲满耐久按 ' + DUR[state.armors[0]] + ' 计；残甲目标更快倒地。')
  return bits.join(' ')
})

/* ---------- 弹药库（装配一次、展开态不随筛选重置，legacy L968 同口径） ---------- */
const ammoKeys = Object.keys(CAL)
const ammoTotal = ammoKeys.reduce((s, k) => s + CAL[k].ammo.length, 0)
const ammoCountText = ammoKeys.length + ' 种口径 · ' + ammoTotal + ' 种弹药'
const ammoOpen = reactive(Object.fromEntries(ammoKeys.map((k) => [k, true])))

/* ---------- 静态折叠块开关（legacy 初始态：矩阵/护甲表/方法开，头盔/来源收） ---------- */
const matrixOpen = ref(true)
const armorTblOpen = ref(true)
const helmetOpen = ref(false)
const methodOpen = ref(true)
const sourceOpen = ref(false)

/* ---------- reveal 入场（legacy 尾部 IntersectionObserver 同参） ---------- */
const rootEl = ref(null)
const PAGE_TITLE = '三角洲行动 · TTK 击杀时间排行（全枪械）'
let io = null
let prevTitle = ''

onMounted(() => {
  prevTitle = document.title
  document.title = PAGE_TITLE
  const els = rootEl.value ? rootEl.value.querySelectorAll('.reveal') : []
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches
  if (!('IntersectionObserver' in window) || reduced) {
    els.forEach((n) => n.classList.add('in'))
    return
  }
  io = new IntersectionObserver((entries) => {
    entries.forEach((en) => {
      if (en.isIntersecting) {
        en.target.classList.add('in')
        io.unobserve(en.target)
      }
    })
  }, { threshold: 0.04, rootMargin: '0px 0px -3% 0px' })
  els.forEach((n) => io.observe(n))
})

onBeforeUnmount(() => {
  if (io) io.disconnect()
  document.title = prevTitle
})
</script>

<template>
  <div ref="rootEl" class="ttk-page">
    <!-- 页头：返回链接已删（全局顶栏三 tab 常驻，legacy 独立页时代的返回条冗余） -->
    <section class="page-head">
      <div class="wrap">
        <p class="kicker">DELTA FORCE · BALLISTICS LAB</p>
        <h1>TTK 击杀时间排行 · 全枪械</h1>
        <p class="lede">烽火地带口径下的理论击杀时间（TTK）与击杀所需子弹数（BTK）排行：基于武器面板、全部可用弹药与穿透 × 护甲减伤逐发模拟得出。部位、护甲、类别与穿透等级支持多选叠加，排行即时重算；模拟口径与未计入项见下方「计算口径」一节。</p>
        <p class="meta">数据基线 S5 全枪表（2025-07）并补充至 S11（2026-09） · 减伤采用国服社区实测口径 · 非官方数据，仅供研究参考</p>
      </div>
    </section>

    <div id="top" class="wrap">
      <section aria-label="TTK 排行">
        <!-- 控制面板：五组分段控件（legacy #ctrl，另有 rank-meta 内 segSort2 共六组） -->
        <div class="ctrl reveal">
          <div class="ctrl-rows">
            <div class="ctrl-row">
              <span class="ctrl-label">部位</span>
              <ControlSeg multiple :model-value="state.parts" :items="PART_SEGS" @update:model-value="setParts" />
            </div>
            <div class="ctrl-row">
              <span class="ctrl-label">目标护甲</span>
              <ControlSeg multiple :model-value="state.armors" :items="ARMOR_SEGS" @update:model-value="setArmors" />
            </div>
            <div class="ctrl-row">
              <span class="ctrl-label">类别</span>
              <ControlSeg multiple :model-value="state.cls.length ? state.cls : ['all']" :items="CLASS_SEGS" @update:model-value="setCls" />
            </div>
            <div class="ctrl-row">
              <span class="ctrl-label">子弹</span>
              <ControlSeg v-model="state.ammoMode" :items="AMMO_MODE_SEGS" />
              <ControlSeg multiple :model-value="state.pens.length ? state.pens : ['all']" :items="PEN_SEGS" @update:model-value="setPens" />
            </div>
            <div class="ctrl-row">
              <span class="ctrl-label">排序</span>
              <ControlSeg v-model="state.sort" :items="SORT_SEGS" />
            </div>
          </div>
          <p v-if="hintText" class="ctrl-hint">{{ hintText }}</p>
        </div>

        <ChampCards class="reveal" :picks="champPicks" />

        <div class="rank-meta reveal">
          <span class="rank-count">{{ rankCountText }}</span>
          <!-- segSort2：与 #ctrl 内 segSort 同绑 state.sort（legacy L308/L642） -->
          <div class="rank-sort">
            <span class="ctrl-label">按</span>
            <ControlSeg v-model="state.sort" :items="SORT_SEGS" />
          </div>
        </div>

        <div class="rank-list reveal">
          <div class="rk-head">
            <span>#</span>
            <span>武器 / 口径</span>
            <span>弹药</span>
            <span class="num hide-m">射速</span>
            <span class="num hide-m">单发伤</span>
            <span class="num">击杀</span>
            <span class="th-ta">TTK<small>条越长越快</small></span>
          </div>
          <template v-if="rankRows.length">
            <RankRow
              v-for="(c, i) in rankRows"
              :key="rowKey(c)"
              :c="c"
              :rank="i + 1"
              :best="bestTtk"
              :show-scen="multiScen"
              :open="openKeys.has(rowKey(c))"
              :combos="allCombos"
              @toggle="toggleRow(c)"
            />
          </template>
          <div v-else class="rk-empty">当前筛选组合下没有可用枪弹：该类别没有使用所选穿透等级（{{ state.pens.length ? state.pens.join('/') : '0-7' }}）的武器，换一个等级或类别试试。</div>
        </div>
        <p class="rank-footnote">点击任意一行可展开该武器可用弹药（受当前子弹筛选限定）的逐发模拟对比。TTK 为首发命中后击倒所需的纯射击时间（不含首发出膛、腰射散布、换弹与网速），仅为站位对枪的理论上限；实战受距离衰减、命中率与压枪水平影响，通常显著更慢。</p>
      </section>

      <!-- 弹药库 -->
      <h3 id="ammo" class="block-h reveal">
        <span class="bht">弹药库</span><span class="bhline"></span><span class="bhc">{{ ammoCountText }}</span>
      </h3>
      <p class="sec-lede">全枪械涉及的 20 种口径全部弹药。穿透等级决定对各级护甲的伤害通过率（见下方矩阵），肉伤 / 甲伤系数乘算武器面板。表中"参考单发"为该口径基准枪的面板数值，实际随具体武器浮动。</p>
      <div class="ammo-list">
        <AmmoTable
          v-for="k in ammoKeys"
          :key="k"
          :cal-key="k"
          :cal="CAL[k]"
          :open="ammoOpen[k]"
          @toggle="ammoOpen[k] = !ammoOpen[k]"
        />
      </div>

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
        <span class="bht">护甲与头盔</span><span class="bhline"></span><span class="bhc">6 级体系</span>
      </h3>
      <p class="sec-lede">护甲与头盔共用同一套 1-6 级判定，但耐久各表：躯干按护甲满耐久、头部按头盔满耐久（主流型号口径，见"头盔与部位覆盖"）。实战中残耐久甲会被更快击碎，TTK 介于满耐久与无甲之间。</p>
      <div class="blocks reveal">
        <CollapseCol :open="armorTblOpen" label="护甲等级一览" note="满耐久口径" @toggle="armorTblOpen = !armorTblOpen">
          <div class="tbl-wrap">
            <table class="tbl">
              <thead>
                <tr><th>等级</th><th>满耐久（本页口径）</th><th>代表护甲</th><th>覆盖与说明</th><th>负面</th></tr>
              </thead>
              <tbody>
                <tr>
                  <td><PenBadge :p="1" /></td><td class="mono num">25</td><td class="dimtx">尼龙防弹衣</td>
                  <td class="dimc">仅胸，聊胜于无</td><td class="dimc">无</td>
                </tr>
                <tr>
                  <td><PenBadge :p="2" /></td><td class="mono num">40</td><td class="dimtx">TG 战术防弹衣</td>
                  <td class="dimc">不护腹部</td><td class="dimc">无</td>
                </tr>
                <tr>
                  <td><PenBadge :p="3" /></td><td class="mono num">75</td><td class="dimtx">TG-H 战术防弹衣</td>
                  <td class="dimc">胸 + 腹双护，低档性价比之王</td><td class="dimc">瞄准 -3% · 移速 -1%</td>
                </tr>
                <tr>
                  <td><PenBadge :p="4" /></td><td class="mono num">110</td><td class="dimtx">DT-AVS / MK-2 战术背心</td>
                  <td class="dimc">DT-AVS 单品 100，按档位上限计</td><td class="dimc">瞄准 -4% · 移速 -3%</td>
                </tr>
                <tr>
                  <td><PenBadge :p="5" /></td><td class="mono num">125</td><td class="dimtx">FS 复合防弹衣</td>
                  <td class="dimc">金甲；金头耐久上限约 50</td><td class="dimc">瞄准 -5% · 移速 -3%</td>
                </tr>
                <tr>
                  <td><PenBadge :p="6" /></td><td class="mono num">150</td><td class="dimtx">HA-2 重型 / 特里克 MAS2.0</td>
                  <td class="dimc">红甲；仅 6 级弹可对穿（同级 50%）</td><td class="dimc">瞄准 -6% · 移速 -5%</td>
                </tr>
              </tbody>
            </table>
          </div>
        </CollapseCol>

        <CollapseCol :open="helmetOpen" label="头盔与部位覆盖" note="眩晕机制" @toggle="helmetOpen = !helmetOpen">
          <div class="method">
            <div class="m-row">
              <span class="m-num">◆</span>
              <div class="m-body">头盔与护甲同一等级体系、同一穿透判定，但<strong>耐久远低于同档护甲</strong>（6 级头最硬也只有 60，6 级甲可达 150）。本页"头部"场景假设目标佩戴与所选护甲同级的头盔，按主流型号满耐久计：3 级 40（DAS / MC201）、4 级 48（GT1；D6 上限 55）、5 级 50（GN 重型；Mask-1 铁壁特例 75）、6 级 60（GT5 指挥官 / H70）。头盔型号间耐久差异极大，残耐久头会被更快击穿。</div>
            </div>
            <div class="m-row">
              <span class="m-num">◆</span>
              <div class="m-body">部分头盔<strong>不防护面部与耳部</strong>：裸脸 / 裸耳被击中即使不掉血（被头盔等级挡下）也会触发<strong>眩晕</strong>（屏幕干扰），实战中会显著拉长对方反应时间。</div>
            </div>
            <div class="m-row">
              <span class="m-num">◆</span>
              <div class="m-body">护甲只覆盖躯干（因型号而异覆盖胸 / 腹），<strong>四肢永远裸露</strong>（伤害 ×0.4，但可被打出流血 / 黑肢）。修复护甲会损失耐久上限；破损甲只要耐久尚存，减伤判定与全新一致。</div>
            </div>
          </div>
        </CollapseCol>
      </div>

      <!-- 计算口径 -->
      <h3 id="method" class="block-h reveal">
        <span class="bht">计算口径</span><span class="bhline"></span><span class="bhc">逐步说明</span>
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
              <div class="m-body"><strong>TTK 公式</strong>（社区通用口径）：
                <div class="m-formula">TTK = 60000 ÷ RPM × (BTK − 1) <span class="c">// 逐发匀速展开：每发间隔 60000/RPM，首发命中即刻出膛不计入时间</span></div>
                <div class="m-body"><strong>三连发武器（M16A4 / MK4 / 93R）</strong>：面板射速为计入两轮 burst 之间间隔的<strong>持续平均值</strong>（社区 wiki 口径，burst 内部射速更高，MK4 约接近 MP7 的 ~950）。本页按面板均值匀速近似：跨 burst 的多发击倒平均误差很小；单个 burst 内的击杀（≤3 发）实际比本页数字更快。burst 组间再开火间隔暂无可靠公开实测，不作单独建模。</div>
              </div>
            </div>
            <div class="m-row">
              <span class="m-num">06</span>
              <div class="m-body"><strong>假设与未计入项</strong>：近距离（无距离衰减）；满耐久护甲；不计跳弹、配件对伤害 / 射速的改动、腰射散布与后坐压枪、换弹与切枪；三连发武器的 burst 内部射速与组间再开火间隔不单独建模（见 TTK 公式一节的近似口径）；霰弹枪按整弹（8 弹丸合计）伤害建模，不计弹丸散布与逐弹丸穿透；栓狙按栓动循环射速近似；S8-S11 平衡补丁可能使个别武器面板 ±1-3。列表中的单发伤害为穿透全额后的值，碎甲期间实际通过率见详情卡。</div>
            </div>
          </div>
        </CollapseCol>

        <CollapseCol :open="sourceOpen" label="资料来源与已知限制" note="社区口径" @toggle="sourceOpen = !sourceOpen">
          <div class="src-body">
            <p class="src-p"><strong>来源依据</strong>：武器肉伤 / 甲伤 / 射速以游民星空"树人"S1 全枪表与 TapTap《S5 烽火全枪表》为基线，S6-S11 新枪（MK47、RM277、MDR、AR-57、MCX LT、K437、汤姆逊、MK4、KC17 等）取各自赛季测评；RPM 经 Delta Force Fandom Wiki 全枪表交叉核验一致。减伤判定（0/50/75/100）、部位倍率、100 血模型与 TTK 公式来自 <a href="https://www.taptap.cn/moment/673910625788757239" target="_blank" rel="noopener">TapTap 官方攻略组·护甲系统全面解析</a>、<a href="https://sanjiaozhou.org/newcomers/delta-force-armor-system-guide" target="_blank" rel="noopener">sanjiaozhou.org 护甲机制解析</a>、日升软件等多来源一致的社区实测；弹药型号与穿透等级参考 The Delta Handbook 弹药表、deltagamehub 及 3DM / 游民星空图鉴。2026-10 全兵种扩充（射手步枪 / 狙击枪 / 轻机枪 / 霰弹枪 / 手枪与 7 个新口径）以 orzice 数据站实时面板为主源，经 deltaforcedb、萌娘百科武器库、Delta Force Fandom Wiki 与各赛季官方公告 / 攻略交叉核验。</p>
            <p class="src-p"><strong>已知限制</strong>：官方从未公布完整数值表，本页为社区口径的静态整理，可能与游戏内实际面板有出入；MK4（另有 23/32 一说）与 MK47（另有 30/48 一说）存在来源冲突，MCX LT 甲伤缺实测（取同口径 K437 参考值 35）；.300 BLK 超音速 / 超压弹、5.45 超压、12.7x55 等新弹型号与穿透等级未完全验证；S8-S11 对 SG552、PTR-32、KC17、M7、ASh-12 等有平衡性调整，数值请以游戏内当前面板为准。栓狙三把（R93 / M700 / SV-98）另有旧社区口径 61/58，本表取当前面板 55/53；AA-12 甲伤与弹匣、Marlin RN 弹等级、部分手枪上线赛季未验证；S9-S11 赛季限定功能弹（CT 修脚、5.8 +P 超压、PLY、AP ST、.45 Super 金弹）因穿透等级 / 系数未披露未收录。</p>
            <p class="src-p"><strong>时效</strong>：整理于 2026-10。武器面板基线为 S5（2025-07）+ 赛季增补，减伤与部位倍率为国服现行口径。版本更新后请以游戏内训练场实测校准。</p>
          </div>
        </CollapseCol>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* ---------- 页头（legacy .site-head；字级/眉题/导语走 base.css 全局） ---------- */
.page-head {
  padding: 64px 0 40px;
  border-bottom: 1px solid var(--line2);
}

/* ---------- 区块导语 ---------- */
.sec-lede {
  max-width: 760px;
  color: var(--dim);
  font-size: var(--fs-sm);
  line-height: 1.85;
  margin: -6px 0 18px;
}

/* ---------- 控制面板（legacy .ctrl，吸顶） ---------- */
.ctrl {
  position: sticky;
  top: 12px;
  z-index: 30;
  background: var(--panel);
  backdrop-filter: blur(12px);
  -webkit-backdrop-filter: blur(12px);
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  padding: 13px 16px 11px;
  margin: 26px 0 0;
  box-shadow: var(--shadow-md);
}
.ctrl-rows {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-2) 26px;
}
.ctrl-row {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
  min-width: 0;
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

/* ---------- rank-meta / 列表外壳 ---------- */
.rank-meta {
  display: flex;
  align-items: baseline;
  gap: 14px;
  flex-wrap: wrap;
  margin: 20px 0 10px;
}
.rank-count {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  color: var(--faint);
  letter-spacing: .05em;
}
.rank-sort {
  margin-left: auto;
  display: flex;
  align-items: center;
  gap: var(--sp-2);
}
.rank-sort .ctrl-label { font-size: var(--fs-micro); }
.rank-list {
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  background: var(--card);
  overflow: hidden;
}
/* 表头（legacy .rk-head；栅格值与 RankRow 内 .rk-row 保持同值） */
.rk-head {
  display: grid;
  grid-template-columns: 40px minmax(150px, 1.15fr) minmax(140px, 1fr) 52px 60px 62px minmax(150px, 1.2fr);
  gap: 12px;
  align-items: center;
  padding: 9px 34px 9px 16px;
  border-bottom: 1px solid var(--line);
  background: var(--bg2);
}
.rk-head span {
  font-family: var(--mono);
  font-size: var(--fs-micro);
  letter-spacing: .18em;
  color: var(--faint);
  white-space: nowrap;
}
.rk-head .num { text-align: right; }
.rk-head .th-ta { text-align: right; }
.rk-head .th-ta small {
  font-size: var(--fs-micro);
  letter-spacing: .08em;
  color: var(--faint);
  opacity: .78;
  display: block;
}
.rk-empty {
  padding: 28px 16px;
  text-align: center;
  font-size: var(--fs-xs);
  color: var(--faint);
  line-height: 1.7;
}
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
  padding: 2px 10px 12px;
}
.tbl { min-width: 640px; }

.method { padding: 2px 16px 16px; }
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
.src-body { padding: 2px 16px 16px; }
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
.src-p a:hover {
  color: var(--accent);
  border-color: var(--accent-dim);
}
.src-p strong { color: var(--dim); }

/* ---------- 响应式（legacy 断点 680 / 560） ---------- */
@media (max-width: 680px) {
  .ctrl {
    padding: 12px 12px 10px;
    top: 8px;
  }
  .ctrl-rows { gap: 10px 0; }
  .ctrl-row {
    flex-wrap: wrap;
    width: 100%;
  }
  .ctrl-label {
    width: 100%;
    margin-bottom: 3px;
  }
}
@media (max-width: 820px) {
  /* legacy ≤820 断点：表头换窄栅格（padding 覆盖为 0 12px，与原页同表现） */
  .rk-head {
    grid-template-columns: 26px minmax(0, 1.25fr) minmax(0, 1fr) 42px 82px;
    gap: 7px;
    padding: 0 12px;
  }
  .rk-head .hide-m { display: none; }
}
@media (max-width: 560px) {
  .ctrl {
    padding: 11px 12px 9px;
    top: 8px;
  }
  .ctrl-rows { gap: 7px 18px; }
  .ctrl-row { gap: var(--sp-2); }
  .m-formula { white-space: normal; }
  .rank-meta {
    flex-direction: column;
    align-items: flex-start;
    gap: var(--sp-2);
  }
  .rank-sort { margin-left: 0; }
}
</style>
