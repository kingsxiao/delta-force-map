/* ============================================================
   notify-policy.js — 信号通知去抖策略（三端同构，唯一事实来源在 shared）
   ------------------------------------------------------------
   消费方：服务端 monitor.mjs / live.mjs / market/radar.mjs（macOS 系统
   通知）、网页端 AmmoMarketView（浏览器通知）、iOS NotifyPolicy.swift
   （同口径移植，单测用 shared/fixtures 对拍）。改这里 = 改三端口径。
   分钟级数据源下，rank 在 0.25 / 0.80 分位边界抖动会让信号来回翻转，
   在原 monitor 的去重规则上增加 streak 确认与全量逐轮记录：
     · state.items 每轮全量记录每个弹的当前信号（含 WAIT）与 streak
       （同信号连续轮数）——只记被通知过的弹，streak 无从计算
     · 首次出现（无 prev）         → 立即通知
     · 信号切换                    → 需 streak ≥ 2（连续两轮同新信号）才通知
     · 同信号 6 小时冷却到期        → 通知
     · BUY 较上次通知价累计再跌 5%  → 重报（渐进阴跌也按累计跌幅触发）
   state.items[name] = { signal, price, at(上次通知时刻), streak }
   参数集中在此可直接调；服务端本文件被 selftest.mjs 覆盖。
   ============================================================ */
import { predictSellEta, fmtHours, fmtPeak } from './sellEta.js'

export const POLICY = {
  COOLDOWN_MS: 6 * 60 * 60 * 1000, // 同信号冷却
  REDROP_PCT: 0.05, // BUY 冷却期内深跌阈值
  SWITCH_STREAK_MIN: 2, // 信号切换需连续确认的轮数
}

export function emptyState() {
  return { items: {} }
}

/* 价格 / 收益率格式化：与 server/ammo/analyze.mjs、网页端页面 fmt 同款
   （整数哈夫币 / +27.6%），通知文案三端逐字一致的前提 */
const fmtPrice = (n) => (Number.isFinite(n) ? Math.round(n).toLocaleString('zh-CN') : '—')
const fmtPct = (n) => (Number.isFinite(n) ? `${n >= 0 ? '+' : ''}${(n * 100).toFixed(1)}%` : '—')

/** 买入通知正文：哪种子弹 / 多少价格买 / 什么时候卖 / 能赚多少
    （预计到价历时吃条目自带 curve 统计，曲线不足时自动省略该段） */
export function buyLine(i) {
  const high = `7天高点到手${fmtPrice(i.netHigh)}`
  const eta = predictSellEta(i)
  // 历时展示门槛：至少 2 次完整上涨样本，单样本中位不进通知
  const etaTxt = eta && eta.medianH != null && eta.episodes >= 2 ? ` 预计${fmtHours(eta.medianH)}到价` : ''
  return `${i.name} 买入≤${fmtPrice(i.current)} → 挂卖${fmtPrice(i.targetSell)}(到手${fmtPrice(i.netSell)})${etaTxt} 预赚${fmtPrice(i.profitPerRound)}/发(${fmtPct(i.profitPct)})，${high}`
}

export function sellLine(i) {
  const eta = predictSellEta(i)
  const peak = eta && eta.peakStart != null ? `，日内${fmtPeak(eta.peakStart, eta.peakEnd)}最贵` : ''
  return `${i.name} 现价${fmtPrice(i.current)}，处7天${Math.round(i.rank * 100)}%高位${peak}，建议挂卖`
}

/**
 * 一轮信号判定：全量记录 + 决定哪些 BUY / SELL 值得通知（就地修改 state）。
 * @param {object} state 持久化状态（服务端 monitor-state.json / 网页端 localStorage）
 * @param {Array} items analysis.items 全量（含 WAIT）
 * @param {number} now 可注入时钟（自测用）
 * @returns {{buys:Array, sells:Array}} 通过去抖、需要通知的项
 *
 * 语义（按优先级）：
 *   1. 首次出现（无 prev）→ 立即通知
 *   2. 信号切换的当轮（prev 还是旧信号）→ 不通知，等下一轮确认
 *   3. 新信号连续第 2 轮且本轮尚未通知过（runNotified）→ 通知（确认轮）
 *   4. 同信号 6h 冷却到期 → 通知
 *   5. BUY 较上次通知价（refPrice）累计再跌 ≥5% → 重报。参考价只在触发
 *      时刷新，不随逐轮观察价漂移——否则渐进阴跌（每轮跌幅 <5%）永远
 *      不触发；旧 state 无 refPrice 时回退 price（旧版即「上次通知价」）
 */
export function judgeSignals(state, items, now = Date.now()) {
  const buys = []
  const sells = []
  const next = {}
  for (const it of items || []) {
    const signal = it.signal
    const prev = state.items[it.name]
    const sameRun = !!prev && prev.signal === signal
    const streak = sameRun ? (prev.streak || 0) + 1 : 1

    let fire = false
    if (!prev) fire = true
    else if (sameRun) {
      if (!prev.runNotified && streak >= POLICY.SWITCH_STREAK_MIN) fire = true
      else if (now - (prev.at || 0) >= POLICY.COOLDOWN_MS) fire = true
      else if (
        signal === 'BUY' &&
        (prev.refPrice ?? prev.price) &&
        Number.isFinite(it.current) &&
        it.current <= (prev.refPrice ?? prev.price) * (1 - POLICY.REDROP_PCT)
      ) {
        fire = true
      }
    }
    // else：切换当轮（streak=1）不通知，等下一轮进入 sameRun 确认

    if (fire && signal === 'BUY') buys.push(it)
    if (fire && signal === 'SELL') sells.push(it)
    next[it.name] = {
      signal,
      price: Number.isFinite(it.current) ? it.current : null,
      // 深跌参考价：触发通知或新信号轮开始时重置为当时价，否则沿用——
      // 判定用累计跌幅，不被逐轮观察价冲淡
      refPrice:
        fire || !sameRun
          ? Number.isFinite(it.current) ? it.current : null
          : prev.refPrice ?? prev.price ?? null,
      at: fire ? now : prev && prev.at ? prev.at : 0,
      streak,
      runNotified: sameRun ? !!(prev.runNotified || fire) : fire,
    }
  }
  state.items = next
  return { buys, sells }
}

/** 通知发送（通知正文与条数上限沿用 monitor 原口径：最多报 3 条，其余进页面）。
    notifyFn 为注入投递器：服务端传 osascript 通知、网页端传浏览器 Notification。 */
export async function sendNotifications(buys, sells, notifyFn) {
  if (buys.length) {
    const top = buys.slice(0, 3)
    const body = top.map((i) => `🎯 ${buyLine(i)}`).join('\n')
    await notifyFn({
      title: `三角洲子弹买入信号 ×${buys.length}`,
      body: buys.length > top.length ? body + `\n…还有${buys.length - top.length}种见 #/ammo 页` : body,
      sound: 'Glass',
    })
  }
  if (sells.length) {
    const top = sells.slice(0, 3)
    const body = top.map((i) => `📈 ${sellLine(i)}`).join('\n')
    await notifyFn({
      title: `三角洲子弹卖出信号 ×${sells.length}`,
      body: sells.length > top.length ? body + `\n…还有${sells.length - top.length}种见 #/ammo 页` : body,
      sound: 'Hero',
    })
  }
}
