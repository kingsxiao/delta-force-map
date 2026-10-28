<script setup>
// 场景最快卡（§6.3：ALL + 类别卡 ≤3 张，一行 4 卡），
// picks 由父组件 computed 产出（label / c=最优组合 / top=ALL 高亮 / scen="5 级头" 场景标注）。
import { CAL } from '../../data/ttk/calibers.js'
import { fmtMs } from './format.js'
import PenBadge from './PenBadge.vue'

const props = defineProps({
  picks: { type: Array, required: true },
  delay: { type: Number, default: 0 }, // 展示层扳机延迟（ms）：与排行行同口径等量平移
})

/* 毫秒主数字分层：fmtMs 输出 "342 ms"（0 值特例 "首发"，无单位），整串同渲染成 30px 时
   单位与数值同权、稀释读数。按首个空格拆成 [数值, 单位]——数值留 display 字阶，单位降档
   弱化（每卡唯一主数字立权）。不改 format.js（口径与 legacy 逐字符一致，展示层自行拆） */
function msParts(p) {
  const s = fmtMs(p.c.ttk + props.delay)
  const i = s.indexOf(' ')
  return i < 0 ? [s, ''] : [s.slice(0, i), s.slice(i + 1)]
}
</script>

<template>
  <!-- .champ 挂 --ri 供容器级级联错峰（§7.3）；picks 为空（搜索/筛选无结果）时整组收起不留空隙。
       用 display 折叠而非 v-if：useReveal 只在挂载时观察一次，v-if 卸载重挂的新节点
       不会再被观察、会卡在入场前的 opacity:0；display 变化 IO 会正常补触发。
       --champ-n = 实际卡数（≤4）：列数随卡数收紧，类别只选 1 类时仅 2 卡，固定 4 列右侧会整行空白 ~50% -->
  <div class="champs" :class="{ empty: !picks.length }" :style="{ '--champ-n': Math.min(picks.length, 4) }">
    <div v-for="(p, i) in picks" :key="p.label" class="champ" :class="{ top: p.top }" :style="{ '--ri': i }">
      <div class="champ-label">{{ p.label }}</div>
      <div class="champ-gun">{{ p.c.gun.zh }}</div>
      <div class="champ-sub">
        <PenBadge :p="p.c.am.pen" solid />
        <span>{{ CAL[p.c.gun.cal].label }} · {{ p.c.am.n }} · {{ p.c.btk }} 发<template v-if="p.scen"> · {{ p.scen }}</template></span>
      </div>
      <!-- 主数字 / 单位 / 副注三层：msParts 为纯函数，v-for 内双调用开销可忽略（≤4 卡）。
           主数字变化反馈（MOTION §3-E 单点关键数字，对齐 iOS hero 现价 numericText）：
           修正/筛选改变 TTK 时以数值+单位为 key 重建内层 span，Transition 只配 enter
           （旧值瞬时退场）单段 250ms 淡入上移——out-in 双段共 500ms 对「读数换了」太拖沓；
           appear 默认 false，首次挂载不播，避免与冠军卡 reveal-group 级联入场同向叠加 -->
      <div class="champ-ttk">
        <Transition name="num">
          <span :key="msParts(p)[0] + (msParts(p)[1] || '')" class="champ-num">{{ msParts(p)[0] }}<small v-if="msParts(p)[1]" class="champ-ms">{{ msParts(p)[1] }}</small></span>
        </Transition>
        <small>TTK · {{ p.c.gun.rpm }} RPM</small>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* 一行 ≤4 卡（§6.3：repeat(N) 治 auto-fit 末行参差）；列数 = 卡数（--champ-n，模板按 picks 注入，
   兜底 4），类别筛选少于 3 类时 2-3 卡各占等分、不再留整行空白；≤820 两列、≤680 单列；上距 12 促排行表进首屏 */
.champs {
  display: grid;
  grid-template-columns: repeat(var(--champ-n, 4), minmax(0, 1fr));
  gap: var(--sp-3);
  margin: var(--sp-3) 0 var(--sp-2);
}
.champs.empty { display: none; }
.champ {
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  background: var(--card);
  box-shadow: var(--edge-light);
  padding: 15px 17px 13px;
  position: relative;
  overflow: hidden;
}
.champ.top {
  border-color: var(--accent-dim);
  background: linear-gradient(135deg, var(--accent-bg), var(--card) 55%);
}
/* 卡片本身不可点击（无 hover 提亮）：场景最快卡是纯展示卡 */
.champ-label {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  /* .26em 对齐 mono kicker 族（base.css .bht / TierBoard .tb-title 同为 xs 档 mono 标签），
     卡内 kicker 与区块 kicker 跨区块同字距 */
  letter-spacing: .26em;
  color: var(--faint);
  margin-bottom: 9px;
}
.champ.top .champ-label { color: var(--accent); }
.champ-gun {
  font-size: var(--fs-lg);
  font-weight: 700;
  letter-spacing: .01em;
  color: var(--tx-strong);
}
.champ-sub {
  font-size: var(--fs-xs);
  color: var(--dim);
  margin-top: 3px;
  display: flex;
  align-items: center;
  gap: 7px;
  flex-wrap: wrap;
}
.champ-ttk {
  font-family: var(--mono);
  font-size: var(--fs-display);
  font-weight: 600;
  color: var(--accent);
  margin-top: 9px;
  letter-spacing: .02em;
  font-variant-numeric: tabular-nums;
  /* 数据大数走紧凑行高档（base.css 行高两档契约）：继承 body 1.7 会让 30px 主数字
    撑出 ~51px 行盒、数字上下空隙过大，主数字反而失焦 */
  line-height: var(--lh-tight);
}
.champ-ttk small {
  font-size: var(--fs-2xs);
  color: var(--faint);
  font-weight: 400;
  margin-left: 5px;
  letter-spacing: .08em;
}
/* 副注独立成行：原与 30px 主数字同基线横排成「342 ms TTK · 706 RPM」——大数旁挂
   11px 小注稀释主数字（第一眼决策数字应只剩 数值+单位），且 4 位数 TTK 叠加长副注时
   inline 流折行位置不稳。子选择器只命中直接子副注：champ-ms 在 Transition 渲染的
   span 内（孙代），仍是 inline、继续与数值同基线 */
.champ-ttk > small {
  display: block;
  margin-left: 0;
  margin-top: 3px; /* 与 .champ-sub 的卡内微距同值 */
}
/* 单位层（介于主数字与副注之间）：sm 字阶 + --dim，比 "TTK · RPM" 副注（2xs/faint）高半档——
   读序 数值 → 单位 → 口径注；特异性 (0,2,0) 压过上方 .champ-ttk small 的通用副注样式 */
.champ-ttk .champ-ms {
  font-size: var(--fs-sm);
  color: var(--dim);
  margin-left: 4px;
  margin-right: 2px;
  letter-spacing: .04em;
}
/* 主数字变化淡入（250ms 状态切换档，全局 swap 同取值但这里只要单段进场）：
   inline-block 让 translateY 生效（inline 元素 transform 无效）；无 leave 类 =
   旧值瞬时退场。位移 6px 与全局 .swap-enter-from 同值，语汇一致 */
.champ-num { display: inline-block; }
.num-enter-active {
  transition: opacity var(--t-panel) var(--ease), transform var(--t-panel) var(--ease);
}
.num-enter-from { opacity: 0; transform: translateY(6px); }
@media (max-width: 820px) {
  .champs { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  /* 奇数末卡满宽（§6.3 末行参差在断点下的复发）：681-820 两列区 picks=3（选 2 类别）
     时末行只剩一张半宽孤卡；末卡跨两列与上行齐边。>820 由 --champ-n 列数自适应无
     孤卡（本块不命中）；≤680 单列须恢复 auto——单列 grid 里 span 2 会撑出隐式第二列 */
  .champ:last-child:nth-child(odd) { grid-column: span 2; }
  .champ { padding: 13px 15px 11px; }
}
@media (max-width: 680px) {
  .champs { grid-template-columns: 1fr; }
  /* 与 820 块同选择器同特异性，靠源序在其后覆盖（见上块注释） */
  .champ:last-child:nth-child(odd) { grid-column: auto; }
}
/* RM 兜底：数字变化降级为瞬时替换（读数语义不依赖动效） */
@media (prefers-reduced-motion: reduce) {
  .num-enter-active { transition: none; }
  .num-enter-from { transform: none; }
}
</style>
