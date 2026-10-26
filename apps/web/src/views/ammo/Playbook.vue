<script setup>
/* ============================================================
   Playbook — 倒卖手册（/ammo 页尾区块）
   ------------------------------------------------------------
   静态内容：实操经验（买什么/何时买、挂单
   定价技巧、版本窗口套利、卡邮件扩容）与本站信号口径串成一条
   「囤→卖」动线。机制与数值随版本变动，不在本组件里写死任何游戏内实时数值。
   ============================================================ */

/* 一天内的买/卖窗口（流量节奏共识；tone 对齐站点语义 buy=绿 sell=红） */
const WINDOWS = [
  { time: '02:00–05:00', tag: '扫货', tone: 'buy', note: '挂机党下线甩卖，全天低位（约低两成）' },
  { time: '07:00–09:00', tag: '囤货', tone: 'buy', note: '工作日早间黄金期：上班族未上线，卖压轻' },
  { time: '12:00–14:00', tag: '上架', tone: 'sell', note: '午休补弹潮，挂单可比凌晨高约 10%' },
  { time: '19:00–23:00', tag: '出货', tone: 'sell', note: '晚间高峰；周日晚 20–23 点是全周最佳抛售窗口' },
]

/* 四张卡：买 / 卖 / 版本窗口 / 卡邮件（warn=true 走 --warn 左边条） */
const CARDS = [
  {
    idx: '01', en: 'BUY', title: '买什么、去哪买', warn: false,
    items: [
      { lead: '流动性优先：', text: '4 级弹是多数对局的主力弹种、进出最快；5 级弹单价高但需求窄，适合大资金慢周转。' },
      { lead: '军需处倒挂：', text: '军需处每日限购（约凌晨 5 点刷新）兑换价低于交易行时先扫军需处；在交易行购买也会自动按军需处的更低档成交。' },
      { lead: '看信号进场：', text: '本站「买入」信号 = 现价处 7 天下 1/5 分位、已止跌企稳（离底 ≥3%、近 12 小时无新低、48 小时趋势转平向上）、且按近 3 天 75 分位挂卖税后仍 ≥10%，随信号给止损位；只倒自己打得出去的弹，价格不涨还能自用。' },
    ],
  },
  {
    idx: '02', en: 'SELL', title: '挂单定价，卖得快又不贱卖', warn: false,
    items: [
      { lead: '删位法（日常清仓）：', text: '把参考价末位删 1 位让面板出现新低价区，选从左数第 4 个价格块——当前仍能快速成交的最高价。' },
      { lead: '柱状图法（急用钱）：', text: '挑最短柱子的档位挂（挂单最少、成交最快）；参考减价幅度：配件 5–6 档、普通武器 3–4 档、基础材料 2–3 档。' },
      { lead: '分批抛：', text: '一次性挂太多会自己砸盘，多人同时抛售更会加速下跌；大仓位拆成几天、多档位出。' },
    ],
  },
  {
    idx: '03', en: 'WINDOW', title: '版本与赛季窗口（利润最厚）', warn: false,
    items: [
      { lead: '更新前 3–7 天囤货：', text: '新赛季/大版本前囤热门口径（新枪配套弹、5.56 等主流弹）；赛季末物价低迷同样是囤货窗口。' },
      { lead: '开更后 3 天内出货：', text: '全服补弹需求暴增，是主要抛售窗口（AP6.3 更新后涨至约 4.5 万/格）。' },
      { lead: '活动公告驱动：', text: '新玩法、夜战等活动公布即囤对应消耗品；研发部门新配方、特勤处制作活动会拉动特定材料价格。' },
    ],
  },
  {
    idx: '04', en: 'MAIL', title: '卡邮件：邮箱当临时仓库', warn: true,
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
      <span class="bht">PLAYBOOK</span><span class="bhline"></span>
      <span class="bhc">倒卖手册</span>
    </div>

    <p class="pb-lede">
      倒卖 = 低价囤消耗品 + 高位分批抛售。本站信号解决「哪种弹、什么价」，下面是
      验证过的「什么时间、怎么操作」——按 <b>时段 → 买 → 卖 → 窗口</b> 串成一条完整动线。
    </p>

    <!-- 一天内的买/卖节奏 -->
    <div class="pb-clock" role="list" aria-label="一天内的买卖时段">
      <div v-for="w in WINDOWS" :key="w.time" class="pw" role="listitem">
        <span class="pw-time">{{ w.time }}</span>
        <span class="pw-tag" :class="w.tone">{{ w.tag }}</span>
        <p class="pw-note">{{ w.note }}</p>
      </div>
    </div>

    <!-- 实操四卡 -->
    <div class="pb-grid">
      <article v-for="c in CARDS" :key="c.idx" class="pb-card" :class="{ warn: c.warn }">
        <header class="pbc-head">
          <span class="pbc-idx">{{ c.idx }} {{ c.en }}</span>
          <h4 class="pbc-title">{{ c.title }}</h4>
        </header>
        <ul>
          <li v-for="(it, i) in c.items" :key="i"><b>{{ it.lead }}</b>{{ it.text }}</li>
        </ul>
      </article>
    </div>

    <!-- 风险与红线 -->
    <div class="pb-risk">
      <span class="pb-risk-label">RISK · 风险与红线</span>
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
.pw-time { font-family: var(--mono); font-size: var(--fs-md); color: var(--tx-strong); font-variant-numeric: tabular-nums; }
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

/* ---------- 实操四卡：固定 4 张 → 桌面 2×2、窄屏 1 列 ---------- */
.pb-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: var(--sp-4); }
.pb-card {
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius-lg);
  padding: var(--sp-4) var(--sp-5);
  transition: border-color var(--t-med) var(--ease);
}
.pb-card:hover { border-color: var(--line-hover); }
/* 灰色地带卡（卡邮件）：--warn 左边条与卡头索引色提示谨慎 */
.pb-card.warn { border-left: 2px solid var(--warn); }
.pbc-head { display: flex; align-items: baseline; gap: 10px; margin-bottom: 10px; }
.pbc-idx { font-family: var(--mono); font-size: var(--fs-2xs); letter-spacing: .14em; color: var(--accent); white-space: nowrap; }
.pb-card.warn .pbc-idx { color: var(--warn); }
.pbc-title { font-size: var(--fs-md); font-weight: 700; color: var(--tx-strong); margin: 0; }
.pb-card ul { list-style: none; display: flex; flex-direction: column; gap: 8px; margin: 0; padding: 0; }
.pb-card li { font-size: var(--fs-sm); color: var(--dim); line-height: 1.8; padding-left: 14px; position: relative; }
.pb-card li::before { content: "◆"; position: absolute; left: 0; top: 6px; font-size: 7px; color: var(--accent-dim); }
.pb-card.warn li::before { color: var(--warn); }
.pb-card li b { color: var(--tx); font-weight: 600; }

/* ---------- 风险红线（全站唯一危险语义 --danger：左边条 + 8% 底，同 GuideBlocks） ---------- */
.pb-risk {
  margin-top: var(--sp-5);
  padding: 12px 16px;
  border-left: 2px solid var(--danger);
  background: rgba(217, 106, 89, .08);
  background: color-mix(in srgb, var(--danger) 8%, transparent);
  border-radius: 0 var(--radius) var(--radius) 0;
}
.pb-risk-label {
  display: block; font-family: var(--mono); font-size: var(--fs-micro);
  letter-spacing: .28em; color: var(--danger); margin-bottom: 8px;
}
.pb-risk ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.pb-risk li { font-size: var(--fs-sm); color: var(--dim); line-height: 1.8; padding-left: 14px; position: relative; }
.pb-risk li::before { content: "◆"; position: absolute; left: 0; top: 6px; font-size: 7px; color: var(--danger); opacity: .7; }
.pb-risk li b { color: var(--tx); font-weight: 600; }

/* ---------- 备注（正文外说明行） ---------- */
.pb-src { font-size: var(--fs-xs); color: var(--faint); line-height: 2; margin: var(--sp-4) 0 0; }

/* ---------- 响应式：时段条 4→2→1 列，卡组 2→1 列 ---------- */
@media (max-width: 900px) { .pb-clock { grid-template-columns: repeat(2, 1fr); } }
@media (max-width: 760px) { .pb-grid { grid-template-columns: 1fr; } }
@media (max-width: 480px) { .pb-clock { grid-template-columns: 1fr; } }

/* 微交互过渡的 reduced-motion 关闭 */
@media (prefers-reduced-motion: reduce) {
  .pb-card { transition: none; }
}
</style>
