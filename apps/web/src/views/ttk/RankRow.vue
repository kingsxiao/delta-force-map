<script setup>
// 排行单行 + 逐发模拟详情（legacy renderRank 行装配 L720-812 的组件化）：
// - 行类目 top1/top2/top3/slow、TTK 条宽 Math.max(4, Math.min(100, best/ttk*100)) 均按原口径；
// - 详情懒加载：首次展开才计算该枪全弹药对比（open=false 时 computed 返回 null，不产生开销）；
// - 详情列表 = 当前筛选下该枪全部组合按 TTK 升序（legacy L772-773 同口径），
//   与点击行 TTK 相同的卡标记 best（legacy L775）。
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import { CAL } from '../../data/ttk/calibers.js'
import { ttkAmmoMarketName } from '../../data/ttk/ammo-market-alias.js'
import { fmtMs, fmtDmg, metaText, extraText, scenLabel, partDmg, PART_CHAR } from './format.js'
import PenBadge from './PenBadge.vue'

const props = defineProps({
  c: { type: Object, required: true },      // combo 结果（含 gun/am/btk/broke/pass/flesh/noArmorBtk/ttk/part/armor）
  rank: { type: Number, required: true },
  best: { type: Number, required: true },   // 当前列表最快 TTK（条宽基准）
  open: { type: Boolean, default: false },
  combos: { type: Array, required: true },  // 当前筛选下全部组合（详情数据源）
  showScen: { type: Boolean, default: false }, // 多场景时在副行标注归属（5 级头）
  tier: { type: String, default: '' },  // T0-T3 强度分档标签（固定基准，见 TtkView tierGun）
  delay: { type: Number, default: 0 },  // 展示层扳机延迟修正（ms）：等量平移，不改名次/模型
  prices: { type: Object, default: null },  // 行情价格上下文（TtkView 传入）：{ byName, ok }
})

const router = useRouter()

/* 行情条目（展开详情的弹药对比行按弹名反查现价；无映射 / 行情不可用 → null 不渲染） */
function marketOf(am) {
  if (!props.prices?.ok) return null
  const name = ttkAmmoMarketName(props.c.gun.cal, am.n)
  return name ? props.prices.byName[name] ?? null : null
}
function priceText(i) {
  const cur = Math.round(i.current).toLocaleString('zh-CN')
  return i.rank == null ? '现价 ' + cur : '现价 ' + cur + ' · ' + Math.round(i.rank * 100) + '%'
}
function gotoMarket(am) {
  const name = ttkAmmoMarketName(props.c.gun.cal, am.n)
  if (name) router.push({ path: '/ammo', query: { q: name } })
}

defineEmits(['toggle'])

/* 分档徽标配色（与 TierBoard 卡片同色）：T0 金 / T1 主色 / T2 蓝 / T3 灰 */
const TIER_COLORS = { T0: 'var(--lv5)', T1: 'var(--accent)', T2: 'var(--lv3)', T3: 'var(--lv0)' }
const tierColor = computed(() => TIER_COLORS[props.tier] || 'var(--faint)')

const rowClass = computed(() => ({
  top1: props.rank === 1,
  top2: props.rank === 2,
  top3: props.rank === 3,
  /* 慢行 = ttk > 2.2× 基准；基准由 TtkView bestTtk 取全表最小正 TTK 后恒正，best>0 仅留兜底（legacy L828 同守卫） */
  slow: props.best > 0 && props.c.ttk > props.best * 2.2,
  open: props.open,
}))

/* ttk=0（头部×无甲 btk=1）的行本就是最快、条画满；best≤0 分支防 0/0，bestTtk 恒正后仅兜底（legacy L860 同守卫） */
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
  <!-- 根 wrapper 挂 --ri 供容器级级联错峰（§7.3）；hover 过渡留在内层 button、与入场 animation 正交 -->
  <div class="rk-row-wrap" :class="{ open }" :style="{ '--ri': rank - 1 }">
    <button
      type="button"
      class="rk-row"
      :class="rowClass"
      :aria-expanded="String(open)"
      @click="$emit('toggle')"
    >
      <span class="rk-num">{{ String(rank).padStart(2, '0') }}</span>
      <span class="rk-thumb" :class="{ ph: !c.gun.img }" aria-hidden="true">
        <img v-if="c.gun.img" class="rk-img" :src="'/guns/' + c.gun.img + '.webp'" alt="" loading="lazy" decoding="async">
        <svg v-else class="rk-sil" viewBox="0 0 240 120"><g fill="currentColor"><rect x="4" y="56" width="54" height="7" rx="2.5"/><rect x="58" y="51" width="44" height="16" rx="3"/><rect x="100" y="47" width="72" height="23" rx="3"/><path d="M118 70 l19 0 l-7 32 l-17 0 z"/><path d="M152 70 l17 0 l-9 28 l-15 0 z"/><path d="M172 51 h27 c9 0 14 5 14 11 v9 h-15 l-6 -9 h-20 z"/></g></svg>
      </span>
      <span class="rk-gun">
        <span class="n"><em v-if="tier" class="tier-b" :style="{ color: tierColor }">{{ tier }}</em>{{ c.gun.zh }}</span>
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
        <span class="rk-ttv">{{ fmtMs(c.ttk + delay) }}</span>
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
                <span class="d-ammo-main">
                  <PenBadge :p="item.x.am.pen" />
                  <span class="d-an">{{ item.x.am.n }}</span>
                </span>
                <button
                  v-if="marketOf(item.x.am)"
                  type="button"
                  class="d-mp"
                  :title="'去行情页看 ' + ttkAmmoMarketName(c.gun.cal, item.x.am.n) + ' 走势'"
                  @click="gotoMarket(item.x.am)"
                >{{ priceText(marketOf(item.x.am)) }}</button>
              </span>
              <span class="d-ttk">
                <span class="d-ttv">{{ fmtMs(item.x.ttk) }}</span>
                <span class="d-bar"><i :style="{ width: item.w }"></i></span>
                <span class="d-btk">{{ item.x.btk }} 发击杀</span>
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
  grid-template-columns: 40px 52px minmax(138px, 1.1fr) minmax(126px, 1fr) 52px 60px 62px minmax(140px, 1.2fr);
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
  transition: background var(--t-fast) var(--ease), box-shadow var(--t-fast) var(--ease);
  position: relative;
}
/* hover / 键盘 focus-visible 行高亮（规格「可点表格行」：focus-visible 底 --row-hover） */
.rk-row:hover,
.rk-row:focus-visible { background: var(--row-hover); }
/* 冠军行 top1：--accent-bg 渐变底 + 左缘 2px --accent 实色（语义分层：冠军用实色，展开态用 --accent-dim） */
.rk-row.top1 { background: linear-gradient(90deg, var(--accent-bg), transparent 70%); }
.rk-row.top1:hover,
.rk-row.top1:focus-visible {
  background: linear-gradient(90deg, rgba(45, 212, 191, .12), transparent 70%);
  background: linear-gradient(90deg, color-mix(in srgb, var(--accent) 12%, transparent), transparent 70%);
}
.rk-row.top1::before {
  content: "";
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  width: 2px;
  background: var(--accent);
}
/* 展开选中：底 --accent-bg + 左缘 2px --accent-dim 内描边（一眼可辨且与 top1 实色分层） */
.rk-row.open { background: var(--accent-bg); box-shadow: inset 2px 0 0 var(--accent-dim); }
.rk-row.open:hover,
.rk-row.open:focus-visible {
  background: rgba(45, 212, 191, .12);
  background: color-mix(in srgb, var(--accent) 12%, transparent);
}
.rk-num {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  color: var(--faint);
  font-variant-numeric: tabular-nums;
}
.rk-row.top1 .rk-num { color: var(--accent); }
.rk-row.top2 .rk-num,
.rk-row.top3 .rk-num { color: var(--accent); }
/* 行内枪械缩略图：官方渲染图懒加载；无图枪用剪影占位（与详情头带同语言） */
.rk-thumb {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 36px;
}
.rk-thumb .rk-img {
  max-width: 100%;
  max-height: 100%;
  filter: drop-shadow(0 2px 5px rgba(0, 0, 0, .45));
}
.rk-thumb.ph { color: var(--faint); opacity: .38; }
.rk-thumb .rk-sil { width: 46px; height: auto; }
/* T0-T3 分档徽标：等宽字小方标，颜色随分档（与 TierBoard 身份色一致） */
.tier-b {
  display: inline-block;
  font-family: var(--mono);
  font-style: normal;
  font-size: var(--fs-micro);
  font-weight: 600;
  letter-spacing: .08em;
  line-height: 1;
  padding: 2px 4px;
  margin-right: 6px;
  border: 1px solid currentColor;
  border-radius: 4px;
  opacity: .92;
  vertical-align: 1px;
}
@media (max-width: 680px) {
  .rk-thumb { grid-column: 2; grid-row: 1; height: 30px; }
}
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
  font-size: var(--fs-xs);
  color: var(--dim);
  letter-spacing: .04em;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  margin-top: 1px;
}
.rk-gun .s em {
  font-style: normal;
  color: var(--tx);
}
.rk-gun .s .scen {
  color: var(--accent);
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
  transition: width var(--t-slow) var(--ease);
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
  transition: transform var(--t-slow) var(--ease);
}
.rk-row.open .caret { transform: translateY(-50%) rotate(180deg); }

/* 详情（legacy L155-170）；折叠展开统一 --t-collapse（0fr→1fr 收编） */
.rk-detail {
  display: grid;
  grid-template-rows: 0fr;
  transition: grid-template-rows var(--t-collapse) var(--ease);
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
  font-size: var(--fs-xs);
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
  content: "";
  position: absolute;
  left: 0;
  top: 8px;
  width: 4px;
  height: 4px;
  border-radius: 1px;
  background: var(--accent-dim);
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
  font-size: var(--fs-xs);
  letter-spacing: .06em;
  color: var(--faint);
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
  flex-direction: column;
  align-items: flex-start;
  gap: 3px;
  min-width: 0;
}
/* 徽标 + 弹名横排（现价链接在下方第二行，联动行情页） */
.d-ammo-main {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
/* 现价文本链（跳行情页）：等宽数字 + accent，hover/active 下划线（规格同 .ammo-toggle） */
.d-mp {
  border: 0;
  background: none;
  padding: 0;
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  letter-spacing: .02em;
  color: var(--accent);
  cursor: pointer;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.d-mp:hover,
.d-mp:active { text-decoration: underline; }
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
.d-pd.cur { color: var(--accent); font-weight: 600; }
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
  font-size: var(--fs-xs);
  color: var(--dim);
  line-height: 1.5;
}

@media (max-width: 820px) {
  /* ≤820 行触达（§5.4）：上下 10px + min-height 44px 兜底，任何断点行高 ≥44px */
  .rk-row {
    grid-template-columns: 26px 44px minmax(0, 1.2fr) minmax(0, 1fr) 42px 82px;
    gap: 7px;
    padding: 10px 12px;
    min-height: 44px;
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
@media (max-width: 680px) {
  /* 排行行改两行式：第一行 排名+武器+BTK，第二行 弹药+TTK条 */
  .rk-row {
    grid-template-columns: 24px 40px minmax(0, 1fr) auto;
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
    grid-column: 3;
    grid-row: 1;
    min-width: 0;
  }
  .rk-cell.strong {
    grid-column: 4;
    grid-row: 1;
    align-self: start;
  }
  .rk-ammo {
    grid-column: 1 / 4;
    grid-row: 2;
  }
  .rk-ammo .an {
    white-space: normal;
    overflow: visible;
    text-overflow: clip;
    line-height: 1.5;
  }
  .rk-ta {
    grid-column: 4;
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
