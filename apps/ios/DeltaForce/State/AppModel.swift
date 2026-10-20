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
    let market = FeedModel(kind: .market)
    let radar = FeedModel(kind: .radar)
    let channel = LiveChannel()
    let notifications = NotificationManager()
    let ttk = TtkStore()

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        channel.onEvent = { [weak self] event in
            self?.handle(event)
        }
        channel.onStateChange = { [weak self] state in
            guard let self else { return }
            let interval: Duration = state.isLive ? .seconds(300) : .seconds(60)
            market.pollInterval = interval
            radar.pollInterval = interval
        }
        market.onSnapshot = { [weak self] snap in
            guard let self else { return }
            Task { await self.notifications.process(snapshot: snap, enabled: self.settings.settings.notificationsEnabled) }
        }
        Task { await notifications.refreshAuthorization() }
        applySettings()
    }

    /// 设置变更（地址 / 演示模式）后重建数据链路
    func applySettings() {
        let client = settings.settings.demoMode ? nil : settings.client
        market.configure(client: client, demo: client == nil)
        radar.configure(client: client, demo: client == nil)
        if let client {
            channel.start(client: client)
        } else {
            channel.stop()
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard started else { return }
            if !settings.settings.demoMode, let client = settings.client {
                if !channel.state.isLive { channel.start(client: client) }
                Task {
                    await market.refresh()
                    await radar.refresh()
                }
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
        case .other:
            break
        }
    }
}
