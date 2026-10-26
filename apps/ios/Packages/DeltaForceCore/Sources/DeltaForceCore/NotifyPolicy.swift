// NotifyPolicy.swift — shared/js/notify-policy.js 的同构移植（信号通知去抖）
// 分钟级数据在 0.25 / 0.80 分位边界抖动会让信号来回翻转，规则：
//   · 每轮全量记录每个物品的当前信号与 streak（同信号连续轮数）
//   · 首次出现（无 prev）         → 立即通知
//   · 信号切换                    → 需 streak ≥ 2（连续两轮同新信号）才通知
//   · 同信号 6 小时冷却到期        → 通知
//   · BUY 较上次通知价累计再跌 5%  → 重报（参考价只在触发时刷新，渐进阴跌也按累计跌幅触发）
// iOS 端用它驱动本地通知（UNUserNotificationCenter 在 App 壳里），state 持久化到 UserDefaults。
import Foundation

public struct NotifyPolicy: Sendable, Hashable {
    /// 同信号冷却
    public var cooldown: TimeInterval = 6 * 60 * 60
    /// BUY 冷却期内深跌阈值
    public var redropPct: Double = 0.05
    /// 信号切换需连续确认的轮数
    public var switchStreakMin: Int = 2

    public init(cooldown: TimeInterval = 6 * 60 * 60, redropPct: Double = 0.05, switchStreakMin: Int = 2) {
        self.cooldown = cooldown
        self.redropPct = redropPct
        self.switchStreakMin = switchStreakMin
    }

    public static let `default` = NotifyPolicy()
}

public struct NotifyItemState: Codable, Sendable, Hashable {
    public var signal: Signal
    public var price: Double?
    /// 深跌参考价：触发通知或新信号轮开始时重置为当时价
    public var refPrice: Double?
    /// 上次通知时刻（秒级时间戳；0 = 从未通知）
    public var at: TimeInterval
    public var streak: Int
    public var runNotified: Bool

    public init(signal: Signal, price: Double?, refPrice: Double?, at: TimeInterval, streak: Int, runNotified: Bool) {
        self.signal = signal
        self.price = price
        self.refPrice = refPrice
        self.at = at
        self.streak = streak
        self.runNotified = runNotified
    }
}

public struct NotifyState: Codable, Sendable, Hashable {
    public var items: [String: NotifyItemState]
    public init(items: [String: NotifyItemState] = [:]) { self.items = items }
}

public struct NotifyVerdict: Sendable, Hashable {
    public let buys: [MarketItem]
    public let sells: [MarketItem]
    public var isEmpty: Bool { buys.isEmpty && sells.isEmpty }
}

public enum NotifyEngine {
    /// 一轮信号判定：全量记录 + 决定哪些 BUY / SELL 值得通知（就地修改 state）
    public static func judge(state: inout NotifyState, items: [MarketItem], now: Date = .now, policy: NotifyPolicy = .default) -> NotifyVerdict {
        let nowTs = now.timeIntervalSince1970
        var buys: [MarketItem] = []
        var sells: [MarketItem] = []
        var next: [String: NotifyItemState] = [:]
        for it in items {
            let signal = it.signal
            let prev = state.items[it.name]
            let sameRun = prev != nil && prev!.signal == signal
            let streak = sameRun ? (prev!.streak) + 1 : 1

            var fire = false
            if let prev {
                if sameRun {
                    if !prev.runNotified, streak >= policy.switchStreakMin {
                        fire = true
                    } else if nowTs - prev.at >= policy.cooldown {
                        fire = true
                    } else if signal == .buy,
                              let ref = prev.refPrice ?? prev.price, ref != 0,
                              let cur = it.current, cur.isFinite,
                              cur <= ref * (1 - policy.redropPct) {
                        fire = true
                    }
                }
                // 切换当轮（streak=1）不通知，等下一轮进入 sameRun 确认
            } else {
                fire = true
            }

            if fire, signal == .buy { buys.append(it) }
            if fire, signal == .sell { sells.append(it) }

            let cur: Double? = (it.current?.isFinite ?? false) ? it.current : nil
            next[it.name] = NotifyItemState(
                signal: signal,
                price: cur,
                refPrice: (fire || !sameRun) ? cur : (prev?.refPrice ?? prev?.price),
                at: fire ? nowTs : (prev?.at ?? 0),
                streak: streak,
                runNotified: sameRun ? (prev!.runNotified || fire) : fire
            )
        }
        state.items = next
        return NotifyVerdict(buys: buys, sells: sells)
    }

    /// 买入通知正文：哪种子弹 / 多少价格买 / 什么时候卖 / 能赚多少 / 破哪里止损
    /// （历时需 ≥2 次完整上涨样本；stopLoss 为旧快照缺失字段时省略止损段）
    public static func buyLine(_ i: MarketItem, now: Date = .now) -> String {
        let high = "7天高点到手\(Fmt.price(i.netHigh))"
        let eta = SellEtaEngine.predict(item: i, now: now)
        var etaTxt = ""
        if let eta, let med = eta.medianH, eta.episodes >= 2 {
            etaTxt = " 预计\(SellEtaEngine.fmtHours(med))到价"
        }
        var stopTxt = ""
        if let stop = i.stopLoss, stop.isFinite {
            stopTxt = "，破\(Fmt.price(stop))止损"
        }
        return "\(i.name) 买入≤\(Fmt.price(i.current)) → 挂卖\(Fmt.price(i.targetSell))(到手\(Fmt.price(i.netSell)))\(etaTxt) 预赚\(Fmt.price(i.profitPerRound))/发(\(Fmt.pct(i.profitPct)))，\(high)\(stopTxt)"
    }

    public static func sellLine(_ i: MarketItem, now: Date = .now) -> String {
        let eta = SellEtaEngine.predict(item: i, now: now)
        var peak = ""
        if let eta, eta.peakStart != nil, let p = SellEtaEngine.fmtPeak(start: eta.peakStart, end: eta.peakEnd) {
            peak = "，日内\(p)最贵"
        }
        let rankPct = Int(MarketMeta.jsRound((i.rank ?? 0) * 100))
        return "\(i.name) 现价\(Fmt.price(i.current))，处7天\(rankPct)%高位\(peak)，建议挂卖"
    }
}
