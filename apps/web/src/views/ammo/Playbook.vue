<script setup>
/* ============================================================
   Playbook — 倒卖手册（/ammo 页尾区块）
   ------------------------------------------------------------
   静态内容：实操经验（买什么/何时买、挂单
   定价技巧、版本窗口套利、卡邮件扩容）与本站信号口径串成一条
   「囤→卖」动线。机制与数值随版本变动，不在本组件里写死任何游戏内实时数值。
   两个实时触点（均为可选 prop，缺失时保持纯静态）：
     · nowHour（数据时刻，父页传入）：点亮时段条里「当前所处窗」
     · season（快照顶层赛季日历）：窗口卡上方的倒计时与阶段点亮
   ============================================================ */
import { computed } from 'vue'
import { seasonPhase } from '@shared/js/marketMeta.js'

const props = defineProps({
  /** 数据时刻（快照曲线末点的墙钟小时，0-23；null = 无判读，时段条保持纯静态） */
  nowHour: { type: Number, default: null },
  /** 赛季日历（快照顶层 season：{name, start, end}；null = 无数据，窗口卡保持纯静态） */
  season: { type: Object, default: null },
})

/* 一天内的买/卖窗口（流量节奏共识；tone 对齐站点语义 buy=绿 sell=红）。
   from/to 为窗口起止小时（左闭右开），供 nowHour 点亮「当前」用 */
const WINDOWS = [
  { time: '02:00–05:00', from: 2, to: 5, tag: '扫货', tone: 'buy', note: '挂机党下线甩卖，全天低位（约低两成）' },
  { time: '07:00–09:00', from: 7, to: 9, tag: '囤货', tone: 'buy', note: '工作日早间黄金期：上班族未上线，卖压轻' },
  { time: '12:00–14:00', from: 12, to: 14, tag: '上架', tone: 'sell', note: '午休补弹潮，挂单可比凌晨高约 10%' },
  { time: '19:00–23:00', from: 19, to: 23, tag: '出货', tone: 'sell', note: '晚间高峰；周日晚 20–23 点是全周最佳抛售窗口' },
]
/* 当前是否落在该窗口（左闭右开，如 19:00–23:00 覆盖 19~22 点整段） */
const inWindow = (w) => props.nowHour != null && props.nowHour >= w.from && props.nowHour < w.to

/* 赛季阶段（快照顶层 season 驱动，纯函数在 @shared/js/marketMeta.js）：
   倒计时 + 当前所处窗口（fresh 开更出货 / hoard T−7~T−3 囤货 / late 赛季末） */
const seasonInfo = computed(() => {
  const p = seasonPhase(props.season)
  if (!p) return null
  const days = p.daysLeft > 0 ? Math.floor(p.daysLeft) : null
  return { ...p, days, title: props.season?.name || '' }
})

/* 四张卡：买 / 卖 / 版本窗口 / 卡邮件（warn=true 走 --warn 左边条） */
const CARDS = [
  {
    idx: '01', tag: '买', title: '买什么、去哪买', warn: false,
    items: [
      { lead: '流动性优先：', text: '4 级弹是多数对局的主力弹种、进出最快；5 级弹单价高但需求窄，适合大资金慢周转。' },
      { lead: '军需处倒挂：', text: '军需处每日限购（约凌晨 5 点刷新）用材料换弹，材料折算价低于交易行时先扫军需处；可兑换弹种在全表弹名旁有「军」标，展开可看折算价与所需材料。' },
      { lead: '看信号进场：', text: '本站「买入」信号 = 现价处 7 天下 1/5 分位、已止跌企稳（离底 ≥3%、近 12 小时无新低、48 小时趋势转平向上）、且按近 3 天 75 分位挂卖税后仍 ≥10%，随信号给止损位；只倒自己打得出去的弹，价格不涨还能自用。' },
    ],
  },
  {
    idx: '02', tag: '卖', title: '挂单定价，卖得快又不贱卖', warn: false,
    items: [
      { lead: '删位法（日常清仓）：', text: '把参考价末位删 1 位让面板出现新低价区，选从左数第 4 个价格块——当前仍能快速成交的最高价。' },
      { lead: '柱状图法（急用钱）：', text: '挑最短柱子的档位挂（挂单最少、成交最快）；参考减价幅度：配件 5–6 档、武器 3–4 档、材料 2–3 档。（挂单档位分布没有第三方数据源，需在游戏内查看）' },
      { lead: '分批抛：', text: '一次性挂太多会自己砸盘，多人同时抛售更会加速下跌；大仓位拆成几天、多档位出。' },
    ],
  },
  {
    idx: '03', tag: '窗口', title: '版本与赛季窗口（利润最厚）', warn: false,
    items: [
      { lead: '更新前 3–7 天囤货：', text: '新赛季/大版本前囤热门口径（新枪配套弹、5.56 等主流弹）；赛季末物价低迷同样是囤货窗口。赛季倒计时见下方横幅（由赛季日历数据驱动）。' },
      { lead: '开更后 3 天内出货：', text: '全服补弹需求暴增，是主要抛售窗口（AP6.3 更新后涨至约 4.5 万/格）。' },
      { lead: '活动公告驱动：', text: '新玩法、夜战等活动公布即囤对应消耗品；研发部门新配方、特勤处制作活动会拉动特定材料价格。' },
    ],
  },
  {
    idx: '04', tag: '邮件', title: '卡邮件：邮箱当临时仓库', warn: true,
    items: [
      { lead: '机制：', text: '邮件附件可暂存物资当扩容仓库用；邮件物资 30 天有效，逾期消失。' },
      { lead: '全装包法（半官方机制）：', text: '先用占格杂物把仓库塞满，再打开全装包并勾选「打开后立即装备」——空间冲突后，原身上装备整套转为补偿邮件。' },
      { lead: '断网重连类卡法属漏洞利用：', text: '官方可能判违规、有封号风险，高价值物资也可能卡失败，谨慎使用。' },
      { lead: '对倒卖的意义：', text: '囤子弹最卡的正是仓库格子；邮件能顶 30 天，恰好盖住一轮「囤→卖」，记得回来领。' },
    ],
  },
]

const RISKS = [
  { lead: '倒卖本身合规：', text: '交易行是官方自由市场，低买高卖属正常玩法；但卡邮件漏洞法、多开搬砖属灰色操作，风险自负。' },
  { lead: '变现红线：', text: '哈夫币不能直接交易；私下交易骗子多，比例明显偏离行情的基本是骗局；官方市集安全但手续费约 30%，出手前先算净所得。' },
  { lead: '行情会跌：', text: '囤货可能不涨反跌，多人同时抛售会加速下跌；历史分位不代表未来走势，本站信号同理。' },
  { lead: '费率以游戏内为准：', text: '挂单 12 / 24 小时费率不同、成交后才扣除；本站利润按实测税率（约 15%）逐弹计算。' },
]
</script>

<template>
  <section class="block reveal">
    <div class="block-h">
      <span class="bht">倒卖手册</span><span class="bhline"></span>
      <span class="bhc">囤 → 卖 实操动线</span>
    </div>

    <p class="pb-lede">
      倒卖 = 低价囤消耗品 + 高位分批抛售。本站信号解决「哪种弹、什么价」，下面是
      验证过的「什么时间、怎么操作」——按 <b>时段 → 买 → 卖 → 窗口</b> 串成一条完整动线。
    </p>

    <!-- 赛季窗口横幅（season 数据驱动，无数据时整块不渲染）：
         倒计时 + 当前阶段（fresh 出货 / hoard 囤货 / late 赛季末 / mid 常规），
         判定同 Playbook 03 卡的静态经验口径（seasonPhase 纯函数） -->
    <p v-if="seasonInfo" class="pb-season" :class="seasonInfo.tone" role="status">
      <span class="ps-name">{{ seasonInfo.title }}</span>
      <template v-if="seasonInfo.days != null"><span class="ps-left">距赛季结束 <b>{{ seasonInfo.days }}</b> 天</span></template>
      <template v-else><span class="ps-left">赛季已到点</span></template>
      <b class="ps-phase" :class="seasonInfo.tone">{{ seasonInfo.label }}</b>
    </p>

    <!-- 一天内的买/卖节奏。nowHour 命中窗口时该卡点亮 + 「当前」徽标——把正上方
         MarketClock 的实时判读与这里的共识时段互相印证（两处口径同为数据时刻，
         非设备本地时间）；不在任何窗内的时刻四卡保持纯静态，不硬凑 -->
    <div class="pb-clock" role="list" aria-label="一天内的买卖时段">
      <div v-for="w in WINDOWS" :key="w.time" class="pw" :class="{ now: inWindow(w) }" role="listitem">
        <span class="pw-time">{{ w.time }}<i v-if="inWindow(w)" class="pw-now" title="按行情数据时刻（快照末点）判定">当前</i></span>
        <span class="pw-tag" :class="w.tone">{{ w.tag }}</span>
        <p class="pw-note">{{ w.note }}</p>
      </div>
    </div>

    <!-- 实操四卡。卡 03 在 fresh/hoard/late 阶段点亮（accent 边条 + 「当前窗口」
         徽标），mid/无数据保持纯静态——赛季横幅给读数、这里给行为卡，同源互证 -->
    <div class="pb-grid">
      <article v-for="c in CARDS" :key="c.idx" class="pb-card" :class="{ warn: c.warn, live: c.idx === '03' && seasonInfo && seasonInfo.phase !== 'mid' }">
        <header class="pbc-head">
          <span class="pbc-idx">{{ c.idx }} {{ c.tag }}<i v-if="c.idx === '03' && seasonInfo && seasonInfo.phase !== 'mid'" class="pbc-live">赛季窗口进行中</i></span>
          <h4 class="pbc-title">{{ c.title }}</h4>
        </header>
        <ul>
          <li v-for="(it, i) in c.items" :key="i"><b>{{ it.lead }}</b>{{ it.text }}</li>
        </ul>
      </article>
    </div>

    <!-- 风险与红线 -->
    <div class="pb-risk">
      <span class="pb-risk-label">风险与红线</span>
      <ul>
        <li v-for="(r, i) in RISKS" :key="i"><b>{{ r.lead }}</b>{{ r.text }}</li>
      </ul>
    </div>

    <p class="pb-src">
      机制与数值随版本变动，以游戏内实际为准。
    </p>
  </section>
</template>

<style scoped>
/* ---------- 导语 ---------- */
.pb-lede { color: var(--dim); font-size: var(--fs-md); line-height: 1.9; max-width: 76ch; margin: 0 0 var(--sp-5); }
.pb-lede b { color: var(--tx-strong); }

/* ---------- 赛季窗口横幅（season 数据驱动）：名称 + 倒计时 + 阶段；
   阶段色对齐全站语义（buy 绿 / sell 红 / warn 黄 / dim 灰） ---------- */
.pb-season {
  display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px 14px;
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius);
  padding: 10px 14px; margin: 0 0 var(--sp-4);
  font-size: var(--fs-sm); color: var(--dim);
}
.ps-name { font-weight: 700; color: var(--tx-strong); }
.ps-left b { font-family: var(--mono); color: var(--tx-strong); font-variant-numeric: tabular-nums; }
.ps-phase { font-size: var(--fs-xs); }
.ps-phase.buy { color: var(--ok); }
.ps-phase.sell { color: var(--danger); }
.ps-phase.warn { color: var(--warn); }
.ps-phase.dim { color: var(--faint); }

/* ---------- 时段条：绿=买侧窗口，红=卖侧窗口（对齐全站信号语义色）。
   固定 4 格内容 → 桌面 4 列、窄屏 2 列、手机 1 列，不留给 auto-fit 空轨道 ---------- */
.pb-clock {
  display: grid; grid-template-columns: repeat(4, 1fr);
  gap: var(--sp-3); margin-bottom: var(--sp-5);
}
.pw {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius);
  padding: 12px 14px;
}
/* 当前所处窗：accent 边框 + 微底点亮（语汇同台账 hit 行 / 搜索 armed 态），
   纯状态无动效——点亮本身就是回声，快照推进时随数据时刻换卡片 */
.pw.now {
  border-color: var(--accent-dim);
  background: var(--accent-bg);
}
.pw-time { font-family: var(--mono); font-size: var(--fs-md); color: var(--tx-strong); font-variant-numeric: tabular-nums; }
/* 「当前」徽标：跟随时段文字排（不与右侧语义 tag 抢角），accent 是唯一强调色 */
.pw-now {
  font-style: normal;
  margin-left: 8px;
  font-family: var(--mono); font-size: var(--fs-2xs); letter-spacing: .1em;
  color: var(--accent);
  border: 1px solid var(--accent-dim); background: var(--accent-bg);
  border-radius: var(--radius-pill); padding: 1px 8px;
  vertical-align: 2px;
}
.pw-tag {
  float: right;
  font-family: var(--mono); font-size: var(--fs-2xs); letter-spacing: .1em;
  padding: 1px 9px; border-radius: var(--radius-pill); border: 1px solid var(--line);
}
/* 语义派生色统一 color-mix（真值 rgba 兜底，写法同 ttk PenMatrix） */
.pw-tag.buy {
  color: var(--ok);
  border-color: rgba(133, 181, 120, .4); background: rgba(133, 181, 120, .1);
  border-color: color-mix(in srgb, var(--ok) 40%, transparent);
  background: color-mix(in srgb, var(--ok) 10%, transparent);
}
.pw-tag.sell {
  color: var(--danger);
  border-color: rgba(217, 106, 89, .4); background: rgba(217, 106, 89, .1);
  border-color: color-mix(in srgb, var(--danger) 40%, transparent);
  background: color-mix(in srgb, var(--danger) 10%, transparent);
}
.pw-note { font-size: var(--fs-xs); color: var(--faint); line-height: 1.7; margin: 6px 0 0; }

/* ---------- 实操四卡：固定 4 张 → 桌面 2×2、窄屏 1 列。刻意不做 hover 提亮：
   卡片是静态阅读内容不可点，hover 反馈是「可点」的错误暗示（MOTION.md 原则 3，
   删掉无意义动效也是优化；对照：买入信号区的 SignalCard 可点才有 hover 上浮） ---------- */
.pb-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: var(--sp-4); }
.pb-card {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-lg);
  padding: var(--sp-4) var(--sp-5);
}
/* 灰色地带卡（卡邮件）：warn 微底与卡头索引色提示谨慎 */
.pb-card.warn {
  background: rgba(227, 178, 94, .05);
  background: color-mix(in srgb, var(--warn) 5%, transparent);
}
/* 赛季窗口进行中的卡 03：微底点亮（语汇同时段条 now 态） */
.pb-card.live { background: var(--accent-bg); }
.pbc-live {
  font-style: normal; font-family: var(--mono); font-size: var(--fs-micro);
  color: var(--accent); border: 1px solid var(--accent-dim); border-radius: var(--radius-pill);
  padding: 1px 8px; margin-left: 8px; vertical-align: 1px;
}
/* flex-wrap：681–820px 视口下双列卡宽 ~300px，「编号徽章（含赛季窗口 chip）+
   标题」一行放不下——标题被挤成窄列逐字竖排（CJK 最小内容宽 = 单字）。允许
   徽章行与标题各占一行，标题拿到整行宽正常折行 */
.pbc-head { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 10px; margin-bottom: 10px; }
.pbc-idx { font-family: var(--mono); font-size: var(--fs-2xs); letter-spacing: .14em; color: var(--accent); white-space: nowrap; }
.pb-card.warn .pbc-idx { color: var(--warn); }
.pbc-title { font-size: var(--fs-md); font-weight: 700; color: var(--tx-strong); margin: 0; }
.pb-card ul { list-style: none; display: flex; flex-direction: column; gap: 8px; margin: 0; padding: 0; }
.pb-card li { font-size: var(--fs-sm); color: var(--dim); line-height: 1.8; padding-left: 14px; position: relative; }
.pb-card li::before { content: "◆"; position: absolute; left: 0; top: 6px; font-size: 7px; color: var(--accent-dim); }
.pb-card.warn li::before { color: var(--warn); }
.pb-card li b { color: var(--tx); font-weight: 600; }

/* ---------- 风险红线（全站唯一危险语义 --danger：danger 边线 + 8% 底） ---------- */
.pb-risk {
  margin-top: var(--sp-5);
  padding: 12px 16px;
  border: 1px solid rgba(217, 106, 89, .35);
  border: 1px solid color-mix(in srgb, var(--danger) 35%, transparent);
  background: rgba(217, 106, 89, .08);
  background: color-mix(in srgb, var(--danger) 8%, transparent);
  border-radius: var(--radius-sm);
}
.pb-risk-label {
  display: block; font-family: var(--mono); font-size: var(--fs-micro);
  letter-spacing: .28em; color: var(--danger); margin-bottom: 8px;
}
.pb-risk ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.pb-risk li { font-size: var(--fs-sm); color: var(--dim); line-height: 1.8; padding-left: 14px; position: relative; }
.pb-risk li::before { content: "◆"; position: absolute; left: 0; top: 6px; font-size: 7px; color: var(--danger); opacity: .7; }
.pb-risk li b { color: var(--tx); font-weight: 600; }

/* ---------- 备注（正文外说明行）：与上方 MarketClock .mc-foot 同为区块末尾的
   口径/免责行——同层级同字号同行距同上距（fs-xs / faint / lh1.8 / sp-3） ---------- */
.pb-src { font-size: var(--fs-xs); color: var(--faint); line-height: 1.8; margin: var(--sp-3) 0 0; }

/* ---------- 响应式：断点对齐全站约定（--bp-pad 820 / --bp-mobile 680，base.css 头注；
   原 900/760 为 ad-hoc 值）：时段条 4→2→1 列，卡组 2→1 列 ---------- */
@media (max-width: 820px) { .pb-clock { grid-template-columns: repeat(2, 1fr); } }
@media (max-width: 680px) { .pb-grid { grid-template-columns: 1fr; } }
@media (max-width: 480px) { .pb-clock { grid-template-columns: 1fr; } }
</style>
