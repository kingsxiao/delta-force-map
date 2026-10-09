<script setup>
// 排行单行 + 逐发模拟详情（legacy renderRank 行装配 L720-812 的组件化）：
// - 行类目 top1/top2/top3/slow、TTK 条宽 Math.max(4, Math.min(100, best/ttk*100)) 均按原口径；
// - 详情懒加载：首次展开才计算该枪全弹药对比（open=false 时 computed 返回 null，不产生开销）；
// - 详情列表 = 当前筛选下该枪全部组合按 TTK 升序（legacy L772-773 同口径），
//   与点击行 TTK 相同的卡标记 best（legacy L775）。
import { computed } from 'vue'
import { CAL } from '../../data/ttk/calibers.js'
import { fmtMs, fmtDmg, metaText, extraText, scenLabel, partDmg, PART_CHAR } from './format.js'
import PenBadge from './PenBadge.vue'

const props = defineProps({
  c: { type: Object, required: true },      // combo 结果（含 gun/am/btk/broke/pass/flesh/noArmorBtk/ttk/part/armor）
  rank: { type: Number, required: true },
  best: { type: Number, required: true },   // 当前列表最快 TTK（条宽基准）
  open: { type: Boolean, default: false },
  combos: { type: Array, required: true },  // 当前筛选下全部组合（详情数据源）
  showScen: { type: Boolean, default: false }, // 多场景时在副行标注归属（"5级头"）
})

defineEmits(['toggle'])

const rowClass = computed(() => ({
  top1: props.rank === 1,
  top2: props.rank === 2,
  top3: props.rank === 3,
  /* best=0（栓狙无甲爆头 btk=1 → ttk=0）时全列表不判慢行（legacy L828 同守卫） */
  slow: props.best > 0 && props.c.ttk > props.best * 2.2,
  open: props.open,
}))

/* best 或 ttk 为 0 时条画满（legacy L860 同守卫，防 0/0 NaN 宽度） */
const barWidth = computed(() =>
  (props.best <= 0 || props.c.ttk <= 0)
    ? '100%'
    : Math.max(4, Math.min(100, props.best / props.c.ttk * 100)) + '%')

const detail = computed(() => {
  if (!props.open) return null
  // 详情限定在点击行同一场景（部位 × 护甲），跨场景数值混排会失去对比意义
  const list = props.combos
    .filter((x) => x.gun === props.c.gun && x.part === props.c.part && x.armor === props.c.armor)
    .sort((a, b) => a.ttk - b.ttk)
  const g = props.c.gun
  const bits = []
  if (g.note) bits.push(g.note)
  if (g.conflict) bits.push('数值存在来源冲突：' + g.conflict)
  if (g.est) bits.push('数值置信度较低')
  if (g.belly != null) bits.push('该枪胸腹同伤（腹部 ×' + g.belly + '）')
  return {
    list: list.map((x) => ({
      x,
      w: Math.max(4, Math.min(100, list[0].ttk / x.ttk * 100)) + '%',
    })),
    bits,
  }
})
</script>

<template>
  <div class="rk-row-wrap" :class="{ open }">
    <button
      type="button"
      class="rk-row"
      :class="rowClass"
      :aria-expanded="String(open)"
      @click="$emit('toggle')"
    >
      <span class="rk-num">{{ String(rank).padStart(2, '0') }}</span>
      <span class="rk-gun">
        <span class="n">{{ c.gun.zh }}</span>
        <span class="s">
          <em>{{ CAL[c.gun.cal].label }}</em> · {{ c.gun.rpm }} RPM · 面板 {{ c.gun.dmg }}/{{ c.gun.admg }}<template v-if="c.gun.burst"> · 三连发</template><template v-if="showScen"> · <b class="scen">{{ scenLabel(c) }}</b></template>
        </span>
      </span>
      <span class="rk-ammo">
        <PenBadge :p="c.am.pen" />
        <span class="an">{{ c.am.n }}</span>
      </span>
      <span class="rk-cell num hide-m">{{ c.gun.rpm }}</span>
      <span class="rk-cell num hide-m">{{ fmtDmg(c.flesh) }}</span>
      <span class="rk-cell num strong">{{ c.btk }} 发</span>
      <span class="rk-ta">
        <span class="rk-bar"><i :style="{ width: barWidth }"></i></span>
        <span class="rk-ttv">{{ fmtMs(c.ttk) }}</span>
      </span>
      <svg class="caret" viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">
        <path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>

    <div class="rk-detail" :class="{ open }">
      <div class="rk-detail-in">
        <div v-if="detail" class="dwrap">
          <!-- 枪械头带：渲染图 + 名牌 + 枪械备注，横向吃满一行 -->
          <header class="dband">
            <img
              v-if="c.gun.img"
              class="dpic"
              :src="'/guns/' + c.gun.img + '.webp'"
              :alt="c.gun.zh + ' 官方渲染图'"
              loading="lazy"
              decoding="async"
            >
            <svg v-else class="dpic dph" viewBox="0 0 240 120" aria-hidden="true">
              <g fill="currentColor">
                <rect x="4" y="56" width="54" height="7" rx="2.5" />
                <rect x="46" y="45" width="5" height="11" rx="1" />
                <rect x="58" y="51" width="44" height="16" rx="3" />
                <rect x="100" y="47" width="72" height="23" rx="3" />
                <rect x="102" y="42" width="58" height="6" rx="2" />
                <path d="M118 70 l19 0 l-7 32 l-17 0 z" />
                <path d="M152 70 l17 0 l-9 28 l-15 0 z" />
                <path d="M172 51 h27 c9 0 14 5 14 11 v9 h-15 l-6 -9 h-20 z" />
              </g>
            </svg>
            <div class="dhead">
              <div class="dh-name">{{ c.gun.zh }}<span class="dh-en">{{ c.gun.en }}</span></div>
              <div class="dh-meta">{{ CAL[c.gun.cal].label }} · {{ c.gun.rpm }} RPM · 面板 {{ c.gun.dmg }}/{{ c.gun.admg }}<template v-if="c.gun.burst"> · 三连发</template></div>
            </div>
            <ul v-if="detail.bits.length" class="dh-note">
              <li v-for="b in detail.bits" :key="b">{{ b }}</li>
            </ul>
          </header>

          <!-- 弹药通栏对比行：列对齐，宽度吃满 -->
          <div class="drows">
            <div class="drow capt" aria-hidden="true">
              <span class="d-rank"></span>
              <span class="d-ammo capt-t">弹药</span>
              <span class="d-ttk capt-t">TTK<small>条越长越快</small></span>
              <span class="d-parts capt-t">部位单发<small>当前场景部位高亮</small></span>
              <span class="d-judge capt-t">判定与碎甲</span>
            </div>
            <div
              v-for="(item, i) in detail.list"
              :key="item.x.am.n"
              class="drow"
              :class="{ best: item.x.ttk === c.ttk }"
            >
              <span class="d-rank">{{ String(i + 1).padStart(2, '0') }}</span>
              <span class="d-ammo">
                <PenBadge :p="item.x.am.pen" />
                <span class="d-an">{{ item.x.am.n }}</span>
              </span>
              <span class="d-ttk">
                <span class="d-ttv">{{ fmtMs(item.x.ttk) }}</span>
                <span class="d-bar"><i :style="{ width: item.w }"></i></span>
                <span class="d-btk">{{ item.x.btk }} 发击倒</span>
              </span>
              <span class="d-parts">
                <span
                  v-for="[pk, pv] in partDmg(item.x.gun, item.x.am)"
                  :key="pk"
                  class="d-pd"
                  :class="{ cur: pk === PART_CHAR[c.part] }"
                >{{ pk }} {{ fmtDmg(pv) }}</span>
              </span>
              <span class="d-judge">
                <span class="d-jline">{{ metaText(item.x) }}<template v-if="item.x.btk > item.x.gun.mag"> · <span class="warn">超弹匣 {{ item.x.gun.mag }} 发</span></template></span>
                <span v-if="extraText(item.x, CAL[item.x.gun.cal].est)" class="d-jnote">{{ extraText(item.x, CAL[item.x.gun.cal].est) }}</span>
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* 行容器与展开动画（legacy L155-174），取值令牌化 */
.rk-row-wrap {
  border-bottom: 1px solid var(--line2);
}
.rk-row-wrap:last-child {
  border-bottom: 0;
}
/* 斑马纹（.rk-head 是第 1 个子元素，odd 子位恰好落在第 2/4/6…行） */
.rk-row-wrap:nth-child(odd) { background: var(--zebra); }
/* 行栅格（legacy L95，与 TtkView 内 .rk-head 保持同值） */
.rk-row {
  display: grid;
  grid-template-columns: 40px minmax(150px, 1.15fr) minmax(140px, 1fr) 52px 60px 62px minmax(150px, 1.2fr);
  gap: 12px;
  align-items: center;
  width: 100%;
  border: 0;
  background: none;
  color: var(--tx);
  text-align: left;
  padding: 11px 34px 11px 16px;
  border-bottom: 0;
  cursor: pointer;
  transition: background var(--t-fast);
  position: relative;
}
.rk-row:hover { background: var(--row-hover); }
.rk-row.top1 { background: linear-gradient(90deg, rgba(45, 212, 191, .075), transparent 70%); }
.rk-row.top1::before {
  content: "";
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  width: 2px;
  background: var(--accent);
}
.rk-row.open { background: rgba(255, 255, 255, .03); }
.rk-num {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  color: var(--faint);
  font-variant-numeric: tabular-nums;
}
.rk-row.top1 .rk-num { color: var(--accent); }
.rk-row.top2 .rk-num,
.rk-row.top3 .rk-num { color: var(--accent-dim); }
.rk-gun { min-width: 0; }
.rk-gun .n {
  display: block;
  font-size: var(--fs-sm);
  font-weight: 600;
  line-height: 1.45;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  color: var(--tx-strong);
}
.rk-gun .s {
  display: block;
  font-family: var(--mono);
  font-size: var(--fs-micro);
  color: var(--faint);
  letter-spacing: .04em;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  margin-top: 1px;
}
.rk-gun .s em {
  font-style: normal;
  color: var(--dim);
}
.rk-gun .s .scen {
  color: var(--accent-dim);
  font-weight: 600;
}
.rk-ammo {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.rk-ammo .an {
  font-size: var(--fs-xs);
  color: var(--dim);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.rk-cell {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  color: var(--dim);
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
}
/* 数字列右对齐（射速 / 单发伤 / 击杀），与表头同规则 */
.rk-cell.num { text-align: right; }
.rk-cell.strong {
  color: var(--tx-strong);
  font-weight: 600;
}
.rk-ta {
  display: flex;
  align-items: center;
  gap: 10px;
  justify-content: flex-end;
  min-width: 0;
}
.rk-bar {
  flex: 1;
  height: 5px;
  border-radius: 3px;
  background: var(--bg);
  overflow: hidden;
  min-width: 40px;
}
.rk-bar i {
  display: block;
  height: 100%;
  border-radius: 3px;
  background: var(--accent);
  background: linear-gradient(90deg, color-mix(in srgb, var(--accent) 55%, transparent), var(--accent));
  transition: width .25s var(--ease);
}
.rk-row.slow .rk-bar i { background: var(--line-hover); }
.rk-ttv {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  color: var(--tx-strong);
  font-weight: 600;
  min-width: 58px;
  text-align: right;
  font-variant-numeric: tabular-nums;
}
.rk-row.top1 .rk-ttv { color: var(--accent); }
.rk-row.slow .rk-ttv {
  color: var(--faint);
  font-weight: 400;
}
.caret {
  position: absolute;
  right: 16px;
  top: 50%;
  transform: translateY(-50%);
  width: 12px;
  height: 12px;
  color: var(--faint);
  opacity: .55;
  transition: transform var(--t-slow);
}
.rk-row.open .caret { transform: translateY(-50%) rotate(180deg); }

/* 详情（legacy L155-170） */
.rk-detail {
  display: grid;
  grid-template-rows: 0fr;
  transition: grid-template-rows .25s var(--ease);
}
.rk-detail.open { grid-template-rows: 1fr; }
.rk-detail-in {
  overflow: hidden;
  min-height: 0;
}
/* 详情：枪械头带（渲染图 + 名牌 + 备注）+ 通栏弹药对比行（列对齐吃满宽度） */
.dwrap { padding: 8px 16px 16px 52px; }
.dband {
  display: flex;
  align-items: center;
  gap: 18px;
  padding: 10px 16px;
  border: 1px solid var(--line2);
  border-radius: var(--radius);
  background: var(--bg2);
}
.dpic { flex: none; width: 184px; height: auto; }
.dph { color: var(--faint); opacity: .4; padding: 10px 0; }
.dhead { min-width: 0; }
.dh-name {
  display: flex;
  align-items: baseline;
  gap: 8px;
  flex-wrap: wrap;
  font-size: var(--fs-lg);
  font-weight: 700;
  color: var(--tx-strong);
}
.dh-en {
  font-family: var(--mono);
  font-size: var(--fs-micro);
  font-weight: 400;
  color: var(--faint);
  letter-spacing: .04em;
}
.dh-meta {
  margin-top: 3px;
  font-family: var(--mono);
  font-size: var(--fs-micro);
  color: var(--dim);
  letter-spacing: .04em;
}
.dh-note {
  flex: 1;
  min-width: 200px;
  align-self: stretch;
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 3px;
  margin: 0;
  padding: 2px 0 2px 18px;
  border-left: 1px solid var(--line2);
  list-style: none;
}
.dh-note li {
  position: relative;
  padding-left: 13px;
  font-size: var(--fs-xs);
  color: var(--dim);
  line-height: 1.65;
}
.dh-note li + li { margin-top: 3px; }
.dh-note li::before {
  content: "◆";
  position: absolute;
  left: 0;
  top: 1px;
  font-size: 7px;
  color: var(--accent-dim);
}

/* 弹药行栅格：排名 | 弹药 | TTK+条 | 部位单发 | 判定碎甲 */
.drows { margin-top: 10px; border-top: 1px solid var(--line2); }
.drow {
  display: grid;
  grid-template-columns: 26px minmax(120px, 1fr) minmax(206px, 1.3fr) minmax(224px, 1.25fr) minmax(252px, 1.55fr);
  grid-template-areas: "rank ammo ttk parts judge";
  gap: 12px;
  align-items: center;
  padding: 9px 12px;
}
.drow + .drow { border-top: 1px solid var(--line2); }
.drow.capt { padding: 7px 12px 6px; align-items: end; }
.drow.capt .capt-t {
  font-family: var(--mono);
  font-size: var(--fs-micro);
  letter-spacing: .16em;
  color: var(--faint);
  white-space: nowrap;
}
.drow.capt small {
  display: block;
  font-size: var(--fs-micro);
  letter-spacing: .06em;
  opacity: .72;
  margin-top: 2px;
}
.drow.capt .d-ttk { display: block; }
.drow.best {
  background: linear-gradient(90deg, var(--accent-bg), transparent 62%);
  box-shadow: inset 2px 0 0 var(--accent);
}
.d-rank {
  grid-area: rank;
  font-family: var(--mono);
  font-size: var(--fs-xs);
  color: var(--faint);
  font-variant-numeric: tabular-nums;
}
.drow.best .d-rank { color: var(--accent); }
.d-ammo {
  grid-area: ammo;
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.d-an {
  font-size: var(--fs-xs);
  font-weight: 600;
  color: var(--tx-strong);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.d-ttk {
  grid-area: ttk;
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
}
.d-ttv {
  font-family: var(--mono);
  font-size: var(--fs-md);
  font-weight: 600;
  color: var(--tx-strong);
  min-width: 56px;
  font-variant-numeric: tabular-nums;
}
.drow.best .d-ttv { color: var(--accent); }
.d-bar {
  flex: 1;
  height: 5px;
  border-radius: 3px;
  background: var(--bg);
  overflow: hidden;
  min-width: 44px;
}
.d-bar i {
  display: block;
  height: 100%;
  border-radius: 3px;
  background: linear-gradient(90deg, color-mix(in srgb, var(--accent) 50%, transparent), var(--accent));
}
.drow.best .d-bar i { background: var(--accent); }
.d-btk {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  color: var(--dim);
  white-space: nowrap;
}
.d-parts {
  grid-area: parts;
  display: flex;
  flex-wrap: wrap;
  column-gap: 9px;
  row-gap: 2px;
  align-items: baseline;
  min-width: 0;
}
.d-pd {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  color: var(--dim);
  font-variant-numeric: tabular-nums;
}
.d-pd.cur { color: var(--accent-dim); font-weight: 600; }
.d-judge {
  grid-area: judge;
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}
.d-jline {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  color: var(--dim);
  line-height: 1.5;
}
.d-jline .warn { color: var(--danger); }
.d-jnote {
  font-family: var(--mono);
  font-size: var(--fs-micro);
  color: var(--faint);
  line-height: 1.5;
}

@media (max-width: 820px) {
  /* legacy 同款：此处 padding:0 12px 覆盖基础 11px 上下内边距（保持原页窄屏表现） */
  .rk-row {
    grid-template-columns: 26px minmax(0, 1.25fr) minmax(0, 1fr) 42px 82px;
    gap: 7px;
    padding: 0 12px;
  }
  .hide-m { display: none; }
  .rk-bar { min-width: 22px; }
  .rk-ttv {
    min-width: 46px;
    font-size: var(--fs-2xs);
  }
  .rk-cell.strong { font-size: var(--fs-2xs); }
  .caret { display: none; }
  .dwrap { padding: 4px 12px 12px; }
  .dband { flex-wrap: wrap; gap: 8px 14px; }
  .dpic { width: 40%; min-width: 128px; }
  .dhead { flex: 1 1 0; min-width: 130px; }
  .dh-note {
    flex-basis: 100%;
    align-self: auto;
    border-left: 0;
    border-top: 1px solid var(--line2);
    padding: 8px 0 0;
  }
  .drow {
    grid-template-columns: 22px minmax(0, 1fr) auto;
    grid-template-areas:
      "rank ammo ttk"
      "parts parts parts"
      "judge judge judge";
    gap: 5px 10px;
    padding: 9px 10px;
  }
  .drow.capt { display: none; }
  .d-ttk { justify-content: flex-end; }
  .d-ttv { min-width: 48px; font-size: var(--fs-sm); }
  .d-bar { min-width: 34px; }
  .d-btk { display: none; }
}
@media (max-width: 560px) {
  /* 排行行改两行式：第一行 排名+武器+BTK，第二行 弹药+TTK条 */
  .rk-row {
    grid-template-columns: 24px minmax(0, 1fr) auto;
    grid-template-rows: auto auto;
    column-gap: 10px;
    row-gap: 6px;
    padding: 11px 12px;
  }
  .rk-num {
    grid-column: 1;
    grid-row: 1;
    align-self: start;
    padding-top: 1px;
  }
  .rk-gun {
    grid-column: 2;
    grid-row: 1;
    min-width: 0;
  }
  .rk-cell.strong {
    grid-column: 3;
    grid-row: 1;
    align-self: start;
  }
  .rk-ammo {
    grid-column: 1 / 3;
    grid-row: 2;
  }
  .rk-ammo .an {
    white-space: normal;
    overflow: visible;
    text-overflow: clip;
    line-height: 1.5;
  }
  .rk-ta {
    grid-column: 3;
    grid-row: 2;
    width: 112px;
  }
  .rk-bar { min-width: 30px; }
  .rk-ttv { min-width: 48px; }
  .rk-row.top1::before { width: 2px; }
}
@media (prefers-reduced-motion: reduce) {
  .rk-bar i, .caret, .rk-detail, .rk-row { transition: none; }
}
</style>
