<script setup>
/* PositionLedger — 我的囤货台账（自 AmmoMarketView 抽出的自包含区块）
   ------------------------------------------------------------
   纯本地 localStorage 记录（usePositions 单例持久化，登录后由 useAccount
   做两端合并，见 /account 页），有持仓才渲染（根节点 v-if，删空 / 云端
   清空后整块卸载）。行情侧经 props 注入，组件不接触快照数据链：
     · items：当前快照弹种列表——行 join 现价/税率/挂目标价（弹名已不在
       快照〔下架 / 改名〕时 item=null，只展示记录本体）、录入表单的
       datalist 联想同源；
     · rules：快照顶层规则展示子集——超期提醒与徽章按 MAX_HOLD_H 下发值
       渲染（缺失退 v2 定稿值 168h），杜绝 UI 与规则参数漂移。
   现价闪变（diffPriceFlash 随本组件迁出）：items 换新快照后按弹名 diff
   新旧现价，「现价」格挂 up/down 色类、900ms 后摘（涨绿跌红、色过渡
   220ms 档）；全表 price-cell 的闪变（底色脉冲 + 箭头）仍在
   AmmoMarketView 自持一份，两处机制同源、互不共享。
   对外契约（defineExpose）：upsert = 台账唯一写入口（全表展开行「记入
   囤货」经父级调它）；rootEl = 区块根元素（父级记入后滚动定位用，
   暴露的 ref 经 proxyRefs 自动解包为元素本身）。 */
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { usePositions } from '../../composables/usePositions'
import { useAccount } from '../../composables/useAccount'
import { imgReady, hideImg } from '../../composables/imgReady'
import { fmt, pct, fmtSigned } from '../../utils/format.js'
import { picThumb } from '@shared/js/marketMeta.js'

const props = defineProps({
  /* 当前行情快照 items（market.items）：行 join 与录入联想的数据源 */
  items: { type: Array, default: () => [] },
  /* 快照顶层 rules 展示子集（analyze.mjs RULES）：MAX_HOLD_H 建议持有上限 */
  rules: { type: Object, default: () => ({}) },
})

const { positions, save: savePositions, upsert: upsertPosition } = usePositions()
const { user: accountUser } = useAccount() // 仅用于台账区块的云同步状态标（同步逻辑全在 useAccount 单例内）

const ruleNum = (k, dflt) => (Number.isFinite(props.rules[k]) ? props.rules[k] : dflt)

/* 持有时长只需「天」粒度：组件自挂 60s 分钟钟即可（页面级 nowTs 的轮询 /
   回前台校正不改变天数口径），卸载清理 */
const nowTs = ref(Date.now())
let clockTimer = null
onMounted(() => { clockTimer = setInterval(() => { nowTs.value = Date.now() }, 60 * 1000) })

/* 台账行 join 行情快照：弹名已不在当前快照（下架 / 改名）时 item=null，只展示记录本体。
   holdDays / overHold：持有时长与超期（> maxHoldH=168h=7 天建议持有上限）提醒，
   依据快照 rules.MAX_HOLD_H 下发值；breakEven：回本挂卖价 = 成本 ÷ (1−税率)，
   15% 税下成本之上要挂 +17.6% 才不亏（analyze.mjs 头注税负数学），用户最易漏算 */
const positionRows = computed(() =>
  positions.value.map((p) => {
    const item = props.items.find((i) => i.name === p.name) || null
    const netSell = item?.netSell ?? null // 挂目标价税后到手 / 发
    const netNow = item && item.current != null && Number.isFinite(item.taxRate)
      ? item.current * (1 - item.taxRate) : null // 现价直出税后 / 发
    const maxHoldH = ruleNum('MAX_HOLD_H', 168)
    const holdDays = Number.isFinite(p.at) && p.at > 0 ? Math.floor((nowTs.value - p.at) / 86400000) : null
    return {
      ...p,
      item,
      netSell,
      netNow,
      /* 到价浮盈（挂目标价口径）与现价浮盈（直出口径） */
      gainNet: netSell != null ? (netSell - p.cost) * p.qty : null,
      gainNow: netNow != null ? (netNow - p.cost) * p.qty : null,
      atTarget: !!(item && item.current != null && item.targetSell != null && item.current >= item.targetSell),
      holdDays,
      overHold: holdDays != null && holdDays * 24 > maxHoldH,
      breakEven: item && Number.isFinite(item.taxRate) && item.taxRate < 1 ? p.cost / (1 - item.taxRate) : null,
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
/* upsertPosition（台账唯一写入口）已上收 usePositions 单例：本组件行内编辑 /
   删除、添加表单与详情页「记入囤货」共用同一落库路径（字段清洗 + 记账时刻
   语义在 composable 一处） */
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
  const item = props.items.find((i) => i.name === name)
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

/* ---------- 价格闪变（随台账区块自 AmmoMarketView 迁出）：静默刷新换新
   items 后 diff 新旧现价，变化行的「现价」格挂 up/down 色类——涨绿跌红、
   色过渡 220ms 档（MOTION.md 微交互档位），900ms 后摘类；一次性读数反馈
   非循环动效，纯静态环境快照版本不变 → diff 天然为空，不会整列乱闪。
   RM 下色瞬变（无过渡）、摘类即还原 ---------- */
const priceFlash = reactive({})
let flashTimer = null
watch(
  () => props.items,
  (nextItems, prevItems) => diffPriceFlash(prevItems, nextItems),
)
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

const posSecRef = ref(null)
/* 对外契约：父级（AmmoMarketView）经模板 ref 调用——upsert 承接全表展开行
   「记入囤货」；rootEl 供记入后 scrollIntoView 滚动定位 */
defineExpose({ upsert: upsertPosition, rootEl: posSecRef })

onUnmounted(() => {
  clearInterval(clockTimer)
  if (posDelTimer) clearTimeout(posDelTimer)
  if (flashTimer) clearTimeout(flashTimer)
})
</script>

<template>
  <!-- 我的囤货台账：纯本地 localStorage（不上传不同步），有持仓才显示。
       浮盈按「挂目标价税后到手」口径；现价已达挂卖价的行高亮可出；
       入场渐显（.reveal）由页面级 observeRoot 统一挂 .in（区块随首条持仓
       从无到有时亦由父级补观察） -->
  <section v-if="positions.length" ref="posSecRef" class="block reveal pos-block" aria-label="我的囤货台账">
    <div class="block-h">
      <span class="bht">我的囤货</span><span class="bhline"></span>
      <span class="bhc">{{ positions.length }} 条 · 本机记录{{ accountUser ? ' · 已随账号云同步' : '' }}</span>
    </div>
    <div class="pos-sum">
      <span class="ps-item">总投入 <b>{{ fmt(posTotals.invest) }}</b></span>
      <span class="ps-item">到价浮盈（挂目标价）<b :class="posTotals.gainNet >= 0 ? 'pos-pos' : 'pos-neg'">{{ fmtSigned(posTotals.gainNet) }}</b><template v-if="posTotals.pct != null">（{{ pct(posTotals.pct) }}）</template></span>
      <span class="ps-item">现价直出浮盈 <b :class="posTotals.gainNow >= 0 ? 'pos-pos' : 'pos-neg'">{{ fmtSigned(posTotals.gainNow) }}</b></span>
    </div>
    <!-- 台账行增删补位重排（MOTION.md §3-B 小列表 ≤20 行〔补〕）：flip move
         补位 + 淡入淡出；.pos-list 的 position: relative 作离场行脱流的锚点 -->
    <TransitionGroup name="flip" tag="ul" class="pos-list">
      <li v-for="r in positionRows" :key="r.name" :class="{ hit: r.atTarget }">
        <span class="pos-name">
          <span class="a-icw" aria-hidden="true">
            <img
              v-if="r.item?.pic" class="a-ic"
              :src="picThumb(r.item.pic, 96)" alt=""
              width="26" height="18" loading="lazy" decoding="async"
              @load="imgReady" @error="hideImg"
            >
          </span>
          <span class="pos-title">{{ r.name }}</span>
          <span v-if="r.atTarget" class="pos-badge">已到挂卖价</span>
          <span v-else-if="r.overHold" class="pos-badge over" :title="`已持有 ${r.holdDays} 天，超过建议上限 ${Math.round(ruleNum('MAX_HOLD_H', 168) / 24)} 天（超时未达目标价，纪律是离场）`">超期 {{ r.holdDays }} 天</span>
          <span v-else-if="r.holdDays != null" class="pos-badge hold" :title="`记账于 ${new Date(r.at).toLocaleDateString('zh-CN')}，持有 ${r.holdDays} 天（建议 ≤ ${Math.round(ruleNum('MAX_HOLD_H', 168) / 24)} 天）`">持 {{ r.holdDays }} 天</span>
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
          <!-- 闪变类挂「现价」值（diffPriceFlash 挂类、900ms 摘类）：静默刷新后
               就地读出这一格刚涨还是刚跌，同全表 price-cell 口径 -->
          <span class="mono pos-v" :class="priceFlash[r.name]">{{ r.item ? fmt(r.item.current) : '—' }}</span>
        </span>
        <span class="pos-cell" :title="r.breakEven != null ? `挂卖 ≥ 此价，税后到手才不亏：成本 ${fmt(r.cost)} ÷ (1−税率 ${(r.item?.taxRate * 100).toFixed(0)}%)` : ''">
          <span class="pos-k">回本挂卖</span>
          <span class="mono pos-v">{{ r.breakEven != null ? fmt(r.breakEven) : '—' }}</span>
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
    </TransitionGroup>
    <form class="pos-add" @submit.prevent="addPosition">
      <input
        v-model.trim="posForm.name" class="pos-in pos-add-name" list="pos-name-list"
        type="text" placeholder="弹名（可联想，如 M855A1）" aria-label="弹名"
      >
      <datalist id="pos-name-list">
        <option v-for="i in items" :key="i.name" :value="i.name" />
      </datalist>
      <input v-model.number="posForm.qty" class="pos-in" type="number" min="1" placeholder="数量" aria-label="数量" required>
      <input v-model.number="posForm.cost" class="pos-in pos-add-cost" type="number" min="1" step="any" placeholder="成本/发（空=现价）" aria-label="成本单价，留空按现价记入">
      <button class="pos-add-btn" type="submit">{{ positions.some((p) => p.name === posForm.name) ? '更新' : '记入囤货' }}</button>
      <p v-if="posFormErr" class="pos-err" role="alert">{{ posFormErr }}</p>
    </form>
  </section>
</template>

<style scoped>
/* ---------- 我的囤货台账（纯本地记录）：汇总条 + 行内可编辑列表 + 录入表单 ---------- */
.pos-sum {
  display: flex; flex-wrap: wrap; gap: 6px 26px;
  padding: 10px 14px; margin-bottom: var(--sp-3);
  background: linear-gradient(90deg, rgba(45, 212, 191, .08), rgba(45, 212, 191, .01) 70%);
  background: linear-gradient(90deg, color-mix(in srgb, var(--accent) 8%, transparent), color-mix(in srgb, var(--accent) 1%, transparent) 70%);
  border-radius: var(--radius-sm);
  font-size: var(--fs-xs); color: var(--dim);
}
.pos-sum b {
  font-family: var(--mono); color: var(--tx-strong);
  font-variant-numeric: tabular-nums;
}
.pos-pos { color: var(--ok); }
.pos-neg { color: var(--danger); }

/* position: relative：flip 离场行脱流（.flip-leave-active 的 absolute）的定位锚点 */
.pos-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; position: relative; }
/* 脱流后 flex 项宽度塌成 shrink-to-fit：补满宽让淡出行与原位重合，
   补位动画读作「这行消失、其余上移」而非「缩一下再消失」 */
.pos-list .flip-leave-active { width: 100%; }
.pos-list li {
  display: flex; align-items: center; flex-wrap: wrap; gap: 6px 16px;
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius);
  padding: 8px 12px;
}
/* 现价已达挂卖价（targetSell）：accent 边框 + 微底，提示可出 */
.pos-list li.hit {
  border-color: var(--accent-dim);
  background: var(--accent-bg);
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
/* 持有时长徽章：常态中性（dim），超期（> 建议持有上限 7 天）转 danger 实感 */
.pos-badge.hold {
  color: var(--dim); border-color: var(--line2); background: none;
}
.pos-badge.over {
  color: var(--danger);
  border-color: rgba(217, 106, 89, .45); background: rgba(217, 106, 89, .12);
  border-color: color-mix(in srgb, var(--danger) 45%, transparent);
  background: color-mix(in srgb, var(--danger) 12%, transparent);
}
/* 行内弹药图标：官方 pic 缩略坐在游戏同款品级底色方框里（取值与全表
   .a-icw 同款、两处各自 scoped；台账行不下发 --gd，退 faint 中性框——
   台账行的身份锚点是弹名文字，品级信息在全表与信号卡承接）；
   .ld 由 imgReady 挂上（加载完成染底），口径见 motion.css「图片占位」段 */
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
/* 囤货录入即时校验（F 项，思路库·:has 表单校验 → 取 :user-invalid 落地：
   语义更准——只对「用户改过且非法」的字段给反馈，不打扰未动过的初值）：
   红边提前于提交给反馈、零 JS；老浏览器回退现有提交时 JS 校验文案，功能完整 */
@supports selector(:user-invalid) {
  .pos-add .pos-in:user-invalid { border-color: var(--danger); }
}
/* number 输入的步进箭头占宽且挤不进窄列：隐藏（键盘直输 / 滚轮仍可调） */
.pos-in::-webkit-outer-spin-button, .pos-in::-webkit-inner-spin-button { -webkit-appearance: none; margin: 0; }
.pos-in[type="number"] { -moz-appearance: textfield; appearance: textfield; }
.pos-cell { display: inline-flex; flex-direction: column; gap: 2px; }
.pos-v { font-size: var(--fs-xs); color: var(--tx); font-variant-numeric: tabular-nums; }
/* 现价闪变：涨绿跌红（与全表 price-cell / SellCard 口径一致），类挂 0.9s 后摘、
   色过渡 220ms 渐入渐出（diffPriceFlash 迁入本组件，详见 script 注释） */
.pos-v { transition: color var(--t-slow) var(--ease); }
.pos-v.up { color: var(--ok); }
.pos-v.down { color: var(--danger); }
.pos-del {
  flex: none; margin-left: auto;
  background: none; border: 1px solid transparent; border-radius: var(--radius-sm);
  color: var(--faint); font-size: var(--fs-2xs); padding: 3px 8px; cursor: pointer;
  /* background-color 也入过渡：二次确认待定态（.arm）的 danger 微底渐入而非硬切 */
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease), background-color var(--t-fast) var(--ease);
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
  .pos-in { font-size: var(--fs-lg); }
  /* 添加表单的成本框单独放宽：16px 防缩放字号下 placeholder「成本/发（空=现价）」
     需 ~147px，96px 固定宽会截成「成本/发（空=现…」，丢掉「留空按现价记入」提示 */
  .pos-add-cost { width: 168px; }
}

.pos-add { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin-top: var(--sp-3); }
.pos-add .pos-in { background: var(--card); }
.pos-add-name { flex: 1 1 170px; width: auto; }
.pos-err { width: 100%; margin: 0; color: var(--warn); font-size: var(--fs-xs); }

/* 录入按钮（主按钮 .retry 家族同款：--accent-bg 底 + --accent-dim 边，hover 提底
   --accent-soft，按下 scale(.98)，禁用降透明；取值与 AmmoMarketView .retry 一致） */
.pos-add-btn {
  background: var(--accent-bg); color: var(--accent); border: 1px solid var(--accent-dim);
  border-radius: var(--radius); padding: 6px 18px; cursor: pointer; font-size: var(--fs-sm);
  transition: background-color var(--t-med) var(--ease), transform var(--t-fast) var(--ease);
}
.pos-add-btn:hover { background: var(--accent-soft); }
.pos-add-btn:active { transform: scale(.98); }
.pos-add-btn:disabled { opacity: .45; cursor: default; }

/* ---------- 触控垫层（通用原则·命中区 ≥44px）：✕ 删除钮视觉尺寸小，伪元素
   四周扩垫补足命中（四周空旷，-13px 全向扩不叠邻区；同页面 .star 手法） ---------- */
@media (pointer: coarse) {
  .pos-del { position: relative; }
  .pos-del::before { content: ""; position: absolute; inset: -13px; }
}

/* 本组件微交互过渡的 reduced-motion 关闭（.flip 离场补位等全局类由 motion.css
   文件尾统一兜底）；闪变色瞬变（类停留 0.9s 仍是有效的方向读数，非动效噪声） */
@media (prefers-reduced-motion: reduce) {
  .pos-add-btn, .pos-in, .pos-del, .pos-v { transition: none; }
  .pos-add-btn:active { transform: none; }
}
</style>
