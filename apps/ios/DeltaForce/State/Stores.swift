// Stores.swift — 本地持久化状态（UserDefaults 即可：都是 KB 级小数据）
import DeltaForceCore
import Foundation
import Observation

struct ServerSettings: Codable, Equatable, Sendable {
    /// 信号本地通知（买入 / 卖出，去抖口径同后端 notify-policy）
    var notificationsEnabled: Bool = false

    static let storageKey = "settings.v1"
}

@MainActor
@Observable
final class SettingsStore {
    var settings: ServerSettings {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: ServerSettings.storageKey),
           let s = try? JSONDecoder().decode(ServerSettings.self, from: data) {
            settings = s
        } else {
            settings = ServerSettings()
        }
    }

    private let defaults: UserDefaults

    /// 后端地址固定写死（APIClient.productionBaseURL），App 只连这一台服务器
    let client = APIClient(baseURL: APIClient.productionBaseURL)

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: ServerSettings.storageKey)
        }
    }
}

@MainActor
@Observable
final class FavoritesStore {
    private(set) var names: Set<String>
    private let defaults: UserDefaults
    private static let key = "favorites.v1"

    /// 用户交互 toggle 后回调（AppModel 接云同步防抖上推；云合并落地走 replaceAll 不触发）
    var onUserToggle: (([String]) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        names = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func contains(_ name: String) -> Bool { names.contains(name) }

    func toggle(_ name: String) {
        if names.contains(name) { names.remove(name) } else { names.insert(name) }
        defaults.set(Array(names).sorted(), forKey: Self.key)
        onUserToggle?(Array(names).sorted())
    }

    /// 云端合并落地（不触发 onUserToggle，避免推拉循环）
    func replaceAll(_ newNames: [String]) {
        names = Set(newNames)
        defaults.set(Array(names).sorted(), forKey: Self.key)
    }

    var sortedNames: [String] { Array(names).sorted() }
}

/// 囤货台账条目：弹名 + 数量 + 成本单价（哈夫币/发）+ 记账时刻（epoch ms，可选）。
/// 本地 UserDefaults 存档，登录后经账号云同步（ledger.ammo）与云端按名合并
/// （契约 shared/API.md §6.3）。at 缺省 = 旧存档未记录（合成 Codable 双向兼容）。
struct AmmoPosition: Codable, Sendable, Hashable, Identifiable {
    let name: String
    var qty: Int
    var cost: Double
    var at: Double?
    var id: String { name }
}

/// 囤货台账（UserDefaults 编码存 [AmmoPosition]，独立 key 不动 favorites.v1；
/// FavoritesStore 同模式）：行情页「我的囤货」区块与详情页成本试算共用，
/// 浮盈 / 到价状态按当前行情快照实时 join 计算，存储里只有账本事实。
@MainActor
@Observable
final class PositionsStore {
    private(set) var positions: [AmmoPosition]
    private let defaults: UserDefaults
    private static let key = "positions.v1"

    /// 用户改台账（upsert / remove）后回调（AppModel 接云同步防抖上推；云合并落地走 replaceAll 不触发）
    var onUserChange: (([LedgerEntry]) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([AmmoPosition].self, from: data) {
            positions = list
        } else {
            positions = []
        }
    }

    func contains(_ name: String) -> Bool { positions.contains { $0.name == name } }

    func position(of name: String) -> AmmoPosition? { positions.first { $0.name == name } }

    /// 同名即同一条：更新或追加后立即落盘。at：调用方未带且已有条目记录过时
    /// 保留原记账时刻（改数量 / 成本不算重新记账），新条目取当下
    func upsert(_ p: AmmoPosition) {
        var entry = p
        if let i = positions.firstIndex(where: { $0.name == p.name }) {
            if entry.at == nil { entry.at = positions[i].at }
            positions[i] = entry
        } else {
            if entry.at == nil { entry.at = Double(Date.now.timeIntervalSince1970 * 1000) }
            positions.append(entry)
        }
        persist()
        onUserChange?(ledgerEntries)
    }

    func remove(_ name: String) {
        positions.removeAll { $0.name == name }
        persist()
        onUserChange?(ledgerEntries)
    }

    /// 云端合并落地（不触发 onUserChange，避免推拉循环）
    func replaceAll(_ entries: [LedgerEntry]) {
        positions = entries.map { AmmoPosition(name: $0.name, qty: $0.qty, cost: $0.cost, at: $0.at) }
        persist()
    }

    /// 云同步视角的台账（LedgerEntry = 契约 ledger.ammo 条目形状，见 DeltaForceCore/AccountData.swift）
    var ledgerEntries: [LedgerEntry] {
        positions.map { LedgerEntry(name: $0.name, qty: $0.qty, cost: $0.cost, at: $0.at) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(positions) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

/// TTK 数据（shared/data/ttk.json 以文件引用捆绑进 App）
@MainActor
@Observable
final class TtkStore {
    private(set) var data: TtkData?
    private(set) var error: String?

    func loadIfNeeded() {
        guard data == nil, error == nil else { return }
        guard let url = Bundle.main.url(forResource: "ttk", withExtension: "json") else {
            error = "TTK 数据缺失，请重新安装 App"
            return
        }
        do {
            data = try TtkData.load(from: Data(contentsOf: url))
        } catch {
            self.error = "TTK 数据解析失败：\(error.localizedDescription)"
        }
    }
}

/// TTK 弹药 ↔ 行情弹名映射（shared/data/ammo-alias.json 以文件引用捆绑进 App；
/// npm run export:ios 从网页端 ammo-market-alias.js 确定性导出——映射与
/// 「一对多歧义 / 国服命名无同型不映射」口径的唯一事实来源在网页端源文件）。
/// 消费方：行情页行 / 详情按弹名标穿透徽章；TTK 排行 / 枪械详情按弹反查现价。
@MainActor
@Observable
final class AmmoAliasStore {
    struct Pair: Codable, Sendable, Hashable {
        /// TTK 口径键（ttk.json calibers 的 key）
        let cal: String
        /// TTK 弹药名（calibers[cal].ammo[].n）
        let ammo: String
        /// 行情弹名（market.json items[].name，唯一键）
        let market: String
    }

    /// TTK 口径|弹药名 → 行情弹名
    private let byTtk: [String: String]
    /// 行情弹名 → 映射对
    private let byMarket: [String: Pair]
    /// 加载失败不弹错误页：徽章 / 现价按「无数据」退场（伤害数据不受影响）
    private(set) var error: String?

    init(bundle: Bundle = .main) {
        (byTtk, byMarket, error) = Self.load(bundle)
    }

    private static func load(_ bundle: Bundle) -> ([String: String], [String: Pair], String?) {
        struct File: Codable { let pairs: [Pair] }
        guard let url = bundle.url(forResource: "ammo-alias", withExtension: "json") else {
            return ([:], [:], "TTK↔行情映射数据缺失，请重新安装 App")
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            var byTtk: [String: String] = [:]
            var byMarket: [String: Pair] = [:]
            for p in file.pairs {
                byTtk["\(p.cal)|\(p.ammo)"] = p.market
                byMarket[p.market] = p
            }
            return (byTtk, byMarket, nil)
        } catch {
            return ([:], [:], "TTK↔行情映射解析失败：\(error.localizedDescription)")
        }
    }

    /// TTK 口径 + 弹药名 → 行情弹名（无映射 → nil：未上架 / 命名差异 / 禁交易弹）
    func marketName(cal: String, ammo: String) -> String? {
        byTtk["\(cal)|\(ammo)"]
    }

    /// 行情弹名 → 穿透等级。pen 的唯一事实来源是 ttk.json 的 calibers——
    /// 本 Store 只管名字对齐；无映射 / 口径或弹名查不到 → nil（调用方不显徽章）。
    func pen(marketName: String, calibers: [String: Caliber]) -> Int? {
        guard let p = byMarket[marketName] else { return nil }
        return calibers[p.cal]?.ammo.first { $0.n == p.ammo }?.pen
    }
}
