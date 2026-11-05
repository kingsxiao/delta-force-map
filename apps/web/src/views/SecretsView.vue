<script setup>
/* SecretsView — 每日地图密码（零号大坝 / 长弓溪谷 / 巴克什 / 航天基地 / 潮汐监狱 / AZ3）
   数据：public/secrets/secrets.json（server/secrets/secrets.mjs 落盘；主源腾讯
   官方 AMS dfm/center.day.secret——WeGame 三角洲助手同款免登录接口，兜底
   moligod 镜像；契约 shared/API.md §1.4）。密码北京时间每天 0 点轮换、日期
   即版本（8 位 YYYYMMDD），位置图为官方 WeGame 助手静态资源、本地打包于
   public/secrets/img/（season 更新可能换图，届时由服务端重新导出替换）。
   刷新：同源 SSE（secrets 事件只在内容变化时广播，版本门控静默重拉）+
   分档轮询兜底——数据链复用 ../composables/useSnapshotFeed.js。
   新鲜度口径与分钟级行情页不同：日更数据没有「10 分钟变灰」一说，只有
   「快照日期 ≠ 北京今天」才变灰提示（0 点轮换后服务端 30 分钟内自然追上）。 */
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import SkeletonView from '../components/SkeletonView.vue'
import { imgReady, hideImg } from '../composables/imgReady'
import { useSnapshotFeed } from '../composables/useSnapshotFeed'
import { useReveal } from '../composables/useReveal'

const rootEl = ref(null)
const { observeRoot } = useReveal()
let prevTitle = ''

const {
  market, loadState, loadError, refreshing,
  load,
} = useSnapshotFeed(`${import.meta.env.BASE_URL}secrets/secrets.json`, {
  events: ['secrets'],
  syntaxError: '每日密码数据格式异常，请稍后重试',
  successTip: false, // 日更数据无「已更新至 X」回声位，日期本身就是版本展示
})

const items = computed(() => market.value?.items || [])

/* 位置图地址：快照存相对路径，拼接 BASE_URL 前缀（子路径托管下不 404；
   模板表达式不能出现 import.meta，收进 script） */
const imgSrc = (it) => `${import.meta.env.BASE_URL}${it.img}`

/* 北京今天（UTC+8 直加，不依赖设备时区口径）：与快照 date 不同 = 今日密码
   尚未抓到，live-dot 变灰 + stale-tip 提示，绝不冒充「今日」 */
function beijingToday() {
  const bj = new Date(Date.now() + 8 * 3600 * 1000)
  const p = (n) => String(n).padStart(2, '0')
  return `${bj.getUTCFullYear()}-${p(bj.getUTCMonth() + 1)}-${p(bj.getUTCDate())}`
}
const isStale = computed(() => !!market.value && market.value.date !== beijingToday())

/* 更新时刻展示：fetchedAt 的北京墙钟 HH:mm（0 点轮换后应为 00:0x） */
const updatedLabel = computed(() => {
  const t = Date.parse(market.value?.fetchedAt || '')
  if (!Number.isFinite(t)) return ''
  const bj = new Date(t + 8 * 3600 * 1000)
  const p = (n) => String(n).padStart(2, '0')
  return `${p(bj.getUTCHours())}:${p(bj.getUTCMinutes())}`
})
const SOURCE_LABEL = { 'official-ams': '官方接口', 'moligod-mirror': '官方接口 · 镜像源' }

/* ---------- 一键复制：clipboard API 优先，http 直连部署（IP:8080 明文，无
   secure context）没有 navigator.clipboard——execCommand 隐藏 textarea 兜底；
   成功回声 2s（.sec-copy「已复制」态） ---------- */
const copiedId = ref(null)
let copiedTimer = null
async function copySecret(item) {
  const text = item.secret
  try {
    await navigator.clipboard.writeText(text)
  } catch {
    const ta = document.createElement('textarea')
    ta.value = text
    ta.setAttribute('readonly', '')
    ta.style.position = 'fixed'
    ta.style.opacity = '0'
    document.body.appendChild(ta)
    ta.select()
    try {
      document.execCommand('copy')
    } finally {
      ta.remove()
    }
  }
  copiedId.value = item.mapId
  if (copiedTimer) clearTimeout(copiedTimer)
  copiedTimer = setTimeout(() => { copiedId.value = null }, 2000)
}

/* 入场级联时序：四态互切走 <Transition mode="out-in">，ready 根节点在旧态
   离场结束后才插入 DOM——nextTick 批次那一刻还找不到 .reveal-group（本页无
   静默换根路径，进场合子在 onStateRootEnter 补跑，与 AmmoMarketView 同口径） */
function onStateRootEnter() {
  if (loadState.value !== 'ready') return
  observeRoot(rootEl.value)
}

onMounted(() => {
  prevTitle = document.title
  document.title = '三角洲行动 · 每日地图密码'
})
onBeforeUnmount(() => {
  document.title = prevTitle
  if (copiedTimer) clearTimeout(copiedTimer)
})
</script>

<template>
  <div ref="rootEl" class="wrap page">
    <header class="compact-head">
      <h1>每日密码 <span class="live-dot" :class="{ stale: isStale }" aria-hidden="true"></span></h1>
      <p v-if="market" class="meta" :title="`数据版本 ${market.version} · ${market.source}`">
        {{ market.date }} 密码 · {{ items.length }} 张图 · 更新于 {{ updatedLabel }}
        <template v-if="SOURCE_LABEL[market.source]"> · {{ SOURCE_LABEL[market.source] }}</template>
      </p>
    </header>

    <!-- 日更口径的「过期」：快照日期不是北京今天（0 点轮换后服务端下一轮自然追上） -->
    <Transition name="swap">
      <p v-if="isStale && market" class="state-tip stale-tip" role="status">
        今日（{{ beijingToday() }}）密码尚未更新，当前显示 {{ market.date }} 的密码，稍后会自动刷新。
      </p>
    </Transition>

    <Transition name="swap" mode="out-in" @after-enter="onStateRootEnter">
      <div v-if="loadState === 'loading'" key="loading" class="state-root sk-hold">
        <SkeletonView variant="hero" />
      </div>
      <div v-else-if="loadState === 'empty'" key="empty" class="state-root">
        <div class="state-card">
          <p>还没有每日密码数据。</p>
          <p class="dim">快照正在准备中，稍后再来看看。</p>
          <button class="retry" :disabled="refreshing" @click="load()">重试</button>
        </div>
      </div>
      <div v-else-if="loadState === 'error'" key="error" class="state-root">
        <div class="state-card">
          <p>每日密码加载失败：{{ loadError }}</p>
          <button class="retry" :disabled="refreshing" @click="load()">重试</button>
        </div>
      </div>
      <div v-else key="ready" class="state-root">
        <!-- 密码卡：点密码即复制（命中区整卡头部 44px+）；位置图官方资源本地打包，
             loading=lazy 分摊流量（单张 ~300KB）。级联入场走 .reveal-group 容器观察
             （base.css §7.3：子项不挂 .reveal，按 --ri 错峰） -->
        <section class="sec-grid reveal-group" aria-label="各地图今日密码">
          <article
            v-for="(it, idx) in items" :key="it.mapId"
            class="sec-card" :style="{ '--ri': idx }"
          >
            <div class="sec-head">
              <h2 class="sec-map">{{ it.mapName }}</h2>
              <button
                class="sec-copy" type="button"
                :class="{ done: copiedId === it.mapId }"
                :aria-label="`复制${it.mapName}密码 ${it.secret}`"
                :title="copiedId === it.mapId ? '已复制' : '点击复制'"
                @click="copySecret(it)"
              >
                <span class="sec-code">{{ it.secret }}</span>
                <span class="sec-copy-hint" aria-hidden="true">{{ copiedId === it.mapId ? '已复制' : '复制' }}</span>
              </button>
            </div>
            <figure v-if="it.img" class="sec-fig">
              <img
                :src="imgSrc(it)"
                :alt="`${it.mapName}每日密码位置图`"
                loading="lazy" decoding="async"
                @load="imgReady" @error="hideImg"
              >
            </figure>
          </article>
        </section>

        <footer class="sec-foot">
          <p>密码门每日 0 点（北京时间）轮换，进入对局后在对应密码门输入即可开启；点击密码可快速复制。</p>
          <p class="dim">数据来源：腾讯官方接口（WeGame 三角洲助手同款），位置图为官方助手素材。</p>
        </footer>
      </div>
    </Transition>
  </div>
</template>

<style scoped>
/* 卡片栅格：桌面 3 列 / 中屏 2 列 / 窄屏单列（auto-fill 自适应，与全站栅格同语汇） */
.sec-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
  gap: var(--sp-4);
}

.sec-card {
  background: var(--card);
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  overflow: hidden;
  transition: border-color var(--t-med) var(--ease);
}
.sec-card:hover { border-color: var(--line-hover); }

.sec-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--sp-3);
  padding: var(--sp-4);
  border-bottom: 1px solid var(--line);
}
.sec-map {
  margin: 0;
  font-size: var(--fs-lg);
  color: var(--tx-strong);
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* 密码即按钮：大号 mono 数字，触控命中区 ≥44px；复制态语义色回声 */
.sec-copy {
  flex: none;
  display: inline-flex;
  align-items: baseline;
  gap: var(--sp-2);
  padding: 6px 12px;
  min-height: 44px;
  align-items: center;
  background: var(--lift, var(--bg2));
  border: 1px solid var(--line);
  border-radius: var(--radius);
  cursor: pointer;
  transition: border-color var(--t-fast) var(--ease), color var(--t-fast) var(--ease);
}
.sec-copy:hover { border-color: var(--line-hover); }
.sec-copy:active { transform: translateY(1px); }
.sec-code {
  font-family: var(--mono);
  font-size: var(--fs-xl);
  font-weight: 700;
  letter-spacing: .14em;
  color: var(--accent);
  font-variant-numeric: tabular-nums;
}
.sec-copy-hint {
  font-size: var(--fs-2xs);
  color: var(--faint);
  min-width: 3em;
  text-align: right;
}
.sec-copy.done { border-color: var(--accent); }
.sec-copy.done .sec-copy-hint { color: var(--accent); }

/* 位置图：占位底（imgReady 铺底、到位淡入，motion.css「图片占位」段口径） */
.sec-fig {
  margin: 0;
  line-height: 0;
}
.sec-fig img {
  width: 100%;
  height: auto;
  display: block;
  opacity: 0;
  transition: opacity var(--t-slow) var(--ease);
}
.sec-fig img.ld { opacity: 1; }

.sec-foot {
  margin-top: var(--sp-5);
  color: var(--dim);
  font-size: var(--fs-sm);
}
.sec-foot p { margin: 0 0 var(--sp-2); }
.sec-foot .dim { color: var(--faint); }

@media (max-width: 640px) {
  .sec-grid { grid-template-columns: 1fr; }
  /* 窄屏卡片头部可能挤：地图名让位换行，密码整行右贴 */
  .sec-head { flex-wrap: wrap; }
  .sec-copy { margin-left: auto; }
}
@media (prefers-reduced-motion: reduce) {
  .sec-card, .sec-copy, .sec-fig img { transition: none; }
}
</style>
