// CraftModels.swift — 特勤处制造利润快照模型（契约 shared/API.md §1.3）
// 字段与 /craft/craft.json 一一对应；利润为上游预估值（材料现价买入 →
// 产出按现价×数量挂卖 → 扣手续费），本端只消费不另立口径。
// 最佳口径（三端一致）：missingPriceCount == 0 中 profitPerHour 最大。
import Foundation

/// 制造台（展示序由快照 places 数组给定：工作台 / 防具台 / 技术中心 / 制药台）
public struct CraftPlace: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// 材料或产物（共用形状）：count 数量、price 现价（缺价为 nil）
public struct CraftMaterial: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let grade: Int?
    public let pic: String?
    public let count: Int
    public let price: Double?
    /// 该材料的小计成本（单价 × 数量；缺价为 nil）
    public let cost: Double?

    public init(name: String, grade: Int? = nil, pic: String? = nil, count: Int = 1, price: Double? = nil, cost: Double? = nil) {
        self.name = name
        self.grade = grade
        self.pic = pic
        self.count = count
        self.price = price
        self.cost = cost
    }
}

/// 产物（材料形状 + 单价更新时刻）
public struct CraftOutput: Codable, Sendable, Hashable {
    public let name: String
    public let grade: Int?
    public let pic: String?
    public let count: Int
    public let price: Double?
    /// 价格更新时刻（北京墙钟 'YYYY-MM-DD HH:mm'，仅展示用）
    public let lastUpdate: String?
}

/// 单条制造配方（`/craft/craft.json` items[] 元素）
public struct CraftItem: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let place: String
    public let requiredLevel: Int?
    public let category: String?
    public let output: CraftOutput
    public let materials: [CraftMaterial]
    /// 材料成本 / 手续费 / 费率 / 产出收入（价×数量）
    public let cost: Double?
    public let fee: Double?
    public let feeRate: Double?
    public let revenue: Double?
    /// 预估净利润 = revenue − fee − cost
    public let profit: Double?
    /// 时利 = profit / periodHours（periodHours ≤ 0 时为 nil）
    public let profitPerHour: Double?
    /// 回报率 = profit / cost
    public let roi: Double?
    public let periodHours: Double?
    public let periodLabel: String?
    /// 今日 / 7 日最高利润（乐观参照，非承诺）
    public let todayMaxProfit: Double?
    public let sevenDayMaxProfit: Double?
    /// 材料或产出缺价计数；> 0 时利润估算不可用
    public let missingPriceCount: Int

    public var isComplete: Bool { missingPriceCount == 0 }
    public var hasEstimate: Bool { isComplete && profit != nil }
}

public struct CraftStats: Codable, Sendable, Hashable {
    public let total: Int
    public let complete: Int
    public let profitable: Int
}

/// 快照顶层（`/craft/craft.json`）
public struct CraftSnapshot: Codable, Sendable, Hashable {
    public let version: String
    public let fetchedAt: Date
    public let generatedAt: Date
    public let source: String
    public let places: [CraftPlace]
    public let items: [CraftItem]
    public let stats: CraftStats

    /// 制造台 id → 展示文案
    public func placeLabel(_ id: String) -> String? {
        places.first { $0.id == id }?.label
    }

    /// 最佳口径（三端一致）：价格完整的配方中时利最大；无候选返回 nil
    public func best(place: String? = nil) -> CraftItem? {
        items
            .filter { ($0.isComplete && $0.profitPerHour != nil) && (place == nil || $0.place == place) }
            .max { ($0.profitPerHour ?? 0) < ($1.profitPerHour ?? 0) }
    }
}
