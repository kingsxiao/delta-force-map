/* ============================================================
   useSnapshotFeed.js — 快照数据链 composable（弹药 / 雷达 / 制造三视图共用）
   ------------------------------------------------------------
   收编三页各自约 120 行的同构链路（模式同 useStars / usePositions 的
   composables 抽法）：loadSeq 并发守卫 + load 四分支（404 空态 / 非 2xx
   throw / 校验失败 / ready）+ SSE 接线（hello 与具名事件同为版本门控的
   轻量 ping：版本前进才重新 GET）+ 分档轮询（off 30min / on 5min /
   其余 60s，逐轮重排随通道状态切换）+ 回前台按变灰阈值补拉 + 卸载清理。
   页级差异以选项注入：
     emptyOn404       首载 404 视为「快照尚未生成」空态而非错误（弹药页）
     accept/onInvalid 快照合法性判定与失败处置（弹药页结构非法 → 整页
                      error；雷达 / 制造 items 为空 → 空态）
     silentNeedsData  无数据时把 silent 降级为整页重载（弹药页语义；
                      雷达 / 制造保持 silent，空 / 错态卡片不闪骨架）
     successTip       静默刷新成功是否回声「已更新至 X」（制造页无回声）
     staleDotMin      回前台补拉的变灰阈值（默认按快照 source 走
                      @shared/js/marketMeta.js staleness 分档）
     onLoaded         ready 后回调（价格闪变 diff / 通知去抖 / DOM 补挂）
   行为约定（三页既有口径，重构不得回退）：SSE 事件是轻量 ping，版本未
   前进不打全量拉取；轮询仅页面可见时发起，后台不空耗；非 2xx 一律
   throw（手动刷新遇失败有反馈）；静默失败保留旧数据只给一行提示。
   协商缓存：整包 200 后写入 snapshotCache 并记 fingerprint，此后重询
   携 If-None-Match——部署形态（server.mjs 以 fingerprint 为 ETag）内容
   未变即回 304，直接用会话快照（免掉约 400KB × 每分钟轮询的整包下发）。
   ============================================================ */
import { onMounted, onUnmounted, ref } from 'vue'
import { formatVersionLabel, staleness } from '@shared/js/marketMeta.js'
import { liveChannelUrl, isLocalHttpHost, createLiveChannel } from '@shared/js/liveChannel.js'
import { peekSnapshot, storeSnapshot, snapshotEtag } from './snapshotCache.js'

export function useSnapshotFeed(url, options = {}) {
  const {
    /** SSE 需透传的具名事件（market / radar / craft）；hello 由通道恒发，同口径处理 */
    events = [],
    /** 首载 404 → 空态（「快照尚未生成」）；false 时 404 走非 2xx throw */
    emptyOn404 = false,
    /** 快照合法性判定；false 时按 onInvalid 处置 */
    accept = (j) => Array.isArray(j?.items) && j.items.length > 0,
    /** accept 为假的处置：'empty' 置空态 | 'error' throw（整页报错） */
    onInvalid = 'empty',
    /** onInvalid='error' 时的报错文案 */
    invalidError = '数据格式异常',
    /** 快照 JSON 解析失败（SyntaxError）的整页错误文案 */
    syntaxError = '行情数据格式异常，请稍后重试',
    /** 无数据时 silent 降级为整页重载（弹药页语义；默认保持 silent） */
    silentNeedsData = false,
    /** 静默刷新成功回声「已更新至 X」——仅手动刷新或版本前进时出声 */
    successTip = true,
    /** 回前台补拉的变灰阈值（分钟）；默认按快照 source 分档（staleness） */
    staleDotMin = () => staleness(market.value?.source).staleDotMin,
    /** ready 后回调：(json, { prev, silent })——价格闪变 diff / 通知去抖等 */
    onLoaded,
  } = options

  const market = ref(null)
  const loadState = ref('loading') // loading | ready | empty | error
  const loadError = ref('')
  const refreshing = ref(false)
  const refreshTip = ref('')
  const refreshTipKind = ref('ok') // ok=成功回声（4s 自动消失）/ warn=失败提示常驻到下次刷新
  const nowTs = ref(Date.now())
  const liveChannel = ref('off') // off(环境不适用) | connecting | on | down

  let tipTimer = null
  let pollTimer = null
  let live = null
  /* 请求序号：SSE 事件 / 轮询 / 手动刷新并发打同一 URL 时只认最新一次的响应，
     先发慢到的旧快照不覆盖新快照（fetch 不取消、响应落地即丢弃） */
  let loadSeq = 0

  async function load(opts = {}) {
    const seq = ++loadSeq
    const silent = silentNeedsData ? !!(opts.silent && market.value) : !!opts.silent
    /* 「进行中」对 silent 与整页请求一致置位：空/错态的重试按钮借此
       :disabled 防连点空转；auto 区分轮询/SSE/回前台补拉与用户手点——
       成功提示的出不出声由它决定。弹药页语义（silentNeedsData）：非
       silent 一律整页重载（错态重试回骨架、无数据时的静默补拉也自然
       降级为整页重载）；雷达 / 制造保持当前状态，错态卡片不闪骨架 */
    refreshing.value = true
    if (!silent && silentNeedsData) loadState.value = 'loading'
    const prev = market.value
    try {
      /* no-store 直连（勿用 ?t= 造唯一 URL：no-cache 响应会写进 HTTP 缓存但该
         URL 永不再现，纯死缓存写放大）。会话缓存有指纹时带 If-None-Match，
         部署形态内容未变即回 304（no-store 下 304 原样上抛，不走 HTTP 缓存） */
      const headers = {}
      const etag = snapshotEtag(url)
      if (etag) headers['If-None-Match'] = etag
      const res = await fetch(url, { cache: 'no-store', headers })
      if (seq !== loadSeq) return
      let json
      if (res.status === 304) {
        /* 命中协商缓存：内容与本地一致，直接用会话快照——market 引用未变、
           版本未前进，diff 与「已更新至」回声天然为空 */
        json = peekSnapshot(url)
        if (!json) throw new Error(`HTTP ${res.status}`) // 无缓存却 304（异常服务）：按错误处理
      } else {
        if (res.status === 404 && emptyOn404) {
          // 静默刷新遇 404 = 快照刚被撤走：如实报错；首载则视作「尚未生成」
          if (silent) throw new Error('快照不存在（HTTP 404）')
          loadState.value = 'empty'
          return
        }
        /* 非 2xx 一律 throw：原先 silent 分支把失败整个吞掉，手点「刷新」
           遇非 2xx 无任何提示 */
        if (!res.ok) throw new Error(`HTTP ${res.status}`)
        json = await res.json()
        if (seq !== loadSeq) return
        storeSnapshot(url, json)
      }
      if (!accept(json)) {
        if (onInvalid === 'error') throw new Error(invalidError)
        loadState.value = 'empty'
        refreshTip.value = ''
        return
      }
      market.value = json
      loadState.value = 'ready'
      onLoaded?.(json, { prev, silent })
      /* 自动轮询/SSE 触发的刷新只在版本真的前进时提示——纯静态环境快照永不
         变化，每分钟闪一次「已更新至 <旧版本>」是在误导；手动点击仍给反馈 */
      if (silent && successTip && (!opts.auto || json.version !== prev?.version)) {
        refreshTip.value = `已更新至 ${formatVersionLabel(json.version)}`
        refreshTipKind.value = 'ok'
        if (tipTimer) clearTimeout(tipTimer)
        tipTimer = setTimeout(() => { refreshTip.value = '' }, 4000)
      } else {
        refreshTip.value = ''
      }
    } catch (e) {
      if (seq !== loadSeq) return // 旧请求的失败不覆盖新请求的状态
      if (silent) {
        // 静默失败：保留旧数据，只在控制条下给一行提示，不整页报错
        refreshTip.value = '刷新失败，仍显示之前的数据'
        refreshTipKind.value = 'warn'
      } else {
        loadError.value = e instanceof SyntaxError ? syntaxError : e.message
        loadState.value = 'error'
      }
    } finally {
      if (seq === loadSeq) refreshing.value = false
    }
  }

  /* ---------- 实时通道（SSE）：本地 vite 工具链连独立 live 服务（8787），
     部署形态连同源 /events；端点判定与断线退避重探在 shared/js/liveChannel.js。
     事件（含 hello）是轻量 ping（API.md §2「版本前进才重新 GET」）：服务端
     内容未变也逐轮广播，版本与当前快照相同就不打全量拉取 */
  const LIVE_SSE_URL = liveChannelUrl(location)
  function connectLive() {
    if (!LIVE_SSE_URL) return
    live = createLiveChannel({
      url: LIVE_SSE_URL,
      events,
      isLocal: () => isLocalHttpHost(location),
      onState: (s) => { liveChannel.value = s },
      onEvent: (t, data) => {
        try {
          const meta = JSON.parse(data)
          if (market.value && meta.version && meta.version !== market.value.version) {
            load({ silent: true, auto: true })
          }
        } catch { /* 事件数据异常只标记连接态，不影响链路 */ }
      },
    })
    live.start()
  }

  /* ---------- 轮询节奏按环境分档：live 通道不适用（https/file 纯静态部署，
     快照永不变化）时退回 30 分钟，避免 60s×缓存穿透对静态主机打无效流量
     （快照约 400KB，60s 轮 ≈ 23MB/小时/标签页）；SSE 已连（on）时服务端
     ~61s 推一次，退 5 分钟级兜底（防连接假活丢更新，也不再与推送各打一半
     重复流量）；connecting/down 保持 60s 快轮（重连期间推送缺席，轮询是
     唯一更新通道）。逐轮重排而非固定 setInterval，节奏可随通道状态切换 */
  function schedulePoll() {
    const delay = liveChannel.value === 'off' ? 30 * 60 * 1000
      : liveChannel.value === 'on' ? 5 * 60 * 1000
      : 60 * 1000
    pollTimer = setTimeout(() => {
      // 后台标签不空耗请求（跳过的轮询由回前台补拉接住）；首载失败 / 空
      // （market 恒 null）时轮询也重试，纯静态部署错误态可自动恢复
      if (!document.hidden) {
        nowTs.value = Date.now()
        if (market.value || loadState.value === 'error' || loadState.value === 'empty') {
          load({ silent: true, auto: true })
        }
      }
      schedulePoll()
    }, delay)
  }

  /* ---------- 回前台补拉：后台期间轮询的可见检查会跳过拉取，切回最坏要
     等下个周期（off 档 30min）；数据龄已过变灰阈值就直接补一次，不等
     tick。首载失败 / 空的页面回前台同样补一次自动恢复 */
  function onVisibility() {
    if (document.visibilityState !== 'visible') return
    nowTs.value = Date.now() // 先校正数据年龄，下面的阈值判断用的才是新值
    if (!market.value) {
      if (loadState.value === 'error' || loadState.value === 'empty') load({ silent: true, auto: true })
      return
    }
    const t = Date.parse(market.value.fetchedAt)
    const ageMin = Number.isFinite(t) ? (nowTs.value - t) / 60000 : null
    if (ageMin != null && ageMin > staleDotMin()) {
      load({ silent: true, auto: true })
    }
  }

  onMounted(() => {
    load()
    connectLive() // 本地 live 服务在跑时走 SSE（≤5s）；不在 / 不适用则轮询兜底
    schedulePoll()
    document.addEventListener('visibilitychange', onVisibility)
  })
  onUnmounted(() => {
    document.removeEventListener('visibilitychange', onVisibility)
    clearTimeout(pollTimer)
    if (tipTimer) clearTimeout(tipTimer) // 成功回声定时器：不摘会在卸载后空写 ref
    if (live) live.stop()
  })

  return { market, loadState, loadError, refreshing, refreshTip, refreshTipKind, nowTs, liveChannel, load }
}
