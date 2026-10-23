// AppModel.swift — 根状态：把设置 / 两路数据源 / 实时通道 / 通知串起来
// 数据流与网页端完全一致：首拉快照 → SSE ping（version 前进）→ 重拉；SSE 不可用 → 60s 轮询。
import DeltaForceCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    let settings = SettingsStore()
    let favorites = FavoritesStore()
    /// 囤货台账（弹名 + 数量 + 成本；本地 UserDefaults，登录后与云端按名合并同步）
    let positions = PositionsStore()
    let market = FeedModel(kind: .market)
    let radar = FeedModel(kind: .radar)
    /// 特勤处制造利润快照（server/craft 落盘，契约 §1.3；SSE craft 事件驱动重拉）
    let craft = FeedModel<CraftSnapshot>(fetcher: { try await $0.fetchCraft() })
    let channel = LiveChannel()
    let notifications = NotificationManager()
    let ttk = TtkStore()
    let ammoAlias = AmmoAliasStore()
    /// 账号与云同步（token 存 Keychain；登录后自选 + 台账与云端合并）
    let auth: AuthStore

    private var started = false

    /// 通知深链：待直达详情的弹名（NotificationManager.onOpen 抛出；AmmoView
    /// 消费后置 nil 防重复触发；RootView 监听到非 nil 时切行情 Tab）
    var pendingDetailName: String?
    /// 通知深链兑底：弹名已不在当前快照（下架 / 改名）时的搜索词通道
    /// （AmmoView 消费后置 nil，再绑回 .searchable 的 query）
    var pendingQuery: String?

    init() {
        // 后端地址固定写死（SettingsStore.client 同源），账号走同一台服务器
        auth = AuthStore(client: settings.client)
    }

    func start() {
        guard !started else { return }
        started = true
        // 用户改自选 / 台账 → 云同步防抖上推（未登录时 AuthStore 内部直接忽略）
        favorites.onUserToggle = { [weak self] names in
            self?.auth.schedulePushDoc(stars: names, positions: self?.positions.ledgerEntries)
        }
        positions.onUserChange = { [weak self] entries in
            guard let self else { return }
            self.auth.schedulePushDoc(stars: self.favorites.sortedNames, positions: entries)
        }
        channel.onEvent = { [weak self] event in
            self?.handle(event)
        }
        channel.onStateChange = { [weak self] state in
            guard let self else { return }
            let interval: Duration = state.isLive ? .seconds(300) : .seconds(60)
            market.pollInterval = interval
            radar.pollInterval = interval
            craft.pollInterval = interval
        }
        market.onSnapshot = { [weak self] snap in
            guard let self else { return }
            Task { await self.notifications.process(snapshot: snap, enabled: self.settings.settings.notificationsEnabled) }
        }
        // 通知点击深链：写入 pendingDetailName，由 RootView（切 Tab）与
        // AmmoView（NavigationPath append / 兑底搜索词）消费
        notifications.onOpen = { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            self.pendingDetailName = name
        }
        // 上推途中若云端缓存尚未加载，AuthStore 会退化为一次拉取合并：结果经此
        // 落回本地（与 syncUserData 同口径，防止后续上推用未合并的本地集覆盖云端）
        auth.onMerged = { [weak self] merged in
            guard let self else { return }
            if let stars = merged.stars { favorites.replaceAll(stars) }
            if let positions = merged.positions { self.positions.replaceAll(positions) }
        }
        Task { await notifications.refreshAuthorization() }
        // 恢复会话后立即拉一次云端：填充 cloudDoc 缓存 + 顺带做两端合并。
        // 首拉失败时 cloudDoc 保持未加载，此后的上推会被 AuthStore 门禁拦下
        // （先补拉合并，拉不到不上推），不会以空缓存覆盖云端
        Task {
            await auth.restore()
            await syncUserData()
        }
        applySettings()
    }

    /// 启动时建立数据链路（后端地址固定写死，无设置变更场景）
    func applySettings() {
        let client = settings.client
        market.configure(client: client)
        radar.configure(client: client)
        craft.configure(client: client)
        channel.start(client: client)
    }

    /// TTK 联动：TTK 口径 + 弹药名 →（行情条目, 行情快照是否就绪）。
    /// 弹名对齐走 AmmoAliasStore；snapshotReady=false（快照未拉到 / 离线）时
    /// 调用方应整列退场——「未上架」只对「有快照但查无此弹」成立，
    /// 不把离线误标成未上架（口径与网页端 TtkView prices 兜底一致）。
    func marketItem(cal: String, ammo: String) -> (item: MarketItem?, snapshotReady: Bool) {
        let items = market.items
        guard let name = ammoAlias.marketName(cal: cal, ammo: ammo) else {
            return (nil, !items.isEmpty)
        }
        return (items.first { $0.name == name }, !items.isEmpty)
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard started else { return }
            if !channel.state.isLive { channel.start(client: settings.client) }
            Task {
                // 离线冷启动时 restore 未验证（user 来自缓存或为空）：补拉 /me，
                // 验证成功顺带补一次冷启动漏掉的云端合并
                if await auth.retryRestoreIfNeeded() {
                    await syncUserData()
                }
                await market.refresh()
                await radar.refresh()
                await craft.refresh()
            }
        case .background:
            channel.stop()
        default:
            break
        }
    }

    private func handle(_ event: LiveEvent) {
        switch event {
        case .hello(let ping), .market(let ping):
            market.noteRemoteVersion(ping.version)
        case .radar(let ping):
            radar.noteRemoteVersion(ping.version)
        case .craft(let ping):
            craft.noteRemoteVersion(ping.version)
        case .other:
            break
        }
    }

    // MARK: - 账号与云同步（AccountView 调用；合并结果落回 FavoritesStore / PositionsStore）

    func loginAccount(username: String, password: String) async throws {
        try await auth.login(username: username, password: password)
        await syncUserData()
    }

    func registerAccount(username: String, password: String) async throws {
        try await auth.register(username: username, password: password)
        await syncUserData()
    }

    func logoutAccount() async {
        await auth.logout()
    }

    /// 拉云端与本地合并（星标并集 / 台账按名并集·同名本地优先）：云端回写 + 本地落地
    func syncUserData() async {
        guard auth.user != nil else { return }
        let remote = await auth.pullAndMerge(stars: favorites.sortedNames, positions: positions.ledgerEntries)
        if let stars = remote.stars { favorites.replaceAll(stars) }
        if let positions = remote.positions { self.positions.replaceAll(positions) }
    }
}
