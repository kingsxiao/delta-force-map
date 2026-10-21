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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        names = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func contains(_ name: String) -> Bool { names.contains(name) }

    func toggle(_ name: String) {
        if names.contains(name) { names.remove(name) } else { names.insert(name) }
        defaults.set(Array(names).sorted(), forKey: Self.key)
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
            error = "App 内缺少 ttk.json（先在仓库根运行 npm run export:ios）"
            return
        }
        do {
            data = try TtkData.load(from: Data(contentsOf: url))
        } catch {
            self.error = "TTK 数据解析失败：\(error.localizedDescription)"
        }
    }
}
