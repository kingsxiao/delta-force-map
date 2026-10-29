<script setup>
// 排行单行 + 逐发模拟详情（legacy renderRank 行装配 L720-812 的组件化）：
// - 行类目 top1/top2/top3/slow、TTK 条宽 Math.max(4, Math.min(100, best/ttk*100)) 均按原口径；
// - 详情懒加载：首次展开才计算该枪全弹药对比（open=false 时 computed 返回 null，不产生开销）；
// - 详情列表 = 当前筛选下该枪全部组合按 TTK 升序（legacy L772-773 同口径），
//   与点击行 TTK 相同的卡标记 best（legacy L775）。
import { computed, onBeforeUnmount, ref, watch } from 'vue'
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

/* 枪械渲染图：BASE_URL 前缀随子路径部署（同行情页数据 URL 口径）；加载失败就地隐藏（同 hideImg 口径） */
const gunImg = (img) => `${import.meta.env.BASE_URL}guns/${img}.webp`
const hideImg = (e) => { e.target.style.display = 'none' }

/* 分档徽标配色（与 TierBoard 卡片同色）：T0 金 / T1 主色 / T2 蓝 / T3 灰。
   T3 不用 --lv0（#79828b 在 --card 上仅 4.35:1，10px/600 小徽标不够大字豁免线），
   局部提亮到 --dim（≥6.1:1）；--lv0 语义留给护甲等级 0，全局不动 */
const TIER_COLORS = { T0: 'var(--lv5)', T1: 'var(--accent)', T2: 'var(--lv3)', T3: 'var(--dim)' }
const tierColor = computed(() => TIER_COLORS[props.tier] || 'var(--faint)')

const rowClass = computed(() => ({
  top1: props.rank === 1,
  top2: props.rank === 2,
  top3: props.rank === 3,
  /* 慢行 = ttk > 2.2× 基准；基准由 TtkView bestTtk 取全表最小正 TTK 后恒正，best>0 仅留兜底（legacy L828 同守卫） */
  slow: props.best > 0 && props.c.ttk > props.best * 2.2,
  open: props.open,
}))

/* ttk=0（头部×无甲 btk=1）的行本就是最快、条画满；best≤0 分支防 0/0，bestTtk 恒正后仅兜底（legacy L860 同守卫）。
   比例口径 Math.max(4, Math.min(100, best/ttk*100)) 不变，表达由「宽度百分比」改为「满宽 scaleX 系数」：
   MOTION.md §6-3 禁过渡 width 只过渡 transform（渐变随缩放拉伸可接受，父级 .rk-bar 定宽裁剪不变） */
const barScale = computed(() =>
  (props.best <= 0 || props.c.ttk <= 0)
    ? 1
    : Math.max(4, Math.min(100, props.best / props.c.ttk * 100)) / 100)

/* 详情懒计算（open=false 不算、不产生开销）。收起保活：detail 若在收起瞬间变 null，
   内容会在折叠动画起点被卸载、250ms 塌缩只剩空壳（CollapseCol 的槽内容是随折叠体
   一起收拢的，同页两种收起形态不一致）——detailCache 保住最近一次结果，收起期间
   旧内容随折叠体一起收拢；open→false 再等 260ms（≈ --t-collapse 250ms + 1 帧，
   同下方展开定位定时器口径）才撤挂载：0fr + overflow:hidden 不出焦也不隐没，
   必须真的卸载才不给读屏器 / Tab 序残留一份隐藏详情，DOM 也不常驻 */
const detailLive = computed(() => {
  if (!props.open) return null
  // 详情限定在点击行同一场景（部位 × 护甲），跨场景数值混排会失去对比意义
  const list = props.combos
    .filter((x) => x.gun === props.c.gun && x.part === props.c.part && x.armor === props.c.armor)
    .sort((a, b) => a.ttk - b.ttk)
  // 条宽基准取详情内最小「正」TTK（同 TtkView bestTtk 口径）：btk=1 一枪死（ttk=0）
  // 稳居列表首位，直接用 list[0] 会 0/0=NaN、基准为 0 时其余弹全塌最小条
  const base = list.find((x) => x.ttk > 0)?.ttk || 1
  const g = props.c.gun
  const bits = []
  if (g.note) bits.push(g.note)
  if (g.est) bits.push('数值置信度较低')
  if (g.belly != null) bits.push('该枪胸腹同伤（腹部 ×' + g.belly + '）')
  return {
    list: list.map((x) => ({
      x,
      /* ttk=0 条画满，0 基准防 0/0=NaN——守卫与行级 barScale 同款（基准恒正后仅兜底）。
         表达同样与行级统一为 scaleX 系数（0-1）：同页面同语义（TTK 比例条）一套配方，
         杜绝后续任何给详情条加过渡时把 width 动画带回来（MOTION.md §6-3 口径） */
      w: (base <= 0 || x.ttk <= 0)
        ? 1
        : Math.max(4, Math.min(100, base / x.ttk * 100)) / 100,
    })),
    bits,
  }
})
const detailCache = ref(null)
watch(detailLive, (d) => { if (d) detailCache.value = d })
let unmountTimer = 0
watch(() => props.open, (v) => {
  clearTimeout(unmountTimer)
  if (v) return
  unmountTimer = setTimeout(() => { detailCache.value = null }, 260)
})
/* 模板沿用 detail 名：展开期取实时值，收起动画期间回落到缓存 */
const detail = computed(() => detailLive.value || detailCache.value)

/* 展开后定位（MOTION.md §3-C「展开后定位」口径，行情页 expander 同款反馈闭环）：
   详情带（头带 + 全弹对比）高 300-600px，点视口中部的行时行头常被顶出视口、
   详情尾部悬在屏外——展开完成后按 nearest 做最小滚动（整行已可见则不动）。
   等 260ms（≈ --t-collapse 250ms + 1 帧）再判：折叠动画中行头仍可见、以瞬时
   盒子判定会漏滚；RM 下折叠瞬时完成，定时器路径一致、仅滚动直达 */
const wrapEl = ref(null)
let scrollTimer = 0
watch(() => props.open, (v) => {
  clearTimeout(scrollTimer)
  if (!v) return
  scrollTimer = setTimeout(() => {
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    wrapEl.value?.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth', block: 'nearest' })
  }, 260)
})
onBeforeUnmount(() => { clearTimeout(scrollTimer); clearTimeout(unmountTimer) })
</script>

<template>
  <!-- 根 wrapper 挂 --ri 供容器级级联错峰（§7.3）；hover 过渡留在内层 button、与入场 animation 正交 -->
  <div ref="wrapEl" class="rk-row-wrap" :class="{ open }" :style="{ '--ri': rank - 1 }">
    <button
      type="button"
      class="rk-row"
      :class="rowClass"
      :aria-expanded="String(open)"
      @click="$emit('toggle')"
    >
      <span class="rk-num">{{ String(rank).padStart(2, '0') }}</span>
      <span class="rk-thumb" :class="{ ph: !c.gun.img }" aria-hidden="true">
        <img v-if="c.gun.img" class="rk-img" :src="gunImg(c.gun.img)" alt="" loading="lazy" decoding="async" @error="hideImg">
        <svg v-else class="rk-sil" viewBox="0 0 240 120"><g fill="currentColor"><rect x="4" y="56" width="54" height="7" rx="2.5"/><rect x="58" y="51" width="44" height="16" rx="3"/><rect x="100" y="47" width="72" height="23" rx="3"/><path d="M118 70 l19 0 l-7 32 l-17 0 z"/><path d="M152 70 l17 0 l-9 28 l-15 0 z"/><path d="M172 51 h27 c9 0 14 5 14 11 v9 h-15 l-6 -9 h-20 z"/></g></svg>
      </span>
      <span class="rk-gun">
        <span class="n"><em v-if="tier" class="tier-b" :style="{ color: tierColor }">{{ tier }}</em>{{ c.gun.zh }}</span>
        <!-- 场景标注放行首：副行 nowrap+ellipsis，标注放尾部时多场景叠加（页面主推交互）
             会被整个裁掉（列表无其他行级场景指示，归属信息全丢），前置保证「N 级头/胸」恒可见 -->
        <span class="s">
          <template v-if="showScen"><b class="scen">{{ scenLabel(c) }}</b> · </template><em>{{ CAL[c.gun.cal].label }}</em> · {{ c.gun.rpm }} RPM · 面板 {{ c.gun.dmg }}/{{ c.gun.admg }}<template v-if="c.gun.burst"> · 三连发</template>
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
        <span class="rk-bar"><i :style="{ transform: 'scaleX(' + barScale + ')' }"></i></span>
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
              :src="gunImg(c.gun.img)"
              :alt="c.gun.zh + ' 官方渲染图'"
              loading="lazy"
              decoding="async"
              @error="hideImg"
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
                <!-- aria-label：可见名只有「现价 · 分位」数字串，title 仅鼠标可见——
                     触屏与读屏用户都需要一个含弹名的可读名 -->
                <button
                  v-if="marketOf(item.x.am)"
                  type="button"
                  class="d-mp"
                  :title="'去行情页看 ' + ttkAmmoMarketName(c.gun.cal, item.x.am.n) + ' 走势'"
                  :aria-label="ttkAmmoMarketName(c.gun.cal, item.x.am.n) + ' 现价与行情走势'"
                  @click="gotoMarket(item.x.am)"
                >{{ priceText(marketOf(item.x.am)) }}</button>
              </span>
              <span class="d-ttk">
                <span class="d-ttv">{{ fmtMs(item.x.ttk) }}</span>
                <span class="d-bar"><i :style="{ transform: 'scaleX(' + item.w + ')' }"></i></span>
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
/* 展开定位的滚动让位（配合上方 watch 的 scrollIntoView）：>680 控制面板吸顶
   （top:8px、常态高约 145px），nearest 把整行贴视口顶时行头须落在面板之下，
   160px 留少量余量；提示条再展开时行头可能被其下缘轻微压住——nearest 多数
   情况不贴顶、属可忍。680 以下面板解除吸顶且全局顶栏不吸顶，无需让位 */
@media (min-width: 681px) {
  .rk-row-wrap { scroll-margin-top: 160px; }
}
/* 斑马纹（.rk-head 是第 1 个子元素，odd 子位恰好落在第 2/4/6…行） */
.rk-row-wrap:nth-child(odd) { background: var(--zebra); }
/* 行栅格（legacy L95，与 TtkView 内 .rk-head 保持同值）。
   枪名轨 1.1→1.35fr、TTK 轨 1.2→1fr（弹药轨不变）：1.1fr 时枪名轨在 1440 下仅 ~261px，
   副行最长「.338 Lapua Magnum · 35 RPM · 面板 100/10」≈302px 与三连发枪的「· 三连发」尾标
   都被省略号裁掉；从 TTK 轨匀 ~50px 给枪名轨后 ~315px 全显，TTK 条仍有 ~165px 可读 */
.rk-row {
  display: grid;
  grid-template-columns: 40px 52px minmax(138px, 1.35fr) minmax(126px, 1fr) 52px 60px 62px minmax(140px, 1fr);
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
/* 冠军行 top1：--accent-bg 渐变底（全站规范：卡片/行不带左缘竖条，冠军语义由渐变底+排名色承担） */
.rk-row.top1 { background: linear-gradient(90deg, var(--accent-bg), transparent 70%); }
.rk-row.top1:hover,
.rk-row.top1:focus-visible {
  background: linear-gradient(90deg, rgba(45, 212, 191, .12), transparent 70%);
  background: linear-gradient(90deg, color-mix(in srgb, var(--accent) 12%, transparent), transparent 70%);
}
/* 展开选中：--accent-bg 微底（与 top1 渐变底分层，一眼可辨） */
.rk-row.open { background: var(--accent-bg); }
.rk-row.open:hover,
.rk-row.open:focus-visible {
  background: rgba(45, 212, 191, .12);
  background: color-mix(in srgb, var(--accent) 12%, transparent);
}
/* 按压态（触屏无 hover 的「按实」回声）：--lift 抬一档面，全站按压配方
   （同 CollapseCol .col-head:active）。源序压过 top1/open 各态底——按压瞬间
   无论何态统一变面，展开/收起动画随即起跑，点击与回声之间不留空窗 */
.rk-row:active { background: var(--lift); }
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
  border-radius: var(--radius-sm); /* 徽标圆角走令牌（PenBadge / TierBoard 徽标同值）；原 4px 是脱离圆角阶梯的字面值 */
  /* 一套徽标配方（对齐 PenBadge .pen「描边 + 同色 12% 底」外形）：分档身份色仍由
     字色/描边承载（与 .pen 的统一亮字不同——徽标本身即内容）；色来自 inline style，
     无法预写 rgba 兜底行，直接 color-mix 单行——不支持的环境整行丢弃、回退现状
     纯描边款（功能完整，仅少一层底色） */
  background: color-mix(in srgb, currentColor 12%, transparent);
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
  width: 100%;
  height: 100%;
  border-radius: 3px;
  background: var(--accent);
  background: linear-gradient(90deg, color-mix(in srgb, var(--accent) 55%, transparent), var(--accent));
  /* §6-3 收编：满宽 + scaleX(比例) 左起缩放代替 width 过渡，比例口径与守卫不变；
     搜索收窄等场景 best 基准变化时条形平滑重缩放 */
  transform-origin: left center;
  transition: transform var(--t-slow) var(--ease);
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
  padding: 2px 0;
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
  font-size: var(--fs-micro); /* 表头附注（「条越长越快」等口径注）与主表头 .rk-head .th-ta small
                                 同层级同字号同字距（.08em）——同一张排行表的两排表头不做出两套注；
                                 micro 白名单本就含表头（不承载实义数据，base.css --fs-micro 注释） */
  letter-spacing: .08em;
  color: var(--faint);
  margin-top: 2px;
}
.drow.capt .d-ttk { display: block; }
.drow.best {
  background: linear-gradient(90deg, var(--accent-bg), transparent 62%);
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
/* 现价文本链（跳行情页）：等宽数字 + accent，hover/active 下划线（规格同 .ammo-toggle）。
   垫层同 AmmoTable .mp（垂直 padding + 等量负 margin，外框与文字位置不变，命中区上下各扩 9px）；
   字阶 xs：现价·分位是实义数据，不低于字阶实义下限 12px（base.css --fs-xs 注释），
   并与 AmmoTable .mp 同尺寸——同一语义链接不做两套配方 */
.d-mp {
  border: 0;
  background: none;
  padding: 9px 0;
  margin: -9px 0;
  font-family: var(--mono);
  font-size: var(--fs-xs);
  letter-spacing: .02em;
  color: var(--accent);
  cursor: pointer;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.d-mp:hover,
.d-mp:active { text-decoration: underline; }
/* 触屏垫层再外延（同 TtkView .ammo-toggle / ControlSeg .seg-btn 手法）：9px 垫层后
   命中区约 38px 仍低于 44px 原则，hover:none 下伪元素上下再外延 5px 到位；左右不扩——
   链接文字本身够宽，两侧是列边界与相邻内容，外扩只会吞邻格点击。伪元素只承接点击不绘制 */
@media (hover: none) {
  .d-mp { position: relative; }
  .d-mp::before {
    content: "";
    position: absolute;
    left: 0;
    right: 0;
    top: -5px;
    bottom: -5px;
  }
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
  /* 与行级 .rk-bar i 同配方（§6-3）：满宽 + scaleX 系数左起缩放；详情条在展开期间
     基准不变、无重算场景，不挂过渡（挂了也只是首帧即终值） */
  width: 100%;
  height: 100%;
  border-radius: 3px;
  background: linear-gradient(90deg, color-mix(in srgb, var(--accent) 50%, transparent), var(--accent));
  transform-origin: left center;
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
  color: var(--faint); /* 备注行比主判定行（--dim）暗一档，两级信息不打架 */
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
  /* 副行同 .an 口径放开换行：两行式枪名 1fr 轨在 390 视口仅 ~150px，副行内容却要 247-302px
     （如「.338 Lapua Magnum · 35 RPM · 面板 100/10」），nowrap+ellipsis 会把「面板 x/y」整段裁掉；
     RPM/面板两列在 ≤820 已随 .hide-m 隐藏，副行是移动端唯一载体，必须全显——
     宁可副行折到两行（行高约 +17px），不做省略号截断 */
  .rk-gun .s {
    white-space: normal;
    overflow: visible;
    text-overflow: clip;
    line-height: 1.5;
  }
  .rk-ta {
    grid-column: 4;
    grid-row: 2;
    /* 不定固定宽（原 112px）：第 4 轨为 auto，按内容收敛到 ~88px（条 30 + 间距 10 + TTK 值 48），
       省下的宽度全让给第 3 轨的枪名 1fr（固定 112px 时第一行「N 发」只需 ~35px 却撑满 112px，
       390 视口下枪名轨被压到 126px）。但省到 150px 也装不下 247-302px 的副行，全显靠上面 .s 放开换行 */
  }
  .rk-bar { min-width: 30px; }
  .rk-ttv { min-width: 48px; }
}
@media (prefers-reduced-motion: reduce) {
  .rk-bar i, .caret, .rk-detail, .rk-row { transition: none; }
}
</style>
