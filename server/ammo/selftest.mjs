/* ============================================================
   selftest.mjs — 子弹行情刷新链路离线自测（node 直接运行，零 npm 依赖）
   ------------------------------------------------------------
   全程不打外网：上游 moligod / kkrb 用注入 globalThis.fetch 的桩替代
   （按 URL 分流，含裸 gzip 响应与 kkrb 三步会话 cookie）；监听一律走
   127.0.0.1 + 临时端口（port 0）。覆盖：
     ① 跨年补年 / 时间键规则（moligod-client 纯函数）
     ② catalog → kkrb 形状适配 + full 模式铺缓存 + fast 模式 0 次 history
     ③ auto 模式只补过期/缺失曲线；fast 缺缓存判「数据不足」绝不补发
     ④ 端到端 analyze：信号值域 / P25≤P75 / 构造 BUY·SELL 命中
     ⑤ notify-policy：首次立即报 / 同信号冷却 / 切换需 streak≥2 确认 /
        冷却到期 / BUY 深跌重报（单轮跳变 + 渐进阴跌按累计跌幅）
     ⑥ fetchOnce：指纹门槛（变化才写、同指纹静默、5min 心跳）+ source 字段
        + dist 联动 + writeSnapshotPair 双写助手
     ⑥b joinOfficialAnchor：锚缺失/坏档静默跳过 + 正常 join（official 挂锚、
        dev 按本快照现价现算、joined 计有效锚条数）
     ⑦ 主源故障自动回落 kkrb（兜底分支：重试 3 次、来源如实切换、旧口径兼容）
     ⑧ 留档 ≥10min 门槛 + 超 7 天 / 超 1000 份清理
     ⑨ 并发读写原子性（写盘全程读方 JSON.parse 不炸、无 .tmp 残留）
     ⑨b 并发写者共写同一目标（违反「只跑一个写盘者」时的安全网）
     ⑩ SSE：连接即收 event:hello、落盘广播 event:market（wire 格式断言，
        127.0.0.1 临时端口）；--no-notify 下 state 仍全量记录（防恢复爆发）
     ⑩b live kkrb 兜底状态机：moligod 失败→kkrb 降档节奏服务→第 3 轮探活
        切回（探活轮不回落 kkrb；注入缩短的节奏参数多轮驱动）
     ⑩c live 双源失败指数退避：起点起步、连败 ×2 增长、cap 封顶不再翻倍
     ⑪ 页面纯逻辑（src/views/ammo/marketMeta.js）：版本双格式 / 阈值分档 /
        实时通道端点（本地 8787 / 同源 /events / file 不可用）/ 过期文案
        分钟·小时·天分档（纯静态部署的如实标注分支）
     ⑫ 页面纯逻辑（src/views/ammo/sellEta.js）：预计卖出——历史到达历时 /
        日内节律 / 时钟标签 / 通知文案（样本门槛）
     ⑬ server.mjs 同源部署服务：静态托管 + 缓存头 + SSE·health 复用 + 防穿越
        + 雷达/特勤处落盘广播 event:radar / event:craft（注入桩，不打外网）
   可选 --online：追加真实上游连通性检查（默认跳过，保证离线可跑）。
   全部通过 exit 0；任何失败把原因写 stderr 后 exit 1。
   用法：node server/ammo/selftest.mjs [--online]
   ============================================================ */
import { mkdtemp, mkdir, readFile, writeFile, readdir, utimes, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import http from 'node:http'
import { gzipSync } from 'node:zlib'

import {
  inferYear, historyTimeToKey, getSnapshot, primeCurveCache, clearCurveCache, curveCacheStats,
  CURVE_TTL_MS, beijingParts,
} from './moligod-client.mjs'
import { fetchOnce, writeJsonAtomic, writeSnapshotPair, joinOfficialAnchor, HEARTBEAT_MS } from './fetch-once.mjs'
import { judgeSignals, emptyState, POLICY, buyLine, sellLine } from '../../shared/js/notify-policy.js'
import { analyzeItem, analyzeMarket } from './analyze.mjs'
import { createLiveServer } from './live.mjs'
import { createSiteServer } from '../server.mjs'
import {
  formatVersionLabel, staleness, sourceLabel, liveChannelUrl, staleTipText,
} from '../../shared/js/marketMeta.js'
import {
  hourlyProfile, reachEpisodes, predictSellEta, fmtHours, fmtPeak,
  dayTradeEta, isDayTradeItem, DAY_TRADE_MAX_H, DAY_TRADE_MIN_NET_PCT, DAY_TRADE_MIN_EPISODES,
} from '../../shared/js/sellEta.js'

const ONLINE = process.argv.includes('--online')
const pad2 = (n) => String(n).padStart(2, '0')

/* ---------- 断言与用例框架 ---------- */
function assert(cond, msg) {
  if (!cond) throw new Error(msg)
}
const checks = []
const check = (name, fn) => checks.push([name, fn])

/* ---------- fixture：moligod / kkrb 上游形状 ---------- */
const NAMES = Array.from({ length: 55 }, (_, i) => `测试弹${i}号`)
const DAY_KEY = '2026-10-13'
const LAST_UPDATE = '10:18:00.000'

/** 北京墙钟 'MM-DD HH:mm'（history 的 time 无年份，fixture 贴着 now 生成） */
function bjTimeStr(date) {
  const p = beijingParts(date)
  return `${pad2(p.month)}-${pad2(p.day)} ${pad2(p.hour)}:${pad2(p.minute)}`
}

/** 168 个小时级 'YYYYMMDDHHmm' 键（kkrb 形状 priceCurve 用） */
function hourlyKeys(n = 168) {
  const keys = []
  for (let i = n - 1; i >= 0; i--) {
    const p = beijingParts(new Date(Date.now() - i * 3600 * 1000))
    keys.push(`${p.year}${pad2(p.month)}${pad2(p.day)}${pad2(p.hour)}${pad2(p.minute)}`)
  }
  return keys
}

/**
 * 168 个小时点的曲线 fixture。tailPrice 控制末点价格（构造 BUY/SELL 用）。
 * 返回 moligod history 形状 { status:'ok', data:[{time,avg,min,max,last}] }
 */
function historyFixture(basePrice = 100, tailPrice = null) {
  const now = Date.now()
  const data = []
  for (let i = 167; i >= 0; i--) {
    const price = i === 0 && tailPrice != null ? tailPrice : basePrice
    data.push({ time: bjTimeStr(new Date(now - i * 3600 * 1000)), avg: price, min: price, max: price, last: price })
  }
  return { status: 'ok', data }
}

/**
 * 按价格函数逐点生成的曲线 fixture（i=0 最旧 … 167 最新）。
 * 用于构造 v2 信号形态（见 analyze.mjs 头注的回测口径）：
 *   · v2 BUY：高位体制 → ≥48h 前崩到低位 → 底部小周期震荡缓升（末点 74，
 *     处全周下 1/5、离底 5.7%、低点 47h 前、48h 斜率微正）
 *   · v2 SELL：60→160 爬升后高位横盘（rank=1.0 且 48h 斜率≈0，动能走弱）
 *   · 接飞刀：全周期线性阴跌（rank 贴 0、幻影利差巨大——旧口径会误报 BUY）
 */
function curveFnFixture(fn) {
  const now = Date.now()
  const data = []
  for (let i = 167; i >= 0; i--) {
    const price = fn(167 - i)
    data.push({ time: bjTimeStr(new Date(now - i * 3600 * 1000)), avg: price, min: price, max: price, last: price })
  }
  return { status: 'ok', data }
}
/** v2 BUY 形态：0..119 高位 120；120 崩至 70；其后底噪小周期缓升（末点 74） */
const V2_BUY_CURVE = (i) => {
  if (i < 120) return 120
  const k = i - 120
  const base = 70 + Math.floor(k / 12)
  return k % 2 ? base + 1 : base + 12
}
/** v2 SELL 形态：0..119 线性爬升 60→160；其后高位横盘 ±0.5 */
const V2_SELL_CURVE = (i) => (i < 120 ? 60 + (i * 100) / 119 : 160 + (i % 2 ? 0.5 : -0.5))
/** 接飞刀形态：130 线性阴跌到 63（每点 −0.4） */
const KNIFE_CURVE = (i) => 130 - i * 0.4
/** 强势上冲形态：全程加速上涨到 7 天新高（rank=1.0 且斜率远超 +0.05%/h） */
const V2_ROCKET_CURVE = (i) => (i < 120 ? 60 + i * 0.5 : 120 + (i - 120))
/** 价格函数 → analyzeItem 的原始入参（kkrb 形状，168 小时点） */
function mkCurveItem(fn, name = '形态测试弹') {
  const keys = hourlyKeys()
  const priceCurve = {}
  for (let i = 0; i < 168; i++) priceCurve[keys[i]] = fn(i)
  const cur = fn(167)
  return { itemName: name, grade: 4, pic: null, currectPrice: cur, priceCurve }
}

function catalogFixture({ priceOf = (i) => 100 + i, dayKey = DAY_KEY, lastUpdate = LAST_UPDATE } = {}) {
  return {
    status: 'ok',
    ttl_seconds: 60,
    encoding: 'json',
    generated_at: Date.now(),
    items: NAMES.map((name, i) => ({
      id: 1000 + i,
      name,
      display_name: name,
      alias_name: null,
      icon_url: `https://playerhub.df.qq.com/icon/${i}.png`,
      grade: String(3 + (i % 3)),
      subcategory: 'ammo.test',
      subcategory_label: 'test',
      latest_price: priceOf(i),
      today_price_day_key: dayKey,
      last_update: lastUpdate,
      seven_day_high_price: 200,
      seven_day_low_price: 50,
    })),
  }
}

/** kkrb 快照 fixture（兜底分支用；version 为 10 位小时档，曲线带税后价对） */
function kkrbFixture(version = '2026101310') {
  const curve = Object.fromEntries(hourlyKeys().map((k, idx) => [k, 100 + (idx % 10)]))
  return {
    code: 1,
    version,
    data: NAMES.map((name, i) => ({
      itemName: name,
      grade: 4,
      pic: null,
      currectPrice: 300 + i,
      thisWeekHighestPrice: 400,
      thisWeekHighestPriceAfterTax: 340,
      priceCurve: curve,
    })),
  }
}

/* ---------- 上游桩：按 URL 分流，替换 globalThis.fetch ---------- */
function respondGzip(obj, status = 200) {
  // moligod 实测行为：响应体恒为裸 gzip 且不带 Content-Encoding 头
  return new Response(gzipSync(Buffer.from(JSON.stringify(obj))), { status })
}

function installStub({ catalog, histories = {}, kkrb = null } = {}) {
  const realFetch = globalThis.fetch
  const calls = { catalog: 0, history: [], kkrbHome: 0, kkrbMenu: 0, kkrbData: 0, kkrbTrade: 0, kkrbCalendar: 0 }
  globalThis.fetch = async (input) => {
    const url = typeof input === 'string' ? input : input && input.url
    // 本机回环请求（SSE 读 127.0.0.1 临时端口）不走桩，透传真 fetch
    if (url && /^http:\/\/(127\.0\.0\.1|localhost)(:|\/)/.test(url)) return realFetch(input)
    if (url && url.includes('moligod.com/api/market/ammo-catalog')) {
      calls.catalog++
      if (catalog instanceof Error) throw catalog
      const fixture = typeof catalog === 'function' ? catalog() : catalog
      return respondGzip(fixture)
    }
    if (url && url.includes('moligod.com/api/market/history')) {
      const name = new URL(url).searchParams.get('name')
      calls.history.push(name)
      const h = typeof histories === 'function' ? histories(name) : histories[name]
      if (h instanceof Error) throw h
      if (!h) return respondGzip({ status: 'ok', data: [] })
      return respondGzip(h)
    }
    if (url && url.includes('kkrb.net')) {
      // fetch-once 的 join 旁路（军需处兑换 / 赛季日历）与子弹快照同为 kkrb
      // 接口，桩内如实应答：军需处空表、日历无有效赛季——两者模块级 TTL 缓存
      // 首次命中后后续轮次零请求。不建模的话它们会落进下面的 home 兜底分支
      // 拿到空 body，res.json() 抛错再触发 kkrbRequest 内部 3s+6s 重试，每轮
      // fetchOnce 白吃 ~18s（⑩b 兜底状态机 20s 轮询窗就是被这个拖爆的）
      if (url.includes('/getTradeAmmoData')) {
        calls.kkrbTrade++
        return Response.json({ code: 1, version: '2026101314', data: { cn: [] } })
      }
      if (url.includes('/getActivityCalendarData')) {
        calls.kkrbCalendar++
        return Response.json({ code: 1, data: {} })
      }
      if (!kkrb) throw new Error(`stub: 意外的 kkrb 调用 ${url}`)
      const res = (body, setCookie) =>
        new Response(body, { headers: setCookie ? [['set-cookie', setCookie]] : {} })
      if (url.includes('/getMenu')) {
        calls.kkrbMenu++
        return res('', 'csrf_token=stub-token')
      }
      if (url.includes('/getAmmoPLData')) {
        calls.kkrbData++
        return Response.json(kkrb)
      }
      calls.kkrbHome++
      return res('', 'PHPSESSID=stub-sess')
    }
    throw new Error(`stub: 未预期的请求 ${url}`)
  }
  return { calls, restore: () => (globalThis.fetch = realFetch) }
}

/* ---------- SSE 读取器（Node 无内建 EventSource，按 wire 格式手解） ---------- */
class SseReader {
  constructor(port) {
    this.url = `http://127.0.0.1:${port}/events`
    this.ctrl = new AbortController()
    this.frames = []
    this.waiters = []
    this.buf = ''
  }
  async start() {
    this.res = await fetch(this.url, { signal: this.ctrl.signal })
    assert(this.res.ok, `SSE HTTP ${this.res.status}`)
    assert(
      /text\/event-stream/.test(this.res.headers.get('content-type') || ''),
      'SSE Content-Type 应为 text/event-stream'
    )
    const reader = this.res.body.getReader()
    const dec = new TextDecoder()
    this.pump = (async () => {
      try {
        for (;;) {
          const { done, value } = await reader.read()
          if (done) break
          this.buf += dec.decode(value, { stream: true })
          let idx
          while ((idx = this.buf.indexOf('\n\n')) >= 0) {
            const raw = this.buf.slice(0, idx)
            this.buf = this.buf.slice(idx + 2)
            const frame = { event: null, data: null }
            for (const line of raw.split('\n')) {
              if (line.startsWith(':')) continue // 注释心跳
              if (line.startsWith('event:')) frame.event = line.slice(6).trim()
              if (line.startsWith('data:')) frame.data = line.slice(5).trim()
            }
            if (frame.event != null || frame.data != null) {
              this.frames.push(frame)
              for (const w of this.waiters.splice(0)) w(frame)
            }
          }
        }
      } catch {
        /* abort 后的正常结束 */
      }
    })()
  }
  waitFor(eventName, timeoutMs = 5000) {
    const hit = this.frames.find((f) => f.event === eventName)
    if (hit) return Promise.resolve(hit)
    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`等待 SSE 事件 ${eventName} 超时 ${timeoutMs}ms`)),
        timeoutMs
      )
      const onFrame = (f) => {
        if (f.event === eventName) {
          clearTimeout(timer)
          resolve(f)
        } else {
          this.waiters.push(onFrame) // 非目标事件，继续等
        }
      }
      this.waiters.push(onFrame)
    })
  }
  close() {
    this.ctrl.abort()
  }
}

/* ============================================================
   ① 跨年补年 / 时间键规则
   ============================================================ */
check('跨年补年与时间键规则', () => {
  const now = new Date()
  const p = beijingParts(now)
  assert(inferYear('10-06 14:00', now) === p.year, '同年 time 应返回当年')
  const newYear = new Date(`${p.year + 1}-01-02T00:00:00Z`)
  assert(inferYear('12-31 22:00', newYear) === p.year, '年初取到去年 12-31 应判上一年')
  const key = historyTimeToKey('10-06 14:05', now)
  assert(/^\d{12}$/.test(key || ''), `时间键应为 12 位，实际 ${key}`)
  assert(key === `${p.year}10061405`, `时间键数值不符：${key}`)
  assert(historyTimeToKey('bad-format', now) === null, '格式不符应返回 null')
})

/* ============================================================
   ② 形状适配 + full 铺缓存 + fast 0 次 history
   ============================================================ */
check('catalog→kkrb 形状适配；full 铺缓存；fast 模式 0 次 history 请求', async () => {
  clearCurveCache()
  const stub = installStub({
    catalog: catalogFixture(),
    histories: () => historyFixture(),
  })
  try {
    const snap = await getSnapshot({ mode: 'full', paceMs: 0 })
    assert(snap.source === 'moligod' && snap.code === 1, '快照应标记 source=moligod / code=1')
    assert(
      snap.version === '202610131018',
      `version 应由 day_key+last_update 推出 12 位分钟档，实际 ${snap.version}`
    )
    const it = snap.data[0]
    assert(it.itemName === NAMES[0], 'itemName 应映射 name')
    assert(typeof it.grade === 'number' && it.grade === 3, `grade 应转数字，实际 ${typeof it.grade}`)
    assert(/^https:\/\//.test(it.pic), 'pic 应映射 icon_url')
    assert(Number.isFinite(it.currectPrice) && it.currectPrice > 0, 'currectPrice 应映射 latest_price')
    const keys = Object.keys(it.priceCurve)
    assert(keys.length === 168, `曲线应 168 点，实际 ${keys.length}`)
    assert(keys.every((k) => /^\d{12}$/.test(k)), '曲线键应为 12 位 YYYYMMDDHHmm')
    assert(
      stub.calls.history.length === NAMES.length,
      `full 应铺 ${NAMES.length} 条曲线，实际 ${stub.calls.history.length}`
    )
    assert(curveCacheStats(NAMES).fresh === NAMES.length, '铺完后缓存应全新鲜')

    const before = stub.calls.history.length
    await getSnapshot({ mode: 'fast', paceMs: 0 })
    assert(
      stub.calls.history.length === before,
      `fast 模式绝不补发 history（打了 ${stub.calls.history.length - before} 次）`
    )
  } finally {
    stub.restore()
  }
})

/* ============================================================
   ③ auto 只补过期/缺失；fast 缺缓存判数据不足
   ============================================================ */
check('auto 模式只补过期/缺失曲线；fast 缺缓存→「数据不足」不补发', async () => {
  clearCurveCache()
  const curveItems = NAMES.map((name) => ({
    name,
    curve: hourlyKeys().map((k, idx) => [k, 100 + (idx % 7)]),
  }))
  const staleAt = Date.now() - CURVE_TTL_MS - 1000
  const stub = installStub({
    catalog: catalogFixture(),
    histories: () => historyFixture(),
  })
  try {
    primeCurveCache(curveItems.filter((_, i) => i !== 9)) // 缺第 9 条
    primeCurveCache([curveItems[7]], { fetchedAt: staleAt }) // 第 7 条过期
    const stats = curveCacheStats(NAMES)
    assert(
      stats.fresh === NAMES.length - 2 && stats.stale === 2,
      `缓存应恰有 2 条不新鲜，实际 fresh=${stats.fresh} stale=${stats.stale}`
    )
    await getSnapshot({ mode: 'auto', paceMs: 0 })
    const fetched = new Set(stub.calls.history)
    assert(stub.calls.history.length === 2, `auto 只应补 2 条，实际 ${stub.calls.history.length}`)
    assert(fetched.has(NAMES[7]) && fetched.has(NAMES[9]), `应恰好补过期(${NAMES[7]})与缺失(${NAMES[9]})`)

    // fast 遇缺失缓存：留空曲线、判数据不足、零 history 请求
    clearCurveCache()
    primeCurveCache(curveItems.slice(0, 10))
    const nBefore = stub.calls.history.length
    const snap = await getSnapshot({ mode: 'fast', paceMs: 0 })
    assert(stub.calls.history.length === nBefore, 'fast 对缺失曲线也不应补发 history')
    const missing = snap.data.find((d) => d.itemName === NAMES[50])
    assert(missing && Object.keys(missing.priceCurve).length === 0, '缺失曲线应留空 priceCurve')
    const analyzed = analyzeItem(missing)
    assert(
      analyzed.signal === 'WAIT' && analyzed.rank === null,
      `缺曲线应判「数据不足」，实际 signal=${analyzed.signal} rank=${analyzed.rank}`
    )
  } finally {
    stub.restore()
  }
})

/* ============================================================
   ④ 端到端 analyze（v2 口径：BUY 五重门槛 / SELL 动量守则 / 接飞刀拒绝）
   ============================================================ */
check('端到端 analyze：v2 BUY·SELL 命中 / 接飞刀拒绝 / 止损位', async () => {
  clearCurveCache()
  const stub = installStub({
    catalog: catalogFixture({ priceOf: (i) => (i === 0 ? 40 : i === 1 ? 160 : i === 2 ? 74 : 100 + i) }),
    histories: (name) => {
      const i = NAMES.indexOf(name)
      if (i === 0) return historyFixture(100, 40) // 末点崩到 40：贴底接飞刀 → 不得 BUY
      if (i === 1) return curveFnFixture(V2_SELL_CURVE) // 高位横盘动能走弱 → SELL
      if (i === 2) return curveFnFixture(V2_BUY_CURVE) // 崩后底部企稳缓升 → BUY
      return historyFixture()
    },
  })
  try {
    const snap = await getSnapshot({ mode: 'full', paceMs: 0 })
    const analysis = analyzeMarket(snap)
    assert(analysis.items.length === NAMES.length, '分析应覆盖全部弹种')
    for (const it of analysis.items) {
      assert(['BUY', 'WATCH', 'SELL', 'WAIT'].includes(it.signal), `信号值域异常：${it.signal}`)
      if (it.rank != null) assert(it.p25 <= it.p75, `${it.name} P25(${it.p25}) 应 ≤ P75(${it.p75})`)
      if (it.signal === 'BUY') {
        // v2 五重门槛（analyze.mjs RULES）：缺一不可
        assert(it.rank <= 0.2, `BUY rank 应 ≤0.2，实际 ${it.rank}`)
        assert(it.profitPct >= 0.1, `BUY 净利差应 ≥10%，实际 ${it.profitPct}`)
        assert(it.curve.length >= 48, `BUY 曲线应 ≥48 点，实际 ${it.curve.length}`)
        assert(it.bounceOffLow >= 0.03, `BUY 离底应 ≥3%，实际 ${it.bounceOffLow}`)
        assert(it.lowAgeH >= 12, `BUY 低点年龄应 ≥12h，实际 ${it.lowAgeH}`)
        assert(it.slope48 >= 0.02, `BUY 48h 斜率应 ≥+0.02%/h，实际 ${it.slope48}`)
        assert(Number.isFinite(it.stopLoss) && it.stopLoss < it.current, `BUY 应带止损位且低于现价，实际 ${it.stopLoss}`)
      }
    }
    const buy = analysis.items.find((i) => i.name === NAMES[2])
    const sell = analysis.items.find((i) => i.name === NAMES[1])
    const knife = analysis.items.find((i) => i.name === NAMES[0])
    assert(buy.signal === 'BUY', `构造「崩后企稳」弹应 BUY，实际 ${buy.signal}（rank=${buy.rank} slope=${buy.slope48} bounce=${buy.bounceOffLow} lowAge=${buy.lowAgeH} pct=${buy.profitPct}）`)
    assert(sell.signal === 'SELL', `构造「高位横盘」弹应 SELL，实际 ${sell.signal}（rank=${sell.rank} slope=${sell.slope48}）`)
    assert(buy.taxRate === 0.15, `moligod 无税后字段应回退 15% 税率，实际 ${buy.taxRate}`)

    // 接飞刀回归（旧口径致命伤）：末点崩到 40 贴 7 天新低、幻影利差 >100%，
    // 但未止跌（bounce=0 / lowAge=0 / 斜率深负）→ 必须 WATCH，绝不 BUY
    assert(knife.signal !== 'BUY', `贴底阴跌弹不得 BUY（旧口径缺陷回归），实际 ${knife.signal}`)
    assert(knife.signal === 'WATCH', `贴底但未企稳应 WATCH，实际 ${knife.signal}`)

    // SELL 动量守则：强势上冲的末点（涨势仍陡）不催卖——rank 高但斜率 >0.05%/h
    const rocket = analyzeItem(mkCurveItem(V2_ROCKET_CURVE))
    assert(rocket.signal === 'WAIT', `强势上冲弹不应催卖（rank=${rocket.rank} slope=${rocket.slope48}），实际 ${rocket.signal}`)
  } finally {
    stub.restore()
  }
})

/* ============================================================
   ⑤ notify-policy 去抖语义
   ============================================================ */
check('notify-policy：首次即报 / 冷却 / 切换 streak≥2 确认 / 到期 / 深跌重报', () => {
  const t0 = 1_800_000_000_000
  const mk = (name, signal, current) => ({
    name, signal, current, rank: 0.2, targetSell: 100, netSell: 85, netHigh: 120,
    profitPerRound: 20, profitPct: 0.3,
  })

  // 首次出现 → 立即通知
  let state = emptyState()
  let r = judgeSignals(state, [mk('A', 'BUY', 100)], t0)
  assert(r.buys.length === 1, '首次出现应通知')

  // 同信号第二轮（冷却内、无深跌）→ 不通知
  r = judgeSignals(state, [mk('A', 'BUY', 99)], t0 + 60_000)
  assert(r.buys.length === 0, '冷却期内同信号不应重复通知')

  // 信号切换当轮 → 不通知（防分位边界抖动刷屏）
  r = judgeSignals(state, [mk('A', 'SELL', 200)], t0 + 120_000)
  assert(r.buys.length === 0 && r.sells.length === 0, '切换当轮不应通知')

  // 新信号连续第 2 轮 → 确认通知
  r = judgeSignals(state, [mk('A', 'SELL', 200)], t0 + 180_000)
  assert(r.sells.length === 1, '切换后连续第 2 轮应确认通知')

  // 确认后的下一轮 → 冷却静默
  r = judgeSignals(state, [mk('A', 'SELL', 200)], t0 + 240_000)
  assert(r.sells.length === 0, '确认后冷却期内应静默')

  // 冷却到期 → 再报
  r = judgeSignals(state, [mk('A', 'SELL', 200)], t0 + 240_000 + POLICY.COOLDOWN_MS + 1)
  assert(r.sells.length === 1, '冷却到期应再报')

  // BUY 冷却期内深跌 ≥5% → 重报；跌幅不足则不报
  state = emptyState()
  judgeSignals(state, [mk('B', 'BUY', 100)], t0)
  r = judgeSignals(state, [mk('B', 'BUY', 94)], t0 + 60_000)
  assert(r.buys.length === 1, '深跌 5% 应重报')
  state = emptyState()
  judgeSignals(state, [mk('B', 'BUY', 100)], t0)
  r = judgeSignals(state, [mk('B', 'BUY', 96)], t0 + 60_000)
  assert(r.buys.length === 0, '跌幅不足 5% 不应重报')

  // 渐进阴跌回归：每轮跌幅 <5% 但累计 ≥5% → 必须重报（深跌参考价是
  // 「上次通知价」，不得被逐轮观察价冲淡）；重报后参考价刷新
  state = emptyState()
  judgeSignals(state, [mk('D', 'BUY', 100)], t0) // 通知，参考价 100
  r = judgeSignals(state, [mk('D', 'BUY', 99)], t0 + 60_000) // -1%
  assert(r.buys.length === 0, '阴跌 -1% 不应重报')
  r = judgeSignals(state, [mk('D', 'BUY', 98)], t0 + 120_000) // 累计 -2%
  assert(r.buys.length === 0, '阴跌累计 -2% 不应重报')
  r = judgeSignals(state, [mk('D', 'BUY', 95)], t0 + 180_000) // 累计 -5%
  assert(r.buys.length === 1, '阴跌累计 -5% 应重报（参考价须为上次通知价 100）')
  r = judgeSignals(state, [mk('D', 'BUY', 94)], t0 + 240_000) // 重报后参考价 95，-1.05%
  assert(r.buys.length === 0, '重报后参考价应刷新为新通知价 95')
  r = judgeSignals(state, [mk('D', 'BUY', 90)], t0 + 300_000) // 距 95 累计 -5.26%
  assert(r.buys.length === 1, '距新参考价累计 -5% 应再次重报')

  // WAIT 弹也逐轮入 state（streak 计算的前提）
  state = emptyState()
  judgeSignals(state, [mk('C', 'WAIT', 50)], t0)
  assert(state.items['C'] && state.items['C'].signal === 'WAIT', 'WAIT 信号也应全量记录')
})

/* ============================================================
   ⑥ fetchOnce：指纹门槛 / source 字段 / dist 联动 / 心跳
   ============================================================ */
check('fetchOnce：指纹门槛（变化才写/同指纹静默/心跳重写）+ source + dist 联动', async () => {
  clearCurveCache()
  const root = await mkdtemp(path.join(tmpdir(), 'ammo-selftest-6-'))
  await mkdir(path.join(root, 'dist', 'ammo'), { recursive: true }) // 模拟跑过 build
  let priceBump = 0
  const stub = installStub({
    catalog: () => catalogFixture({ priceOf: (i) => 100 + i + priceBump }),
    histories: () => historyFixture(),
  })
  try {
    const pub = path.join(root, 'public', 'ammo', 'market.json')
    const dist = path.join(root, 'dist', 'ammo', 'market.json')

    // 首次：必写，含 source/fingerprint，dist 联动
    let r = await fetchOnce({ rootDir: root, mode: 'full', paceMs: 0 })
    assert(
      r.changed === true && r.source === 'moligod',
      `首次应落盘且 source=moligod，实际 changed=${r.changed} source=${r.source}`
    )
    const j1 = JSON.parse(await readFile(pub, 'utf8'))
    assert(
      j1.source === 'moligod' && /^[0-9a-f]{64}$/.test(j1.fingerprint),
      'market.json 顶层应含 source 与 sha256 指纹'
    )
    const d1 = JSON.parse(await readFile(dist, 'utf8'))
    assert(d1.version === j1.version && d1.source === 'moligod', 'dist/ammo/market.json 应联动写入')

    // 同内容再抓：changed=false 不写
    r = await fetchOnce({ rootDir: root, mode: 'fast', paceMs: 0 })
    assert(r.changed === false, '同指纹应静默（不写盘）')

    // 心跳：把 market.json mtime 拨回 6 分钟前 → 重写（fetchedAt 刷新）
    const old = new Date(Date.now() - HEARTBEAT_MS - 60_000)
    await utimes(pub, old, old)
    r = await fetchOnce({ rootDir: root, mode: 'fast', paceMs: 0 })
    assert(r.changed === true, '超 5 分钟心跳应重写')

    // 内容变化：写盘 + 指纹翻转
    priceBump = 5
    r = await fetchOnce({ rootDir: root, mode: 'fast', paceMs: 0 })
    assert(r.changed === true, '价格变化应写盘')
    const j2 = JSON.parse(await readFile(pub, 'utf8'))
    assert(j2.fingerprint !== j1.fingerprint, '指纹应随价格翻转')

    // writeSnapshotPair（四处「public + dist 双写」的统一助手）：dist 命中双写、
    // 返回路径列表；dist 目录不存在时只写 public
    await rm(path.join(root, 'dist', 'ammo'), { recursive: true, force: true }) // 撤掉 dist 再对比
    const written = await writeSnapshotPair(root, path.join('ammo', 'market.json'), JSON.stringify({ pair: 1 }))
    assert(written.length === 1 && written[0] === pub, `无 dist 目录应只写 public，实际 ${written.join(',')}`)
    await mkdir(path.join(root, 'dist', 'ammo'), { recursive: true })
    const written2 = await writeSnapshotPair(root, path.join('ammo', 'market.json'), JSON.stringify({ pair: 2 }))
    assert(
      written2.length === 2 && written2[1] === path.join(root, 'dist', 'ammo', 'market.json'),
      `dist 目录存在应双写并返回两路径，实际 ${written2.join(',')}`
    )
    assert(JSON.parse(await readFile(written2[1], 'utf8')).pair === 2, 'dist 应与 public 同内容')
  } finally {
    stub.restore()
    await rm(root, { recursive: true, force: true })
  }
})

/* ============================================================
   ⑥b joinOfficialAnchor：锚缺失 / 坏档静默跳过 + 正常 join（纯离线）
   ============================================================ */
check('joinOfficialAnchor：锚缺失/坏档静默跳过 + 正常 join（dev 现算）', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'ammo-selftest-6b-'))
  const anchorPath = path.join(root, 'data', 'ammo', 'official-anchor.json')
  const items = [
    { name: '测试弹0号', current: 110 },
    { name: '测试弹1号', current: 50 },
    { name: '无锚弹', current: 80 },
  ]
  try {
    // 分支一：锚文件不存在 → 原样返回、officialAnchor=null（旁路参照永不阻塞主链路）
    let r = await joinOfficialAnchor(items, anchorPath)
    assert(r.officialAnchor === null && r.items === items, '锚缺失应原样返回且 officialAnchor=null')

    // 分支二：坏档（半截 JSON）→ 同上静默跳过
    await mkdir(path.dirname(anchorPath), { recursive: true })
    await writeFile(anchorPath, '{"items": [')
    r = await joinOfficialAnchor(items, anchorPath)
    assert(r.officialAnchor === null && r.items === items, '坏档应静默跳过、不炸主链路')

    // 分支三：正常 join——按弹名精确挂 official；dev 按本快照现价现算；
    // joined 计锚侧有效条数（快照里没有的锚条目也计入，如实反映锚覆盖面）
    await writeFile(anchorPath, JSON.stringify({
      fetchedAt: '2026-10-27T08:00:00.000Z',
      items: [
        { name: '测试弹0号', official: 100 },
        { name: '测试弹1号', official: 'x' }, // 非法锚值剔除
        { name: '锚里多余的弹', official: 200 }, // 快照无此弹：joined 仍计
      ],
    }))
    r = await joinOfficialAnchor(items, anchorPath)
    assert(
      r.officialAnchor && r.officialAnchor.joined === 2 && r.officialAnchor.fetchedAt === '2026-10-27T08:00:00.000Z',
      `joined 应为有效锚条数 2 且透传 fetchedAt，实际 ${JSON.stringify(r.officialAnchor)}`
    )
    const a = r.items.find((i) => i.name === '测试弹0号')
    assert(
      a.official && a.official.avg === 100 && a.official.dev === 0.1 && a.official.at === '2026-10-27T08:00:00.000Z',
      `official 应挂锚并按现价现算 dev=(110−100)/100=0.1，实际 ${JSON.stringify(a.official)}`
    )
    assert(r.items.find((i) => i.name === '测试弹1号').official === undefined, '锚值非法的弹不得造字段')
    assert(r.items.find((i) => i.name === '无锚弹').official === undefined, '锚里没有的弹不造字段')
    assert(items[0].official === undefined, '入参数组不得被改动（返回新数组）')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

/* ============================================================
   ⑦ 主源故障 → 自动回落 kkrb（兜底分支）
   ============================================================ */
check('主源故障自动回落 kkrb：重试 3 次、来源如实切换、旧口径兼容', async () => {
  clearCurveCache()
  const root = await mkdtemp(path.join(tmpdir(), 'ammo-selftest-7-'))
  // 先用 moligod 落一份正常数据
  const okStub = installStub({ catalog: catalogFixture(), histories: () => historyFixture() })
  try {
    await fetchOnce({ rootDir: root, mode: 'full', paceMs: 0 })
  } finally {
    okStub.restore()
  }

  // 再让 moligod 全面失败（含重试），kkrb 桩正常 → 回落
  const badStub = installStub({
    catalog: new Error('moligod 挂了（模拟）'),
    kkrb: kkrbFixture('2026101314'),
  })
  try {
    const r = await fetchOnce({ rootDir: root, mode: 'auto', paceMs: 0 })
    assert(r.source === 'kkrb', `应回落 kkrb，实际 ${r.source}`)
    assert(r.version === '2026101314', 'kkrb 路径 version 应保持上游 10 位小时档')
    assert(badStub.calls.catalog === 3, `主源应重试 2 次（共 3 次尝试），实际 ${badStub.calls.catalog}`)
    assert(
      badStub.calls.kkrbHome >= 1 && badStub.calls.kkrbMenu >= 1 && badStub.calls.kkrbData >= 1,
      'kkrb 三步会话应完整走通'
    )
    const j = JSON.parse(await readFile(path.join(root, 'public', 'ammo', 'market.json'), 'utf8'))
    assert(j.source === 'kkrb' && j.version === '2026101314', '落盘应如实标记 kkrb 兜底')
    assert(j.items.length === NAMES.length && j.items[0].taxRate > 0, 'kkrb 快照照常产出分析字段')
    // 页面侧对 10 位版本的兼容由 ⑪ 的 formatVersionLabel 断言覆盖
  } finally {
    badStub.restore()
    await rm(root, { recursive: true, force: true })
  }
})

/* ============================================================
   ⑧ 留档门槛与清理
   ============================================================ */
check('留档 ≥10min 门槛 + 超 7 天 / 超 1000 份清理', async () => {
  clearCurveCache()
  const root = await mkdtemp(path.join(tmpdir(), 'ammo-selftest-8-'))
  const histDir = path.join(root, 'data', 'ammo', 'history')
  await mkdir(histDir, { recursive: true })
  const now = Date.now()
  // 预置：一份 8 天前旧档（验证超龄清理）+ 一份 11 分钟前的近期档
  //（提供「距上次留档 ≥10min」的门槛基准，同时是稍后超量清理里最旧的一份）
  const oldF = path.join(histDir, '2026010100.json')
  const recentF = path.join(histDir, '2026101309.json')
  await writeFile(oldF, '{}')
  await writeFile(recentF, '{}')
  await utimes(oldF, new Date(now - 8 * 24 * 3600 * 1000), new Date(now - 8 * 24 * 3600 * 1000))
  await utimes(recentF, new Date(now - 11 * 60 * 1000), new Date(now - 11 * 60 * 1000))

  let priceBump = 0
  const stub = installStub({
    catalog: () => catalogFixture({ priceOf: (i) => 100 + i + priceBump }),
    histories: () => historyFixture(),
  })
  try {
    // 第一次（内容变化、距上次留档 11min）：留档 + 清掉超龄旧档
    await fetchOnce({ rootDir: root, mode: 'fast', paceMs: 0 })
    let files = new Set(await readdir(histDir))
    assert(!files.has('2026010100.json'), '超 7 天旧档应被清理')
    assert(files.has('202610131018.json'), `应留档 <version>.json，实际 ${[...files].join(',')}`)
    assert(files.has('2026101309.json'), '7 天内旧档不应误删')

    // 第二次（10min 内、内容变化）：门槛拦截，不重复留档
    priceBump = 1
    await fetchOnce({ rootDir: root, mode: 'fast', paceMs: 0 })
    files = new Set(await readdir(histDir))
    assert(files.size === 2, `10min 内不应重复留档，实际 ${files.size} 份`)

    // 灌 1005 份触发上限：清理按 mtime 从最旧开始，收敛到恰好 1000 份。
    // 注意：先前唯一一份留档的 mtime 早于全部 fillers，属「最旧的 7 份」之列，
    // 按 mtime 逐出规约同样会被清理——这是设计行为，不是丢数据（内容仍以
    // public/ammo/market.json 为准，留档只是备份）。
    priceBump = 2
    for (let i = 0; i < 1005; i++) {
      await writeFile(path.join(histDir, `filler-${String(i).padStart(5, '0')}.json`), '{}')
    }
    await fetchOnce({ rootDir: root, mode: 'fast', paceMs: 0 })
    const list = (await readdir(histDir)).filter((f) => f.endsWith('.json'))
    assert(list.length === 1000, `留档应收敛到恰好 1000 份，实际 ${list.length}`)
    assert(!list.includes('2026101309.json'), '最旧的近期档应作为超额部分被清理')
    assert(!list.includes('202610131018.json'), '早于 fillers 的留档属最旧 7 份，按 mtime 规约被逐')
    assert(list.includes('filler-01004.json'), '最新的 filler 应保留')
  } finally {
    stub.restore()
    await rm(root, { recursive: true, force: true })
  }
})

/* ============================================================
   ⑨ 并发读写原子性
   ============================================================ */
check('原子写：写盘全程并发读者 JSON.parse 不炸、无 .tmp 残留', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'ammo-selftest-9-'))
  const target = path.join(root, 'public', 'ammo', 'market.json')
  const big = JSON.stringify({ items: Array.from({ length: 2000 }, (_, i) => ({ n: i, s: 'x'.repeat(200) })) })
  let stop = false
  let reads = 0
  const reader = (async () => {
    while (!stop) {
      try {
        JSON.parse(await readFile(target, 'utf8'))
        reads++
      } catch (e) {
        if (e.code !== 'ENOENT') throw new Error(`读到半截 JSON：${e.message}`)
      }
      await new Promise((r) => setTimeout(r, 0))
    }
  })()
  try {
    for (let i = 0; i < 60; i++) {
      await writeJsonAtomic(target, i % 2 ? big : JSON.stringify({ items: [], flip: i }))
    }
    stop = true
    await reader
    assert(reads > 10, `并发读取应成功多次，实际 ${reads} 次`)
    const leftovers = (await readdir(path.dirname(target))).filter((f) => f.endsWith('.tmp'))
    assert(leftovers.length === 0, `写完不应残留 .tmp，实际 ${leftovers.join(',')}`)
  } finally {
    stop = true
    await reader.catch(() => {})
    await rm(root, { recursive: true, force: true })
  }
})

/* ============================================================
   ⑨b 并发写者（违反「同时只跑一个写盘者」时的安全网）
   ============================================================ */
check('并发写者共写同一目标：独立 tmp 名，读方全程可解析、无 tmp 残留', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'ammo-selftest-9b-'))
  const target = path.join(root, 'public', 'ammo', 'market.json')
  let stop = false
  let reads = 0
  const reader = (async () => {
    while (!stop) {
      try {
        JSON.parse(await readFile(target, 'utf8'))
        reads++
      } catch (e) {
        if (e.code !== 'ENOENT') throw new Error(`并发写者下读到半截 JSON：${e.message}`)
      }
      await new Promise((r) => setTimeout(r, 0))
    }
  })()
  try {
    const writers = [0, 1, 2].map((k) => (async () => {
      for (let i = 0; i < 40; i++) {
        // 三个写者共用同一固定目标、交错写不同载荷（模拟 monitor 与手动
        // fetch 同时跑：A 的 rename 不得搬走 B 正在写的半截内容）
        await writeJsonAtomic(target, JSON.stringify({ w: k, i, pad: 'y'.repeat(40000) }))
      }
    })())
    await Promise.all(writers)
    stop = true
    await reader
    assert(reads > 10, `并发读取应成功多次，实际 ${reads} 次`)
    const leftovers = (await readdir(path.dirname(target))).filter((f) => f.endsWith('.tmp'))
    assert(leftovers.length === 0, `并发写完不应残留 .tmp，实际 ${leftovers.join(',')}`)
    const final = JSON.parse(await readFile(target, 'utf8'))
    assert(['0', '1', '2'].includes(String(final.w)), '最终内容应完整属于某个写者')
  } finally {
    stop = true
    await reader.catch(() => {})
    await rm(root, { recursive: true, force: true })
  }
})

/* ============================================================
   ⑩ SSE：hello 初始事件 + 落盘广播 market（127.0.0.1 临时端口）
   ============================================================ */
check('SSE：连接即收 event:hello；落盘广播 event:market（wire 格式）', async () => {
  clearCurveCache()
  const root = await mkdtemp(path.join(tmpdir(), 'ammo-selftest-10-'))
  const stub = installStub({
    catalog: catalogFixture(),
    histories: () => historyFixture(),
  })
  const live = createLiveServer({
    rootDir: root,
    statePath: path.join(root, 'data', 'ammo', 'monitor-state.json'),
    noNotify: true,
  })
  let reader = null
  try {
    await new Promise((resolve) => live.server.listen(0, '127.0.0.1', resolve))
    const port = live.server.address().port
    assert(Number.isInteger(port) && port > 0, '应监听在 127.0.0.1 临时端口')

    reader = new SseReader(port)
    await reader.start()
    // hello 是连接即发的确定性初始事件（不依赖落盘时机，防 flaky）
    const hello = await reader.waitFor('hello', 1500)
    const helloData = JSON.parse(hello.data)
    assert(
      typeof helloData === 'object' && 'version' in helloData && 'source' in helloData,
      'hello 应携带 {version, source, ...}'
    )

    // 触发一轮真实 cycle：fetchOnce(桩上游) → 落盘 → 广播 market
    await live.triggerCycle('fast')
    const market = await reader.waitFor('market', 5000)
    const mData = JSON.parse(market.data)
    assert(
      mData.source === 'moligod' && /^\d{12}$/.test(mData.version),
      `market 广播应带 moligod 12 位版本，实际 ${market.data}`
    )
    assert(mData.version === live.status.version, '广播版本应与 health 状态一致')
    const j = JSON.parse(await readFile(path.join(root, 'public', 'ammo', 'market.json'), 'utf8'))
    assert(j.version === mData.version, '广播版本应与落盘一致')

    // --no-notify 回归：静默模式仍须逐轮记录去抖 state（否则静默 ≥6h 后恢复
    // 通知时，全部现存信号冷却到期一次性爆发）
    const stateFile = path.join(root, 'data', 'ammo', 'monitor-state.json')
    const st = JSON.parse(await readFile(stateFile, 'utf8'))
    const recorded = Object.keys(st.items || {})
    assert(recorded.length === NAMES.length, `no-notify 下 state 应全量记录（${NAMES.length} 项），实际 ${recorded.length}`)
    assert(st.items[NAMES[0]] && 'signal' in st.items[NAMES[0]], 'state 记录应含 signal 字段')
  } finally {
    if (reader) reader.close()
    await live.close()
    stub.restore()
    await rm(root, { recursive: true, force: true })
  }
})

/* ---------- live 状态机观测工具：轮询等待 + 首次观测时刻（⑩b/⑩c 计时口径） ---------- */
/** 轮询直到 cond() 成立；返回首次观测为真的时刻（ms 时间戳）。
 *  live 的调度全部走真实 setTimeout——多轮状态机用例注入毫秒级节奏参数，
 *  用 2ms 轮询观测 status / 桩计数的变化时刻来测轮间距 */
async function pollUntil(cond, what, timeoutMs = 20000, stepMs = 2) {
  const t0 = Date.now()
  while (!cond()) {
    if (Date.now() - t0 > timeoutMs) throw new Error(`等待超时（${timeoutMs}ms）：${what}`)
    await new Promise((r) => setTimeout(r, stepMs))
  }
  return Date.now()
}

/* ============================================================
   ⑩b live kkrb 兜底状态机：降档节奏 → 每 3 轮探活 → 探活成功切回
   ============================================================ */
check('live kkrb 兜底状态机：moligod 失败→kkrb 降档服务→第 3 轮探活切回', async () => {
  clearCurveCache()
  const root = await mkdtemp(path.join(tmpdir(), 'ammo-selftest-10b-'))
  let moligodUp = false
  const stub = installStub({
    catalog: () => {
      if (!moligodUp) throw new Error('moligod 挂了（模拟）')
      return catalogFixture()
    },
    histories: () => historyFixture(),
    kkrb: kkrbFixture('2026101314'),
  })
  // 捕获 console.log：探活成功的日志行是 forceProbe 分支专属，作探活路径的直证
  const logs = []
  const origLog = console.log
  console.log = (...a) => logs.push(a.join(' '))
  const live = createLiveServer({
    rootDir: root,
    statePath: path.join(root, 'data', 'ammo', 'monitor-state.json'),
    noNotify: true,
    // 注入缩短的节奏（生产默认 60s / 10min / 30min）：kkrbCadenceMs=300ms，
    // fastMs 故意拉大到 60s——若兜底期误用 fast 档，第 2/3 轮要等 ~60s 必超时
    fastMs: 60 * 1000,
    kkrbCadenceMs: 300,
    slowMs: 60 * 60 * 1000, // slow loop 不参与本用例
  })
  try {
    await live.start() // 冷启动轮（auto）：moligod 3 连败（4.5s 重试间隔）→ 回落 kkrb
    assert(
      live.status.source === 'kkrb' && live.status.cycles === 1 && live.status.consecutiveFailures === 0,
      `冷启动应回落 kkrb 并成功（source=${live.status.source} cycles=${live.status.cycles} failures=${live.status.consecutiveFailures}）`
    )
    const j = JSON.parse(await readFile(path.join(root, 'public', 'ammo', 'market.json'), 'utf8'))
    assert(j.source === 'kkrb', 'kkrb 兜底轮落盘应如实标记来源')

    // 第 2、3 轮仍由 kkrb 服务；轮间距 = 兜底节奏 300ms（降档生效，非 fast 档）。
    // 计时口径：上一轮成功（cycles 递增）→ 下一轮首发 catalog 请求的间隔；
    // 每轮 moligod 恰好打 3 次 catalog（⑦ 已证），第 n 轮首发即第 3(n−1)+1 次
    const tEnd1 = Date.now()
    const tStart2 = await pollUntil(() => stub.calls.catalog >= 4, '第 2 轮发起')
    const tEnd2 = await pollUntil(() => live.status.cycles >= 2, '第 2 轮成功')
    const tStart3 = await pollUntil(() => stub.calls.catalog >= 7, '第 3 轮发起')
    await pollUntil(() => live.status.cycles >= 3, '第 3 轮成功')
    assert(live.status.source === 'kkrb' && live.status.consecutiveFailures === 0, '前 3 轮应持续由 kkrb 服务')
    for (const [n, gap] of [['2', tStart2 - tEnd1], ['3', tStart3 - tEnd2]]) {
      assert(
        gap >= 290 && gap <= 1200,
        `第 ${n} 轮间距应为兜底节奏 300ms（实测 ${gap}ms）——误用 fast 档（60s）会超时、无退避会 <290ms`
      )
    }

    // 第 3 轮后探活武装：moligod 恢复 → 第 4 轮（探活轮，fallback:false）切回。
    // kkrbData 在探活轮必须零增量——探活失败不得回落 kkrb（fallback:false 的直证）
    const kkrbDataBefore = stub.calls.kkrbData
    moligodUp = true
    await pollUntil(
      () => live.status.source === 'moligod' && live.status.cycles >= 4,
      '第 4 轮探活切回 moligod',
      10000
    )
    assert(live.status.consecutiveFailures === 0, '探活成功应无失败计数')
    assert(
      logs.some((l) => l.includes('moligod 探活成功，切回分钟级节奏')),
      `应出现探活成功日志（forceProbe 分支专属），实际 ${JSON.stringify(logs)}`
    )
    assert(stub.calls.kkrbData === kkrbDataBefore, '探活轮不得回落 kkrb（fallback:false）')
    await new Promise((r) => setTimeout(r, 50)) // 等落盘尾工（state 写盘）收口
  } finally {
    console.log = origLog
    await live.close()
    stub.restore()
    await rm(root, { recursive: true, force: true })
  }
})

/* ============================================================
   ⑩c live 双源失败指数退避：起点起步 → ×2 增长 → cap 封顶
   ============================================================ */
check('live 双源失败指数退避：起点起步、连败 ×2 增长、cap 封顶不再翻倍', async () => {
  clearCurveCache()
  const root = await mkdtemp(path.join(tmpdir(), 'ammo-selftest-10c-'))
  // kkrb 桩给「会话成功但 version 不合规」的响应：fetchAmmoMarket 的形状校验
  // 在 kkrbRequest 成功之后才抛——绕开 kkrb-client 内部 3s 递增重试，让每轮
  // 失败只耗 moligod 的 4.5s 重试间隔（两源全挂的真实路径，计时可控）
  const stub = installStub({
    catalog: new Error('moligod 挂了（模拟）'),
    kkrb: { code: 1, version: 'bad-version', data: [] },
  })
  const live = createLiveServer({
    rootDir: root,
    statePath: path.join(root, 'data', 'ammo', 'monitor-state.json'),
    noNotify: true,
    // 注入缩短的退避参数（生产默认起点 60s / cap 10min）：
    // 期望延时序列 40 → 40 → 80 → 80（首尾两次 40：start 不翻倍；80 封顶不再翻到 160）
    fastMs: 10,
    kkrbCadenceMs: 50,
    failBackoffStartMs: 40,
    failBackoffCapMs: 80,
    slowMs: 60 * 60 * 1000,
  })
  const origErr = console.error
  console.error = () => {} // 失败日志刷屏降噪（本用例断言节奏，不断言文案）
  try {
    await live.start() // 第 1 轮（auto）失败：moligod 3 连败 + kkrb 形状不符
    assert(live.status.consecutiveFailures === 1, `第 1 轮应失败计数 1，实际 ${live.status.consecutiveFailures}`)
    assert(stub.calls.catalog === 3, `moligod 应恰好 3 次尝试，实际 ${stub.calls.catalog}`)
    // 逐轮记录「上一轮失败落定（failures 递增）→ 下一轮首发请求」的间隔 = 本轮退避延时
    const gaps = []
    for (let round = 2; round <= 5; round++) {
      const tEnd = await pollUntil(() => live.status.consecutiveFailures >= round - 1, `第 ${round - 1} 轮失败落定`)
      const tStart = await pollUntil(() => stub.calls.catalog >= 3 * (round - 1) + 1, `第 ${round} 轮发起`)
      gaps.push(tStart - tEnd)
    }
    await pollUntil(() => live.status.consecutiveFailures >= 5, '第 5 轮失败落定') // 等在飞轮次收口再关服务
    assert(live.status.consecutiveFailures === 5, `五轮应全失败，实际 ${live.status.consecutiveFailures}`)
    // 退避序列断言：下界按 setTimeout 硬保证（不会提前）留 5ms 观测偏移余量；
    // 上界留足调度噪声。未翻倍的机器恒 40ms 到不了 80；未封顶的机器第 5 轮
    // 会翻到 160ms 恒超上界（gap[0] 的观测起点在 start() 返回后，可比定时器
    // 注册晚零点几毫秒，故下界 35 而非 40——仍远大于无退避的 fastMs=10 档）
    assert(gaps[0] >= 35 && gaps[0] <= 150, `第 2 轮延时应为起点 40ms，实际 ${gaps[0]}`)
    assert(gaps[1] >= 40 && gaps[1] <= 150, `第 3 轮延时应仍为 40ms（start 不翻倍），实际 ${gaps[1]}`)
    assert(gaps[2] >= 80 && gaps[2] <= 150, `第 4 轮延时应翻倍到 80ms，实际 ${gaps[2]}`)
    assert(gaps[3] >= 80 && gaps[3] <= 150, `第 5 轮延时应封顶 80ms（未封顶将翻到 160ms），实际 ${gaps[3]}`)
    await new Promise((r) => setTimeout(r, 50)) // 等第 5 轮尾工收口
  } finally {
    console.error = origErr
    await live.close()
    stub.restore()
    await rm(root, { recursive: true, force: true })
  }
})

/* ============================================================
   ⑪ 页面纯逻辑：版本双格式 / 阈值分档 / 通道门槛 / 过期文案（静态回退分支）
   ============================================================ */
check('页面纯逻辑：版本双格式 / 阈值按 source 分档 / SSE 环境门槛 / 静态过期文案', () => {
  // 12 位分钟档（moligod）
  assert(
    formatVersionLabel('202610131018') === '2026-10-13 10:18',
    `12 位应显示到分钟，实际 ${formatVersionLabel('202610131018')}`
  )
  // 10 位小时档（kkrb 兜底）维持 HH:00
  assert(
    formatVersionLabel('2026101310') === '2026-10-13 10:00',
    `10 位应显示 HH:00，实际 ${formatVersionLabel('2026101310')}`
  )
  assert(formatVersionLabel('') === '—', '空版本显示 —')

  const tM = staleness('moligod')
  const tK = staleness('kkrb')
  assert(tM.staleDotMin === 10 && tM.staleTipMin === 30, 'moligod 阈值应为 10/30 分钟')
  assert(tK.staleDotMin === 60 && tK.staleTipMin === 360, 'kkrb 阈值应沿用 60/360 分钟')

  assert(liveChannelUrl({ protocol: 'http:', hostname: 'localhost', origin: 'http://localhost:5173' }) === 'http://127.0.0.1:8787/events', '本地 http dev 应连独立 live 服务 8787')
  assert(liveChannelUrl({ protocol: 'http:', hostname: '127.0.0.1', origin: 'http://127.0.0.1:5173' }) === 'http://127.0.0.1:8787/events', '127.0.0.1 应连独立 live 服务 8787')
  assert(
    liveChannelUrl({ protocol: 'https:', hostname: 'example.com', origin: 'https://example.com' }) === 'https://example.com/events',
    'https 部署应连同源 /events（server.mjs 形态，无 CORS/mixed-content）'
  )
  assert(liveChannelUrl({ protocol: 'file:', hostname: '', origin: 'null' }) === null, 'file:// 打开无实时通道')
  assert(liveChannelUrl({}) === null, '缺环境信息应返回 null')

  const tipM = staleTipText('moligod', 42)
  assert(
    tipM.includes('42 分钟') && tipM.includes('历史快照'),
    `moligod 过期文案应如实注明分钟数与历史快照边界，实际：${tipM}`
  )
  // 分钟/小时/天分档：静态部署多天未更新时不得输出原始分钟数
  assert(staleTipText('moligod', 4320).includes('3 天'), `4320 分钟应显示「3 天」，实际：${staleTipText('moligod', 4320)}`)
  assert(!staleTipText('moligod', 4320).includes('4320'), '不得输出原始分钟数')
  assert(staleTipText('moligod', 300).includes('5 小时'), `300 分钟应显示「5 小时」，实际：${staleTipText('moligod', 300)}`)
  const tipK = staleTipText('kkrb', 420)
  assert(tipK.includes('7 小时') && !tipK.includes('历史快照'), `kkrb 过期文案应保持小时口径，实际：${tipK}`)
  assert(sourceLabel('moligod').includes('分钟级') && sourceLabel('kkrb').includes('小时级'), '更新粒度文案应按 source 切换')
})

/* ============================================================
   ⑫ 页面纯逻辑：预计卖出时间（历史到达历时 / 日内节律 / 时钟标签 / 通知文案）
   ============================================================ */
check('页面纯逻辑：预计卖出（历史到达历时 / 日内节律 / 时钟标签 / 通知文案）', () => {
  // 手搓 7 天小时曲线：19–21 点 120、02 点挖坑 80、其余 100（10-06 00:00 起，168 点）
  const mkCurve = (days = 7) => {
    const pts = []
    const t0 = new Date(2026, 9, 6, 0, 0)
    for (let k = 0; k < days * 24; k++) {
      const dt = new Date(t0.getTime() + k * 3600 * 1000)
      const key = `${dt.getFullYear()}${pad2(dt.getMonth() + 1)}${pad2(dt.getDate())}${pad2(dt.getHours())}00`
      const price = dt.getHours() >= 19 && dt.getHours() <= 21 ? 120 : dt.getHours() === 2 ? 80 : 100
      pts.push([key, price])
    }
    return pts
  }
  const curve = mkCurve()

  // 日内节律：连续 3 小时最高窗口应 19–22，高位比 02 点坑高 50%
  const prof = hourlyProfile(curve)
  assert(prof && prof.startHour === 19 && prof.endHour === 22, `高位窗口应 19–22，实际 ${prof && prof.startHour}-${prof && prof.endHour}`)
  assert(prof && prof.liftPct > 0.49 && prof.liftPct < 0.51, `涨幅应约 50%（80→120），实际 ${prof && prof.liftPct}`)

  // 历史到达历时：80 出发 → 首达 120；7 天每天一段（02→19 = 17 小时）
  const eps = reachEpisodes(curve, 80, 120)
  assert(eps.length === 7 && eps.every((h) => h === 17), `应得 7 段 × 17 小时，实际 [${eps.join(',')}]`)
  // 手搓短序列：段1 idx0→idx4 = 4 小时；段2 idx5→idx6 = 1 小时（升序返回）
  const eps2 = reachEpisodes([['a', 80], ['b', 90], ['c', 100], ['d', 110], ['e', 120], ['f', 80], ['g', 120]], 80, 120)
  assert(eps2.length === 2 && eps2[0] === 1 && eps2[1] === 4, `短序列应得 [1,4]，实际 [${eps2.join(',')}]`)

  // predictSellEta：现价 80 / 目标 120，注入时钟 10-13 15:00（晚于曲线末点 10-12 23:00）
  const now = new Date(2026, 9, 13, 15, 0).getTime()
  const e = predictSellEta({ current: 80, targetSell: 120, curve }, now)
  assert(e && e.atTarget === false, '现价低于目标不应判 atTarget')
  assert(e.medianH === 17 && e.fastestH === 17 && e.episodes === 7, `中位/最快应 17 小时 × 7 次，实际 ${e.medianH}/${e.fastestH}/${e.episodes}`)
  assert(e.etaLabel === '明日 08:00', `时钟标签应「明日 08:00」（15:00+17h），实际 ${e.etaLabel}`)
  assert(e.trend === 'flat', `末 6 点（18–23 时价 100/120/120/120/100/100）应判 flat，实际 ${e.trend}`)

  // atTarget 分支：现价已达挂卖价 → 无历时、只留日内高位
  const e2 = predictSellEta({ current: 120, targetSell: 120, curve }, now)
  assert(e2 && e2.atTarget && e2.medianH == null && e2.peakStart === 19, '已达目标价应判 atTarget 且保留日内节律')

  // 数据不足 / 容错分支
  assert(predictSellEta({ current: 100, targetSell: 120, curve: curve.slice(0, 10) }, now) === null, '曲线 <24 点应判数据不足')
  assert(predictSellEta(null) === null, '空条目应安全返回 null')
  const eNoTarget = predictSellEta({ curve }, now)
  assert(eNoTarget && eNoTarget.medianH == null && eNoTarget.peakStart === 19, '缺目标价应退化为只给日内节律、不给历时')

  // 可读化分档
  assert(fmtHours(5) === '5 小时' && fmtHours(2.5) === '2.5 小时' && fmtHours(72) === '3 天', `fmtHours 分档异常：${fmtHours(5)}/${fmtHours(2.5)}/${fmtHours(72)}`)
  assert(fmtPeak(19, 22) === '19–22 点' && fmtPeak(23, 2) === '23–次日 2 点', `fmtPeak 文案异常：${fmtPeak(19, 22)} / ${fmtPeak(23, 2)}`)

  // 通知文案：带曲线的条目追加 ETA / 日内时段；无曲线条目（⑤ 的形状）自动省略
  const line = buyLine({ name: '测试弹', current: 80, targetSell: 120, netSell: 102, netHigh: 110, profitPerRound: 22, profitPct: 0.275, curve })
  assert(line.includes('预计17 小时到价'), `买入通知应含预计历时，实际：${line}`)
  const lineOld = buyLine({ name: '测试弹', current: 80, targetSell: 120, netSell: 102, netHigh: 110, profitPerRound: 22, profitPct: 0.275 })
  assert(!lineOld.includes('预计'), '无曲线条目不应输出预计历时')
  const sLine = sellLine({ name: '测试弹', current: 120, rank: 0.9, curve })
  assert(sLine.includes('日内19–22 点最贵'), `卖出通知应含日内高位，实际：${sLine}`)

  // 日抛判定（dayTradeEta / isDayTradeItem）：卖价锚 = 现价税后回本线 + 5%，
  // fixture 现价 80 → sellFor = 80×1.05/0.85 ≈ 98.82；每天 02 点坑(80)→03 点(100)
  // 一段（1 小时）× 7 段，中位 1h ≤24h → 命中
  assert(DAY_TRADE_MAX_H === 24 && DAY_TRADE_MIN_NET_PCT === 0.05 && DAY_TRADE_MIN_EPISODES === 2,
    `日抛门槛常量异常：${DAY_TRADE_MAX_H}/${DAY_TRADE_MIN_NET_PCT}/${DAY_TRADE_MIN_EPISODES}`)
  const dtItem = { current: 80, taxRate: 0.15, curve }
  const dt = dayTradeEta(dtItem)
  assert(dt && dt.medianH === 1 && dt.episodes === 7, `日抛 ETA 应 1h × 7 段，实际 ${dt && dt.medianH}/${dt && dt.episodes}`)
  assert(Math.abs(dt.sellFor - 80 * 1.05 / 0.85) < 1e-9, `卖价锚应现价×(1+5%)/(1−税率)，实际 ${dt.sellFor}`)
  assert(isDayTradeItem(dtItem, dt), '中位 1h ≤24h 应判日抛')
  // 门槛分支：单样本拒判；中位超 24h 拒判（maxH 可注入覆写）；eta 复用与内部重算等价
  assert(!isDayTradeItem(dtItem, { medianH: 25, episodes: 3 }), '中位 25h 超门槛不应判日抛')
  assert(isDayTradeItem(dtItem, { medianH: 25, episodes: 3 }, 48), '注入 maxH=48 时 25h 应命中')
  assert(isDayTradeItem(dtItem), '缺省 eta 应内部重算并命中')
  // 现价处 7 天新低（fixture 曲线最低 80，现价 60）：无从该价位出发的历史 → 如实拒绝
  assert(dayTradeEta({ current: 60, taxRate: 0.15, curve }) === null, '现价低于全曲线（无历史先例）应返回 null')
  // 数据不足 / 容错：短曲线、缺税率、缺现价、空条目
  assert(dayTradeEta({ current: 80, taxRate: 0.15, curve: curve.slice(0, 10) }) === null, '曲线 <24 点应返回 null')
  assert(dayTradeEta({ current: 80, curve }) === null, '缺税率应返回 null')
  assert(dayTradeEta({ taxRate: 0.15, curve }) === null, '缺现价应返回 null')
  assert(dayTradeEta(null) === null && !isDayTradeItem(null), '空条目应安全返回 null / false')
})

/* ============================================================
   ⑫b 旁路参照：军需处兑换清洗/join + 赛季日历阶段（quartermaster / season /
   marketMeta.seasonPhase）——纯函数离线断言，不打外网
   ============================================================ */
check('旁路参照：军需处清洗/join 与赛季阶段 seasonPhase', async () => {
  const { normalizeTradeRow, fetchQuartermaster, resetQuartermasterCacheForTest, QUARTERMASTER_TTL_MS } = await import('./quartermaster.mjs')
  const { fetchSeason, resetSeasonCacheForTest } = await import('./season.mjs')
  const { seasonPhase } = await import('../../shared/js/marketMeta.js')
  const { joinQuartermaster, joinSeason } = await import('./fetch-once.mjs')

  // normalizeTradeRow：合法行保留关键字段、折算 = 材料总值/发数；非法行剔除
  const row = normalizeTradeRow({
    itemName: '5.45x39mm BT', perCount: 180, singlePrice: 1666, totalMaterialValue: 215184,
    totalMaterialLists: [
      { itemName: '水壶', count: 3, perPrice: 34712 },
      { itemName: '坏材料', count: 1, perPrice: 'x' }, // 非数剔除
    ],
  }, '202610271630')
  assert(row && row.name === '5.45x39mm BT', '合法行应保留')
  assert(Math.abs(row.costPerRound - 215184 / 180) < 0.01, `折算价应为总值/发数，实际 ${row.costPerRound}`)
  assert(row.materials.length === 1 && row.marketPrice === 1666, '非法材料应剔除、现价保留')
  assert(normalizeTradeRow({ itemName: '', perCount: 1 }) === null, '空名剔除')
  assert(normalizeTradeRow({ itemName: 'x', perCount: 0, singlePrice: 1, totalMaterialValue: 1 }) === null, 'perCount<1 剔除')

  // fetchQuartermaster：code!==1 抛出；TTL 生效（窗口内第二次调用不打桩）
  resetQuartermasterCacheForTest()
  let calls = 0
  const stubOk = async () => { calls++; return { code: 1, version: '202610271630', data: { cn: [{ itemName: '弹A', perCount: 100, singlePrice: 10, totalMaterialValue: 500, totalMaterialLists: [] }] } } }
  const t1 = await fetchQuartermaster({ now: 1000, request: stubOk })
  const t2 = await fetchQuartermaster({ now: 1000 + QUARTERMASTER_TTL_MS - 1, request: stubOk })
  assert(calls === 1 && t1.items.length === 1 && t2 === t1, 'TTL 内应命中缓存不再打桩')
  await fetchQuartermaster({ now: 1000 + QUARTERMASTER_TTL_MS, request: stubOk })
  assert(calls === 2, '过期后应重新拉取')
  resetQuartermasterCacheForTest()
  let threw = false
  try { await fetchQuartermaster({ now: 0, request: async () => ({ code: -101, msg: '繁忙' }) }) } catch { threw = true }
  assert(threw, '业务失败应抛出（调用方静默跳过 join）')

  // joinQuartermaster：按名精确合并 trade；无数据原样返回
  const items = [{ name: '弹A', current: 12 }, { name: '弹B', current: 5 }]
  const merged = joinQuartermaster(items, t1)
  assert(merged[0].trade && merged[0].trade.costPerRound === 5 && merged[1].trade === undefined, 'trade 应按名精确合并')
  assert(joinQuartermaster(items, null) === items, '无军需处数据应原样返回')

  // fetchSeason：起止倒挂 → null；正常 → 形状收敛（坏事件剔除）
  resetSeasonCacheForTest()
  const badSeason = await fetchSeason({ now: 0, request: async () => ({ code: 1, data: { seasonName: 'X', seasonStartTime: '2026-11-05T01:59:59+08:00', seasonEndTime: '2026-09-04T02:00:00+08:00', seasonEvent: [] } }) })
  assert(badSeason === null, '起止倒挂应返回 null')
  resetSeasonCacheForTest()
  const season = await fetchSeason({
    now: 0,
    request: async () => ({
      code: 1,
      data: {
        seasonName: 'S11赛季', seasonStartTime: '2026-09-04T02:00:00+08:00', seasonEndTime: '2026-11-05T01:59:59+08:00',
        seasonEvent: [{ name: '群星 赛季', start: '2026-09-04T02:00:00+08:00', end: '2026-11-05T01:59:59+08:00', type: 'ingame' }, { name: '坏事件', start: 'x', end: 'y' }],
      },
    }),
  })
  assert(season && season.name === 'S11赛季' && season.events.length === 1, '赛季形状收敛：坏事件剔除')

  // seasonPhase：四阶段边界（囤货窗 T−7~T−3 / 赛季末 T−3 / 开更 +3 / 常规）
  const S = { name: 'S11', start: '2026-09-04T02:00:00+08:00', end: '2026-11-05T01:59:59+08:00' }
  assert(seasonPhase(S, Date.parse('2026-09-05T00:00:00+08:00')).phase === 'fresh', '开更 ≤3 天 = 出货窗')
  assert(seasonPhase(S, Date.parse('2026-10-27T16:00:00+08:00')).phase === 'mid', '剩 8.4 天 = 常规期')
  assert(seasonPhase(S, Date.parse('2026-10-30T00:00:00+08:00')).phase === 'hoard', '剩 6.1 天 = 囤货窗')
  assert(seasonPhase(S, Date.parse('2026-11-02T00:00:00+08:00')).phase === 'hoard', '剩 3.08 天 = 囤货窗上界（T−7~T−3 含刚过 3 天）')
  assert(seasonPhase(S, Date.parse('2026-11-03T00:00:00+08:00')).phase === 'late', '剩 2.08 天 = 赛季末')
  assert(seasonPhase(null) === null && seasonPhase({ name: 'x', start: 'bad', end: 'bad' }) === null, '无效赛季返回 null')

  // joinSeason：顶层带上赛季；null 原样返回
  const analysis = { items: [], stats: {} }
  assert(joinSeason(analysis, season).season.name === 'S11赛季', 'season 应挂到顶层')
  assert(joinSeason(analysis, null) === analysis, '无赛季原样返回')
})

/* ============================================================
   ⑬ server.mjs 同源部署服务：静态托管 / 缓存头 / SSE·health 复用 / 防穿越
   ============================================================ */
check('server.mjs 同源部署服务：静态托管 / 缓存头 / SSE·health 复用 / 防穿越 / 雷达·特勤处广播', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'ammo-selftest-13-'))
  const dist = path.join(root, 'dist')
  await mkdir(path.join(dist, 'ammo'), { recursive: true })
  await mkdir(path.join(dist, 'assets'), { recursive: true })
  await writeFile(path.join(dist, 'index.html'), '<!doctype html><title>t</title>')
  await writeFile(path.join(dist, 'assets', 'app-abc.js'), 'x')
  await writeFile(path.join(dist, 'ammo', 'market.json'), '{}')
  await writeFile(path.join(root, 'secret.txt'), 'topsecret')
  // 雷达/特勤处循环均注入桩（不打外网；craftCycle 默认 runCraftCycle 会真实
  // 抓 moligod）：只验证「落盘后广播 event:radar / event:craft」的接线；
  // statePath 比照用例⑩指向临时目录——否则 live 的去抖 state 会写进仓库
  // 真实 data/ammo/monitor-state.json，与常驻监控进程并发写共享 state
  const radarOut = { version: '202610141200', stats: { total: 10, anomaly: 1, buy: 0, sell: 3, watch: 6 } }
  const craftOut = { version: '202610141200', stats: { total: 20, complete: 18, profitable: 9 } }
  const site = createSiteServer({
    rootDir: root,
    noNotify: true,
    statePath: path.join(root, 'data', 'ammo', 'monitor-state.json'),
    radarCycle: async () => radarOut,
    craftCycle: async () => craftOut,
  })
  try {
    await new Promise((resolve) => site.server.listen(0, '127.0.0.1', resolve))
    const port = site.server.address().port
    const base = `http://127.0.0.1:${port}`

    // 静态托管与缓存头：html/json no-cache（SSE 通知后自拉必须拿到新数据），
    // /assets/ 哈希文件 immutable 长缓存
    let r = await fetch(`${base}/`)
    assert(r.status === 200 && (await r.text()).includes('<title>'), '/ 应返回 index.html')
    assert(r.headers.get('cache-control') === 'no-cache', 'html 应 no-cache')
    r = await fetch(`${base}/assets/app-abc.js`)
    assert(r.status === 200 && /immutable/.test(r.headers.get('cache-control') || ''), '/assets/ 哈希文件应长缓存 immutable')
    r = await fetch(`${base}/ammo/market.json`)
    assert(
      r.status === 200 && /json/.test(r.headers.get('content-type') || '') && r.headers.get('cache-control') === 'no-cache',
      '数据 json 应 application/json + no-cache'
    )

    // /health 与 /events 复用 live 服务处理器
    r = await fetch(`${base}/health`)
    assert(r.status === 200 && (await r.json()).ok === true, '/health 应复用 live 返回 ok')
    const reader = new SseReader(port)
    await reader.start()
    const hello = await reader.waitFor('hello', 1500)
    const helloData = JSON.parse(hello.data)
    assert(typeof helloData === 'object' && 'version' in helloData && 'source' in helloData, 'SSE hello 应携带 {version, source}')
    assert(helloData.version === site.live.status.version, 'hello 版本应与服务状态一致')

    // 雷达落盘广播：注入桩触发一轮 → SSE 收到 event:radar（版本 + 统计）
    await site.triggerRadarCycle()
    const radar = await reader.waitFor('radar', 1500)
    const radarData = JSON.parse(radar.data)
    assert(
      radarData.version === radarOut.version && radarData.total === radarOut.stats.total && radarData.anomaly === 1,
      `radar 事件应携带版本与统计，实际 ${radar.data}`
    )
    // 特勤处制造落盘广播：同雷达桩模式 → event:craft（版本 + 统计）
    await site.triggerCraftCycle()
    const craft = await reader.waitFor('craft', 1500)
    const craftData = JSON.parse(craft.data)
    assert(
      craftData.version === craftOut.version && craftData.total === craftOut.stats.total && craftData.profitable === 9,
      `craft 事件应携带版本与统计，实际 ${craft.data}`
    )
    reader.close()

    // 防目录穿越：node 原生请求保留 %2e%2e（fetch 会提前归一化路径）
    const traversal = await new Promise((resolve, reject) => {
      http.get({ host: '127.0.0.1', port, path: '/%2e%2e/secret.txt' }, resolve).on('error', reject)
    })
    assert(
      [403, 404].includes(traversal.statusCode),
      `穿越请求应被拒绝（403/404），实际 ${traversal.statusCode}`
    )
  } finally {
    await site.close()
    await rm(root, { recursive: true, force: true })
  }
})

/* ============================================================
   可选：--online 追加真实上游连通性（默认跳过）
   ============================================================ */
if (ONLINE) {
  check('[online] 真实 moligod catalog / history 连通性', async () => {
    const { fetchCatalog, fetchHistory } = await import('./moligod-client.mjs')
    const cat = await fetchCatalog()
    assert(cat.status === 'ok' && cat.items.length >= 50, `真实 catalog 异常：${cat.items && cat.items.length} 条`)
    const pts = await fetchHistory(cat.items[0].name)
    assert(pts.length >= 24, `真实 history 点数不足：${pts.length}`)
    console.log(`      （真实源 ${cat.items.length} 种 / 首弹 ${pts.length} 点）`)
  })
}

/* ---------- 运行 ---------- */
let failed = 0
for (const [name, fn] of checks) {
  try {
    await fn()
    console.log(`✓ ${name}`)
  } catch (e) {
    failed++
    console.error(`✗ ${name}`)
    console.error(`    ${e.message}`)
  }
}
console.log(
  `\n${failed === 0 ? `全部 ${checks.length} 项通过` : `${failed}/${checks.length} 项失败`}` +
    `${ONLINE ? '（含 --online）' : '（离线模式，未打外网；--online 可追加真实源检查）'}`
)
process.exit(failed === 0 ? 0 : 1)
