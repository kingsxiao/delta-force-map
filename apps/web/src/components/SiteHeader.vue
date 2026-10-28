<script setup>
import { onBeforeUnmount, onMounted, ref, computed, nextTick, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useAccount } from '../composables/useAccount'

const route = useRoute()
const router = useRouter()
const { user } = useAccount()

// 三个主 tab + 账号入口（登录态显示用户名）；active 高亮按 route.path
// 精确比对（'/' 不应匹配到所有路由）
const tabs = [
  { to: '/ammo', label: '子弹行情' },
  { to: '/radar', label: '异动雷达' },
  { to: '/craft', label: '特勤处制造' },
  { to: '/ttk', label: 'TTK 排行' },
]

/* ================= ⌘K 快捷跳转面板（前沿思路落地） =================
   dialog + showModal 走 top-layer：不受页内 sticky/z-index 遮挡（免遮挡），
   Esc 关闭 / 焦点圈闭 / 关闭后焦点还给触发钮，全部是 dialog 原生能力。
   索引三档：5 页面 + /ttk 页内小节（锚点 id 实存于 TtkView 模板）+
   实体词条（68 枪 + 20 口径）。实体词条懒加载：guns/calibers 静态数据
   原本只活在 /ttk 懒 chunk 里，静态 import 会把它们并进每个页面的主包——
   改为首次开面板时动态 import（本地 chunk，毫秒级），常驻索引只有 10 条零成本。
   枪械词条 → /ttk?q=zh：TtkView 只在 setup 阶段消费一次 query
   （TtkView.vue:142 applyQuery / :148），从其它页跳入即筛到该枪；
   已在 /ttk 时视图不重挂、query 不生效 → 该场景降级为只滚到 #rank。 */
const BASE_ENTRIES = [
  { k: 'p-ammo', label: '子弹行情', hint: '页面', to: '/ammo' },
  { k: 'p-radar', label: '异动雷达', hint: '页面', to: '/radar' },
  { k: 'p-craft', label: '特勤处制造', hint: '页面', to: '/craft' },
  { k: 'p-ttk', label: 'TTK 排行', hint: '页面', to: '/ttk' },
  { k: 'p-acc', label: '账号', hint: '页面', to: '/account' },
  { k: 's-rank', label: '枪械排行榜', hint: 'TTK · 小节', to: '/ttk', hash: 'rank' },
  { k: 's-ammo', label: '弹药库', hint: 'TTK · 小节', to: '/ttk', hash: 'ammo' },
  { k: 's-bal', label: '平衡更新日志', hint: 'TTK · 小节', to: '/ttk', hash: 'balance' },
  { k: 's-armor', label: '护甲一览', hint: 'TTK · 小节', to: '/ttk', hash: 'armor' },
  { k: 's-method', label: '计算方法', hint: 'TTK · 小节', to: '/ttk', hash: 'method' },
]
const entries = ref(BASE_ENTRIES)
let entitiesLoaded = false
function loadEntities() {
  if (entitiesLoaded) return
  entitiesLoaded = true
  Promise.all([import('../data/ttk/guns'), import('../data/ttk/calibers')]).then(
    ([{ GUNS }, { CAL }]) => {
      const CLS_ZH = { ar: '步枪', smg: '冲锋枪', dmr: '射手步枪', snp: '狙击枪', lmg: '轻机枪', sg: '霰弹枪', pst: '手枪' }
      entries.value = [
        ...BASE_ENTRIES,
        ...GUNS.map((g) => ({
          k: 'g-' + g.en, label: g.zh, sub: g.en, sk: CLS_ZH[g.cls] || '',
          hint: (CLS_ZH[g.cls] || '') + ' · TTK 排行', to: '/ttk', hash: 'rank', q: g.zh,
        })),
        ...Object.values(CAL).map((c) => ({
          k: 'c-' + c.label, label: c.label, sub: c.sub,
          hint: '口径 · 弹药库', to: '/ttk', hash: 'ammo',
        })),
      ]
    }
  )
}

const kDlg = ref(null)
const kIn = ref(null)
const kq = ref('')
const ai = ref(0) // 方向键游标（aria-activedescendant 联动）
const K_MAX = 14 // 命中列表上限：滚动扫读负担与「键盘可达任意项」的平衡点
// 空查询只铺页面 + 小节（10 条）；有词才在实体池做中英文不区分大小写匹配。
// sk = 类别搜索键（枪械词条的「狙击枪/冲锋枪…」）：用户按类别搜是高频路径，
// 类别名只出现在 hint（展示用）不参与匹配会让「狙击」一无所获
const matched = computed(() => {
  const q = kq.value.trim().toLowerCase()
  if (!q) return entries.value.slice(0, 10)
  return entries.value.filter(
    (e) =>
      e.label.toLowerCase().includes(q) ||
      (e.sub || '').toLowerCase().includes(q) ||
      (e.sk || '').includes(q)
  )
})
const results = computed(() => matched.value.slice(0, K_MAX))
const moreN = computed(() => matched.value.length - results.value.length)

const isMac = /Mac|iPhone|iPad/.test(navigator.userAgent)

function openK() {
  kq.value = ''
  ai.value = 0
  loadEntities() // 实体词条懒加载：首开触发，本地 chunk 毫秒级、后续命中即时
  kDlg.value?.showModal()
  // dialog 打开后显式聚焦输入框（autofocus 属性在部分引擎的 showModal 时序下不可靠）
  nextTick(() => kIn.value?.focus())
}
function closeK() { kDlg.value?.close() }
function onDlgClose() { kq.value = '' } // 关闭即清词，重开必是干净列表

function onInKey(e) {
  const n = results.value.length
  if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && n) {
    e.preventDefault()
    ai.value = e.key === 'ArrowDown' ? (ai.value + 1) % n : (ai.value - 1 + n) % n
  } else if (e.key === 'Enter') {
    e.preventDefault()
    const it = results.value[ai.value]
    if (it) go(it)
  }
}
/* 视图是动态 import 的懒 chunk：push resolve 只代表路由就绪，目标 id 可能尚未
   挂进 DOM——按帧重试一小段兜住首访冷加载；仍找不到就停在页首（降级不报错） */
function scrollToId(id, rm, tries = 24) {
  const el = document.getElementById(id)
  if (el) {
    el.scrollIntoView({ behavior: rm ? 'auto' : 'smooth', block: 'start' })
    return
  }
  if (tries > 0) requestAnimationFrame(() => scrollToId(id, rm, tries - 1))
}
async function go(e) {
  closeK()
  const rm = window.matchMedia('(prefers-reduced-motion: reduce)').matches
  if (route.path === e.to) {
    // 已在同页：不重推路由（/ttk 不会重挂、q 深链不生效还污染 URL），只滚锚点
    if (e.hash) scrollToId(e.hash, rm)
    return
  }
  await router.push(e.q ? { path: e.to, query: { q: e.q } } : e.to)
  if (e.hash) scrollToId(e.hash, rm)
}
// 换词即归零游标：结果列表变了，旧下标可能悬空（Enter 空转、高亮丢失）
watch(kq, () => { ai.value = 0 })
// 游标可见性：方向键移出列表视口时把当前项滚回（nearest 不牵动页面滚动）
watch(ai, () => {
  document.getElementById('k-opt-' + ai.value)?.scrollIntoView({ block: 'nearest' })
})

function onGlobalKey(e) {
  if ((e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K')) {
    e.preventDefault() // Chrome 地址栏搜索等浏览器默认占位让位
    if (kDlg.value?.open) closeK()
    else openK()
  }
}

// 溢出提示：tabs 横向滚动承接时滚动条被藏掉，「右边还有 tab」必须另有可感信号。
// 纯 CSS 感知不了 scrollWidth>clientWidth，只能在尺寸/滚动变化时手动挂摘 .can-scroll
// （驱动右缘渐隐 mask）；滚到最右即摘除，渐隐不会一直压着最后一个 tab。
const tabsEl = ref(null)
let tabsRO = null
function syncTabsOverflow() {
  const el = tabsEl.value
  if (!el) return
  const more = el.scrollWidth - el.clientWidth > 1
  const atEnd = el.scrollLeft + el.clientWidth >= el.scrollWidth - 1
  el.classList.toggle('can-scroll', more && !atEnd)
}
onMounted(() => {
  window.addEventListener('keydown', onGlobalKey)
  const el = tabsEl.value
  if (!el) return
  syncTabsOverflow()
  tabsRO = new ResizeObserver(syncTabsOverflow)
  tabsRO.observe(el)
  // 逐个 tab 也观察：登录后「登录」换成用户名、字体晚加载改宽，都不动容器盒宽，
  // 只盯容器会漏刷新
  el.querySelectorAll('.tab').forEach((t) => tabsRO.observe(t))
  el.addEventListener('scroll', syncTabsOverflow, { passive: true })
})
onBeforeUnmount(() => {
  window.removeEventListener('keydown', onGlobalKey)
  if (tabsRO) tabsRO.disconnect()
  if (tabsEl.value) tabsEl.value.removeEventListener('scroll', syncTabsOverflow)
})
</script>

<template>
  <header class="site-topbar">
    <div class="wrap bar-inner">
      <router-link to="/" class="brand" aria-label="三角洲行动 · delta force hub 首页">
        <span class="brand-glyph" aria-hidden="true"></span>
        <span class="brand-mark">DELTA FORCE</span>
        <span class="brand-sub">delta force hub</span>
      </router-link>

      <nav class="tabs" ref="tabsEl" aria-label="站点导航">
        <router-link
          v-for="t in tabs"
          :key="t.to"
          :to="t.to"
          class="tab"
          :class="{ active: route.path === t.to }"
        >
          {{ t.label }}
        </router-link>
        <!-- 账号入口与主 tab 同样式：登录后显示用户名，未登录显示「登录」。
             用户名规则允许 16 字符（全中文常态比 4 个主 tab 加起来还宽），原样显示
             会把顶栏需求宽撑出 701~880px 长尾区间：tabs 被迫滚动、账号 tab 只露
             几个字。入口的可点价值高于完整展示价值 → 按宽截断（见 .acct-name），
             全名保留在 title（hover 可见）与 DOM 文本（读屏器不受 CSS 截断影响） -->
        <router-link
          to="/account"
          class="tab"
          :class="{ active: route.path === '/account' }"
          :title="user ? user.username : undefined"
        >
          <span class="acct-name">{{ user ? user.username : '登录' }}</span>
        </router-link>
      </nav>

      <!-- ⌘K 快捷跳转入口：刻意不占 .tab 类（smoke.mjs 断言 .site-topbar .tab 恰好 5 个）；
           命中区按 44px 下限给足，视觉保持小号快捷键 chips -->
      <button
        class="k-btn" type="button" aria-label="快速跳转"
        :title="isMac ? '快速跳转（⌘ K）' : '快速跳转（Ctrl K）'"
        @click="openK"
      >
        <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true">
          <circle cx="7" cy="7" r="4.6" fill="none" stroke="currentColor" stroke-width="1.6" />
          <path d="M10.4 10.4 13.5 13.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
        </svg>
        <span class="k-key">{{ isMac ? '⌘K' : 'Ctrl K' }}</span>
      </button>
    </div>

    <!-- 快捷跳转面板：dialog showModal 进 top-layer（免被页内 sticky 遮挡）；
         @click.self = 点背幕关闭（backdrop 点击落在 dialog 自身）；Esc 走原生 cancel -->
    <dialog ref="kDlg" class="k-dlg" aria-label="快速跳转" @click.self="closeK" @close="onDlgClose">
      <div class="k-row">
        <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
          <circle cx="7" cy="7" r="4.6" fill="none" stroke="currentColor" stroke-width="1.6" />
          <path d="M10.4 10.4 13.5 13.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
        </svg>
        <input
          ref="kIn" v-model="kq" class="k-in" type="search"
          aria-label="搜索跳转目标"
          placeholder="搜索页面 / 小节 / 枪械 / 口径…"
          role="combobox" aria-expanded="true" aria-controls="k-list"
          :aria-activedescendant="results.length ? 'k-opt-' + ai : undefined"
          @keydown="onInKey"
        >
      </div>
      <div id="k-list" class="k-list" role="listbox" aria-label="跳转目标">
        <!-- 空态给一条出路（通用原则）：说明匹配口径 + 引导清空看全部入口 -->
        <p v-if="!results.length" class="k-empty">
          没有匹配「{{ kq.trim() }}」的目标；试试枪械中文名（如 腾龙）或口径（如 5.7）。
        </p>
        <div
          v-for="(e, i) in results" :key="e.k" :id="'k-opt-' + i"
          class="k-opt" role="option" :aria-selected="i === ai" :class="{ on: i === ai }"
          @mouseenter="ai = i" @click="go(e)"
        >
          <span class="k-l">{{ e.label }}</span>
          <span class="k-h">{{ e.hint }}</span>
        </div>
      </div>
      <p class="k-foot">
        <span class="k-tip-key">↑↓ 选择 · ↵ 跳转 · Esc 关闭</span>
        <span class="k-tip-touch">点按目标跳转 · 点空白处关闭</span>
        <span v-if="moreN"> · 已收起 {{ moreN }} 条</span>
      </p>
    </dialog>

    <!-- hero 特效插槽（机制保留）：v2.2 起特效迁入首页 .site-head，此处不再注入内容 -->
    <div class="hero-slot">
      <slot name="hero-fx" />
    </div>
  </header>
</template>

<style scoped>
.site-topbar {
  position: relative;
  background: var(--bg2);
  border-bottom: 1px solid var(--line);
}
.bar-inner {
  position: relative;
  z-index: 2;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-4);
  height: 56px;
}
.brand {
  display: flex;
  flex: none; /* 不参与收缩：窄屏收缩压力全交给 .tabs（否则 DELTA FORCE 会被压折行） */
  align-items: center;
  gap: 10px;
  text-decoration: none;
  transition: transform var(--t-fast) var(--ease);
}
/* 品牌链接 hover：副标提亮一档（--faint → --dim），主标保持强文字色 */
.brand:hover .brand-sub { color: var(--dim); }
.brand:active { transform: translateY(1px); }
/* 品牌菱形标：与全站 ◆ / 菱形点位同一几何语言 */
.brand-glyph {
  flex: none;
  width: 8px;
  height: 8px;
  background: var(--accent);
  transform: rotate(45deg);
  /* 光晕色走 --accent-dim（.38）：原手写 rgba(45,212,191,.35) 是全组唯一游离的主色
     变体，3% 透明度差肉眼不可辨，收编后主色系只在 base.css 令牌段出现一次 */
  box-shadow: 0 0 10px var(--accent-dim);
}
.brand-mark {
  font-family: var(--mono);
  font-size: var(--fs-sm);
  font-weight: 700;
  letter-spacing: .22em;
  color: var(--tx-strong);
}
.brand-sub {
  font-family: var(--sans);
  font-size: var(--fs-xs);
  color: var(--faint);
  letter-spacing: .12em;
  transform: translateY(1px);
  transition: color var(--t-med) var(--ease);
}
.tabs {
  display: flex;
  align-self: stretch; /* 拉通顶栏全高：tab 触达区 44 → 56px，且 ::after 指示条
                           （bottom:-1px）贴住顶栏下边线，激活态与分隔线连续成一体 */
  /* 词距 28px = gap 16 + 两侧 padding 6×2（原 gap 24 + padding 2×2 同为 28，视觉不变）：
     把 8px 从 gap 挪进 .tab 盒内，是为了给内缩焦点环留位——见 .tab:focus-visible */
  gap: var(--sp-4);
  /* 溢出承接常开：顶栏未压缩自然需求宽约 664px（brand+gap+tabs），561~663px 一带
     曾经既放不下又没有滚动，页面被撑出横向滚动条、「登录」被裁出视口；任何宽度
     统一交给横向滚动承接（min-width:0 让 tabs 可在 brand 旁收缩出滚动空间）。
     滚动条本身藏掉（复用全站 pills 的 overflow-x 范式），溢出信号由 .can-scroll
     右缘渐隐承担 */
  min-width: 0;
  overflow-x: auto;
  /* 横滚吸附（手机常态：375px 屏 tabs 可用宽约 158px、需求 319px，必横滚）：手指
     松开后停在整词边界而不是半个字；proximity 只在靠近停点时吸附，快滑/滚到两端
     不被强拉，键盘聚焦的自动滚动也不受干扰；不支持的引擎忽略即自由滚动 */
  scroll-snap-type: x proximity;
  scrollbar-width: none;
  padding-bottom: 1px; /* 给 ::after 指示条的 -1px 底部溢出留位，防滚动容器裁剪 */
  /* 右锚定：加入 ⌘K 触发钮后 bar-inner 有三个子元素，space-between 会把 tabs
     摊到顶栏正中；margin-left:auto 让导航组（tabs + ⌘K）整体靠右，保持原布局语言 */
  margin-left: auto;
}
.tabs::-webkit-scrollbar { display: none; }
/* 右缘渐隐 = 「右边还有 tab」的唯一可感信号（滚动条已藏）；class 由 JS 按真实
   溢出挂摘（见 syncTabsOverflow），不溢出/已滚到最右时绝不出现 */
.tabs.can-scroll {
  -webkit-mask-image: linear-gradient(90deg, #000 0, #000 calc(100% - 24px), transparent 100%);
  mask-image: linear-gradient(90deg, #000 0, #000 calc(100% - 24px), transparent 100%);
}
/* 账号 tab 文字按宽截断：8em（fs-sm 13px ≈ 104px）= 中文 8 字 / 英文约 14 字符，
   超出显示省略号。span 作为 .tab（inline-flex）的 flex item 自动块化，ellipsis 生效；
   侧限 8em 是平衡点：12~16 字长名下 820px 级视口 tabs 不再溢出，727px 级溢出减半，
   而短名/「登录」不受影响（内容窄于上限时 max-width 不介入） */
.acct-name {
  max-width: 8em;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
/* 下划线式 tab：文字 + 底部指示条，与页内胶囊 chips 拉开层级 */
.tab {
  position: relative;
  display: inline-flex;
  align-items: center;
  flex: none; /* 横向滚动模式下不吃收缩，保持整词宽 */
  scroll-snap-align: start; /* 配 .tabs 的 proximity 吸附：停点 = 词左缘对齐容器左缘 */
  min-height: 44px; /* 触控行高下限（HIG 44pt）；.tabs 已拉通 56px 顶栏全高，实际行高即 56px */
  padding: 6px 6px; /* 左右 2→6：承接从 .tabs gap 挪来的 8px（词距不变），盒内给内缩焦点环留 4px 净距 */
  font-size: var(--fs-sm);
  color: var(--dim);
  text-decoration: none;
  letter-spacing: .05em;
  white-space: nowrap; /* 放不下时由 .tabs 横向滚动承接，绝不允许逐字折行 */
  transition: color var(--t-med) var(--ease), transform var(--t-fast) var(--ease);
}
/* 焦点环内缩：.tabs 是 overflow-x:auto 滚动容器（两轴都裁剪），.tab 又 stretch 填满
   56px 顶栏全高——全局焦点环 outline 2px + offset 2px 外扩 4px 必超出 .tabs 盒上下缘
   被裁、首/末 tab 左右缘同裁，键盘用户 Tab 到导航时只看到两条竖线。改画在盒内侧
   （-2px），上下离文字 >15px、左右离文字 4px（padding 6 − 环宽 2），环完整可见 */
.tab:focus-visible { outline-offset: -2px; }
.tab::after {
  content: "";
  position: absolute;
  left: 4px;  /* 两侧内缩 4px = 抵消 padding 2→6 的增量：指示条仍为「文字宽 + 4px」，与改前同宽 */
  right: 4px;
  bottom: -1px;
  height: 2px;
  background: var(--accent);
  transform: scaleX(0);
  transform-origin: left center;
  transition: transform var(--t-med) var(--ease), opacity var(--t-med) var(--ease);
}
.tab:hover { color: var(--tx); }
.tab:hover::after { transform: scaleX(1); opacity: .3; }
.tab.active { color: var(--accent); }
.tab.active::after { transform: scaleX(1); opacity: 1; }
/* 按下态：文字再提亮一档 + 整体下沉 1px + 指示条压低，触屏（无 hover）同样有「按实」反馈 */
.tab:active { color: var(--tx-strong); transform: translateY(1px); }
.tab:active::after { opacity: .15; }
/* 当前路由 tab 按下时保持主色文字与满亮指示条（选中态不被按下态覆盖） */
.tab.active:active { color: var(--accent); }
.tab.active:active::after { opacity: 1; }
/* 特效层容器：绝对定位不影响导航条布局；v2.2 起不再注入内容，机制保留 */
.hero-slot {
  position: absolute;
  inset: 0;
  pointer-events: none;
}
.hero-slot > :deep(*) {
  pointer-events: auto;
}

/* ===== ⌘K 触发钮：小号快捷键 chips 观感，命中区按 44px 触控下限给足 ===== */
.k-btn {
  flex: none;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  align-self: center;
  min-height: 44px; /* 触控垫层下限；视觉高度由内容决定（约 30px） */
  padding: 4px 10px;
  background: var(--card);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  color: var(--dim);
  cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease);
}
.k-btn:hover { color: var(--tx); border-color: var(--line-hover); }
/* 按下态与 hover 同档：触屏无 hover，按压即时可见（同 .tab 口径） */
.k-btn:active { color: var(--tx); border-color: var(--line-hover); }
.k-key {
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  letter-spacing: .08em;
  color: var(--faint);
}
.k-btn:hover .k-key,
.k-btn:active .k-key { color: var(--dim); }
/* 触屏没有键盘，快捷键字样失去意义：只留放大镜图标，点击仍可开面板 */
@media (hover: none) and (pointer: coarse) {
  .k-key { display: none; }
}

/* ===== 快捷跳转面板：dialog 在 top-layer，margin 即定位（命令面板落上 1/8 处）。
   面板属「浮在内容之上」——用最高阴影档 + 实底面板色（契约口径） ===== */
.k-dlg {
  margin: 12vh auto auto;
  width: min(560px, calc(100vw - 32px));
  padding: 0;
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  background: var(--panel-solid);
  color: var(--tx);
  box-shadow: var(--shadow-lg);
}
.k-dlg::backdrop { background: var(--scrim); }
/* 开合过渡（渐进增强）：@starting-style 提供「打开」的起始帧，display / overlay 走
   allow-discrete 让「关闭」（display:none + 退出 top-layer）也先播完淡出再卸层。
   不支持的引擎整块跳过 = 瞬开瞬关，功能完整 */
@supports (transition: opacity 0.25s allow-discrete) {
  .k-dlg {
    opacity: 0;
    transition: opacity var(--t-panel) var(--ease),
      display var(--t-panel) allow-discrete, overlay var(--t-panel) allow-discrete;
  }
  .k-dlg[open] { opacity: 1; }
  .k-dlg::backdrop {
    opacity: 0;
    transition: opacity var(--t-panel) var(--ease),
      display var(--t-panel) allow-discrete, overlay var(--t-panel) allow-discrete;
  }
  .k-dlg[open]::backdrop { opacity: 1; }
  @starting-style {
    .k-dlg[open] { opacity: 0; }
    .k-dlg[open]::backdrop { opacity: 0; }
  }
}
.k-row {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding: 4px var(--sp-4);
  border-bottom: 1px solid var(--line2);
}
.k-row svg { flex: none; color: var(--faint); }
/* 输入区即焦点所在（打开即聚焦、仅此一个可键入控件），以光标为可见焦点指示，
   不再叠全局 :focus-visible 外框 */
.k-in {
  flex: 1;
  min-width: 0;
  background: none;
  border: 0;
  outline: none;
  color: var(--tx-strong);
  font-size: var(--fs-lg);
  padding: 10px 0;
}
.k-in::placeholder { color: var(--faint); }
/* overscroll contain：showModal 挡交互不挡滚动——结果列表滚到端点后继续滚，
   滚动链会把背后的页面带走（背幕下的内容悄悄换位，关闭面板后突兀）；列表自身
   没有别的滚动出口，切断链无副作用 */
.k-list { max-height: min(46vh, 400px); overflow-y: auto; overscroll-behavior: contain; padding: var(--sp-2); }
.k-opt {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-3);
  padding: 8px 10px;
  border-radius: var(--radius-sm);
  cursor: pointer;
  transition: background var(--t-fast) var(--ease);
}
/* 触屏命中区：粗指针下加大真实 padding（≈34 → 46px，过 44 下限）；列表项
   上下相邻，::before 外扩垫层会互相叠压，故与 .nf-link 同口径用真实尺寸 */
@media (pointer: coarse) {
  .k-opt { padding: 12px 10px; }
}
/* 选中面用强调底令牌（唯一强调色系）；文字保持正文/强文字色，不用 --accent 作字色 */
.k-opt.on { background: var(--accent-bg); }
/* 触屏按压面色：鼠标路径的回声是 hover→.on 选中面（@mouseenter 同步游标），触屏
   无 hover，点按瞬间 :active 面色是唯一回声（通用原则：hover 独享信息须有触屏等价物）。
   源序在 .on 之后：键盘/鼠标路径按住已选中项时以更强的 lift 面覆盖选中面 */
.k-opt:active { background: var(--lift); }
.k-l {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--tx);
}
.k-opt.on .k-l { color: var(--tx-strong); }
.k-h {
  flex: none;
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  letter-spacing: .06em;
  color: var(--faint);
}
.k-opt.on .k-h { color: var(--dim); }
.k-empty { padding: var(--sp-4) 10px; font-size: var(--fs-sm); color: var(--dim); }
.k-foot {
  padding: 8px var(--sp-4);
  border-top: 1px solid var(--line2);
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  letter-spacing: .05em;
  color: var(--faint);
}
/* 操作提示按输入介质分流：键盘提示（↑↓/↵/Esc）对触屏是无效指令——触屏路径
   已隐藏 ⌘K 字样（.k-key 同款断点），此处一并切换为触屏可执行的动作指引，
   「关闭出路」在两种介质下都成立（键盘 Esc / 点背幕） */
.k-tip-touch { display: none; }
@media (hover: none) and (pointer: coarse) {
  .k-tip-key { display: none; }
  .k-tip-touch { display: inline; }
}

/* 窄屏（≤700px）：brand 收缩（藏副标、字距减半）+ tabs gap 收窄。门槛不是拍脑袋：
   未压缩时顶栏自然需求宽约 672px，旧门槛 560px 之上的 561~671px 一带既放不下又
   无承接（横向滚动承接旧只在 ≤560px 生效）；直接抬过 672px 需求线（+28px 余量），
   让这一带压缩后全部 tab 无需滚动即可见，彻底消灭「无承接区间」。
   gap 16→8 + .tab 两侧 padding 6：词距 20px 与改前（gap 16 + padding 2×2）相同 */
@media (max-width: 700px) {
  .brand-sub { display: none; }
  .brand-mark { letter-spacing: .12em; }
  .tabs { gap: var(--sp-2); }
}
@media (prefers-reduced-motion: reduce) {
  .tab, .tab::after, .brand, .brand-sub { transition: none; }
  .k-btn, .k-opt { transition: none; }
  /* 面板开合降级为瞬开瞬关（opacity 声明保留：关闭态本就 display:none） */
  .k-dlg, .k-dlg::backdrop { transition: none; }
}
</style>
