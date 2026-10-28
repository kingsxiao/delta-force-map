// Models.swift — 快照 / 事件 / 健康状态的数据模型
// 字段与 shared/schema/*.schema.json 一一对应（契约见 shared/API.md）。
// 子弹行情与异动雷达共用 MarketItem：雷达特有字段（hiRank / category /
// crossDev / anomaly …）为可选，图表与详情页因此可以完全复用。
import Foundation

/// 买卖信号（口径：server/ammo/analyze.mjs，三端不得另立）
public enum Signal: String, Codable, Sendable, CaseIterable, Hashable {
    case buy = "BUY"
    case watch = "WATCH"
    case sell = "SELL"
    case wait = "WAIT"

    public var label: String {
        switch self {
        case .buy: "买入"
        case .watch: "关注"
        case .sell: "卖出"
        case .wait: "观望"
        }
    }

    /// 与 analyze.mjs SIGNAL_META.hint 逐字同步（v2 口径；analyze.mjs 该处头注已标注为 iOS 文案镜像源）
    public var hint: String {
        switch self {
        case .buy: "低位企稳且趋势走平向上，挂卖近3天P75税后仍有≥10%利润"
        case .watch: "接近低位但未同时满足止跌/趋势/利差门槛，先挂限价观察"
        case .sell: "贴近7天高位且动能转弱，持仓建议挂卖离场"
        case .wait: "价格处于中位区间或仍在下行，不动手"
        }
    }
}

/// 曲线点：JSON 形状为 `["202610071100", 288]`（时间键双格式：12 位分钟档 / 10 位小时档）
public struct CurvePoint: Sendable, Hashable, Codable {
    public let key: String
    public let price: Double

    public init(key: String, price: Double) {
        self.key = key
        self.price = price
    }

    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        key = try c.decode(String.self)
        price = try c.decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(key)
        try c.encode(price)
    }
}

/// 官方均价参照（腾讯 AMS 对账口径；契约 shared/API.md §1 items[].official）。
/// 旁路参照：不进任何信号计算；快照无锚时字段不出现。
public struct OfficialPrice: Codable, Sendable, Hashable {
    public let avg: Double
    public let dev: Double
    public let at: String?

    public init(avg: Double, dev: Double, at: String? = nil) {
        self.avg = avg
        self.dev = dev
        self.at = at
    }
}

/// 军需处兑换折算（kkrb 军需处兑换接口；契约 shared/API.md §1 items[].trade）。
/// 旁路参照：不进任何信号计算；仅约 7 种可兑换弹有此字段。
public struct AmmoTrade: Codable, Sendable, Hashable {
    public let costPerRound: Double
    public let perCount: Int
    public let marketPrice: Double
    public let materials: [TradeMaterial]?
    public let version: String?

    public struct TradeMaterial: Codable, Sendable, Hashable {
        public let name: String
        public let count: Int
        public let perPrice: Double

        public init(name: String, count: Int, perPrice: Double) {
            self.name = name
            self.count = count
            self.perPrice = perPrice
        }
    }

    public init(costPerRound: Double, perCount: Int, marketPrice: Double, materials: [TradeMaterial]? = nil, version: String? = nil) {
        self.costPerRound = costPerRound
        self.perCount = perCount
        self.marketPrice = marketPrice
        self.materials = materials
        self.version = version
    }
}

/// 单个物品的分析结果（子弹与雷达物品共用）
public struct MarketItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }

    public let name: String
    public let grade: Int?
    public let pic: String?
    public let current: Double?
    public let taxRate: Double
    public let curve: [CurvePoint]
    /// 现价在 7 天曲线中的分位；nil = 数据不足（曲线 <24 点，signal 恒 WAIT）
    public let rank: Double?
    public let p10: Double?
    public let p25: Double?
    public let p50: Double?
    public let p75: Double?
    public let p90: Double?
    public let weekHigh: Double?
    public let weekLow: Double?
    public let p75Local: Double?
    public let targetSell: Double?
    public let netSell: Double?
    public let netHigh: Double?
    public let profitPerRound: Double?
    public let profitPct: Double?
    /// 近 48h 回归斜率（%/h）；BUY 需 ≥ +0.02，SELL 动量守则 > 0.05 不催卖
    public let slope48: Double?
    /// 7 天最低价距今小时数（BUY 需 ≥12：止跌确认）
    public let lowAgeH: Double?
    /// 现价相对 7 天低点离底幅度（BUY 需 ≥ 0.03）
    public let bounceOffLow: Double?
    /// 止损位：跌破 7 天低点 3% 或离场风险上限（现价 −5%）的大者；nil = 旧快照无此字段
    public let stopLoss: Double?
    /// 建议最长持有小时数（回测口径 168h = 7 天）；nil = 旧快照无此字段
    public let maxHoldH: Double?
    /// 现价相对 24h 前的涨跌幅（展示特征，不进判定）；nil = 曲线不足 25 点或旧快照
    public let chg24h: Double?
    /// 现价相对窗口首点（约 7 天前）的涨跌幅（展示特征，不进判定）；nil = 旧快照
    public let chg7d: Double?
    /// 官方均价参照（旁路参照不进信号）；nil = 无锚 / 旧快照
    public let official: OfficialPrice?
    /// 军需处兑换折算（旁路参照不进信号）；nil = 不可兑换弹 / 旧快照
    public let trade: AmmoTrade?
    public let signal: Signal
    public let reason: String?

    // ---- 雷达专有 ----
    public let hiRank: Int?
    public let category: String?
    public let crossDev: Double?
    public let crossOverlap: Int?
    public let anomaly: Bool?
    public let rawSignal: Signal?
    public let curveSource: String?

    public init(
        name: String, grade: Int? = nil, pic: String? = nil, current: Double?, taxRate: Double = 0.15,
        curve: [CurvePoint], rank: Double? = nil, p10: Double? = nil, p25: Double? = nil, p50: Double? = nil,
        p75: Double? = nil, p90: Double? = nil, weekHigh: Double? = nil, weekLow: Double? = nil,
        p75Local: Double? = nil, targetSell: Double? = nil, netSell: Double? = nil, netHigh: Double? = nil,
        profitPerRound: Double? = nil, profitPct: Double? = nil, slope48: Double? = nil, lowAgeH: Double? = nil,
        bounceOffLow: Double? = nil, stopLoss: Double? = nil, maxHoldH: Double? = nil,
        chg24h: Double? = nil, chg7d: Double? = nil, official: OfficialPrice? = nil, trade: AmmoTrade? = nil,
        signal: Signal, reason: String? = nil,
        hiRank: Int? = nil, category: String? = nil, crossDev: Double? = nil, crossOverlap: Int? = nil,
        anomaly: Bool? = nil, rawSignal: Signal? = nil, curveSource: String? = nil
    ) {
        self.name = name
        self.grade = grade
        self.pic = pic
        self.current = current
        self.taxRate = taxRate
        self.curve = curve
        self.rank = rank
        self.p10 = p10
        self.p25 = p25
        self.p50 = p50
        self.p75 = p75
        self.p90 = p90
        self.weekHigh = weekHigh
        self.weekLow = weekLow
        self.p75Local = p75Local
        self.targetSell = targetSell
        self.netSell = netSell
        self.netHigh = netHigh
        self.profitPerRound = profitPerRound
        self.profitPct = profitPct
        self.slope48 = slope48
        self.lowAgeH = lowAgeH
        self.bounceOffLow = bounceOffLow
        self.stopLoss = stopLoss
        self.maxHoldH = maxHoldH
        self.chg24h = chg24h
        self.chg7d = chg7d
        self.official = official
        self.trade = trade
        self.signal = signal
        self.reason = reason
        self.hiRank = hiRank
        self.category = category
        self.crossDev = crossDev
        self.crossOverlap = crossOverlap
        self.anomaly = anomaly
        self.rawSignal = rawSignal
        self.curveSource = curveSource
    }

    public var isAnomaly: Bool { anomaly ?? false }
    public var hasEnoughData: Bool { rank != nil }
}

public struct SnapshotStats: Codable, Sendable, Hashable {
    public let total: Int
    public let buy: Int
    public let sell: Int
    public let watch: Int
    public let anomaly: Int?

    public init(total: Int, buy: Int, sell: Int, watch: Int, anomaly: Int? = nil) {
        self.total = total
        self.buy = buy
        self.sell = sell
        self.watch = watch
        self.anomaly = anomaly
    }
}

/// 快照顶层 `rules`（`analyze.mjs` RULES_VIEW_KEYS 展示子集；契约 shared/API.md §1）：
/// 门槛文案与分位刻度从这里渲染、不得写死数字；null = 该门槛关闭（如市场体制门槛
/// BUY_MKT_SLOPE_MIN）。逐字段宽松解码（try?）——形状异常时退 nil 而非让整张快照
/// 解码失败，渲染端有 v2 定稿值兜底（AmmoView MethodNote 同 web ruleNum 缺省做法）
public struct MarketRules: Codable, Sendable, Hashable {
    /// 现价分位买入门槛（7 天窗口，0.20）
    public let buyRankMax: Double?
    /// 对目标挂卖价的税后净收益率下限（0.10）
    public let buyMinNetPct: Double?
    /// 关注分位门槛（0.35）
    public let watchRankMax: Double?
    /// 卖出分位门槛（0.80）
    public let sellRankMin: Double?
    /// 市场体制门槛（全市场 48h 斜率中位下限，%/h）；null = 关闭
    public let buyMktSlopeMin: Double?
    /// 建议最长持有（小时）
    public let maxHoldH: Double?
    /// 目标价体制窗口（小时）
    public let targetWindowH: Double?

    enum CodingKeys: String, CodingKey {
        case buyRankMax = "BUY_RANK_MAX"
        case buyMinNetPct = "BUY_MIN_NET_PCT"
        case watchRankMax = "WATCH_RANK_MAX"
        case sellRankMin = "SELL_RANK_MIN"
        case buyMktSlopeMin = "BUY_MKT_SLOPE_MIN"
        case maxHoldH = "MAX_HOLD_H"
        case targetWindowH = "TARGET_WINDOW_H"
    }

    public init(
        buyRankMax: Double? = nil, buyMinNetPct: Double? = nil, watchRankMax: Double? = nil,
        sellRankMin: Double? = nil, buyMktSlopeMin: Double? = nil, maxHoldH: Double? = nil,
        targetWindowH: Double? = nil
    ) {
        self.buyRankMax = buyRankMax
        self.buyMinNetPct = buyMinNetPct
        self.watchRankMax = watchRankMax
        self.sellRankMin = sellRankMin
        self.buyMktSlopeMin = buyMktSlopeMin
        self.maxHoldH = maxHoldH
        self.targetWindowH = targetWindowH
    }

    public init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        // let 属性不能在委托 self.init() 之后再赋值：先解出各字段、统一走指定初始化器
        self.init(
            buyRankMax: try? c.decodeIfPresent(Double.self, forKey: .buyRankMax),
            buyMinNetPct: try? c.decodeIfPresent(Double.self, forKey: .buyMinNetPct),
            watchRankMax: try? c.decodeIfPresent(Double.self, forKey: .watchRankMax),
            sellRankMin: try? c.decodeIfPresent(Double.self, forKey: .sellRankMin),
            buyMktSlopeMin: try? c.decodeIfPresent(Double.self, forKey: .buyMktSlopeMin),
            maxHoldH: try? c.decodeIfPresent(Double.self, forKey: .maxHoldH),
            targetWindowH: try? c.decodeIfPresent(Double.self, forKey: .targetWindowH)
        )
    }
}

/// 快照顶层（`/ammo/market.json` 与 `/market/radar.json` 共用；`signals` 字段是 items 的过滤副本，客户端自行过滤故不解码）
public struct MarketSnapshot: Codable, Sendable, Hashable {
    public let version: String
    public let fetchedAt: Date
    public let generatedAt: Date
    public let source: String
    public let fingerprint: String?
    public let items: [MarketItem]
    public let stats: SnapshotStats?
    /// 信号门槛展示子集；nil = 旧快照无此字段（雷达快照亦无）——渲染端退 v2 定稿值兜底
    public let rules: MarketRules?

    public init(version: String, fetchedAt: Date, generatedAt: Date, source: String, fingerprint: String? = nil, items: [MarketItem], stats: SnapshotStats? = nil, rules: MarketRules? = nil) {
        self.version = version
        self.fetchedAt = fetchedAt
        self.generatedAt = generatedAt
        self.source = source
        self.fingerprint = fingerprint
        self.items = items
        self.stats = stats
        self.rules = rules
    }

    public func items(with signal: Signal) -> [MarketItem] { items.filter { $0.signal == signal } }
    public var isMinuteGrained: Bool { source == "moligod" }
}

/// GET /health
public struct HealthStatus: Codable, Sendable, Hashable {
    public let ok: Bool
    public let source: String?
    public let version: String?
    public let generatedAt: String?
    public let lastSuccessAt: String?
    public let consecutiveFailures: Int?
    public let cycles: Int?
}

/// SSE 命名事件的 data 负载（hello / market / radar / craft 四者字段并集，均为轻量 ping）
public struct LivePing: Codable, Sendable, Hashable {
    public let version: String?
    public let source: String?
    public let generatedAt: String?
    public let total: Int?
    public let anomaly: Int?
    public let buy: Int?
    public let sell: Int?
    public let complete: Int?
    public let profitable: Int?

    public init(version: String?, source: String? = nil, generatedAt: String? = nil, total: Int? = nil, anomaly: Int? = nil, buy: Int? = nil, sell: Int? = nil, complete: Int? = nil, profitable: Int? = nil) {
        self.version = version
        self.source = source
        self.generatedAt = generatedAt
        self.total = total
        self.anomaly = anomaly
        self.buy = buy
        self.sell = sell
        self.complete = complete
        self.profitable = profitable
    }
}

public enum LiveEvent: Sendable, Hashable {
    case hello(LivePing)
    case market(LivePing)
    case radar(LivePing)
    case craft(LivePing)
    case other(name: String, data: String)

    /// 把原始 SSE 事件映射为契约事件；data 解析失败也不丢事件（退化为 version=nil 的 ping）
    public static func parse(_ event: SSEEvent) -> LiveEvent {
        let ping = (try? JSONDecoder.deltaForce().decode(LivePing.self, from: Data(event.data.utf8)))
            ?? LivePing(version: nil)
        switch event.name {
        case "hello": return .hello(ping)
        case "market": return .market(ping)
        case "radar": return .radar(ping)
        case "craft": return .craft(ping)
        default: return .other(name: event.name, data: event.data)
        }
    }
}

public extension JSONDecoder {
    /// 契约专用解码器：ISO-8601 日期兼容带 / 不带小数秒（Node `toISOString()` 带毫秒）
    static func deltaForce() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle().parse(raw) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "无法解析日期：\(raw)"))
        }
        return decoder
    }
}
