// FeedModel.swift — 一路快照（子弹行情 / 异动雷达）的数据源：
// 首拉 + 轮询（实时通道在线时放宽到 5 分钟兜底，否则 60s，与网页端一致）；
// SSE ping 到达且 version 前进时立即重拉。
import DeltaForceCore
import Foundation
import Observation

@MainActor
@Observable
final class FeedModel {
    enum Kind {
        case market, radar
    }

    let kind: Kind
    private(set) var snapshot: MarketSnapshot?
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastRefreshAt: Date?
    /// 轮询间隔（AppModel 按实时通道状态调节）
    var pollInterval: Duration = .seconds(60)

    /// 新快照到达（version 变化）时回调，AppModel 用它驱动本地通知
    var onSnapshot: ((MarketSnapshot) -> Void)?

    private var client: APIClient?
    private var pollTask: Task<Void, Never>?

    init(kind: Kind) {
        self.kind = kind
    }

    func configure(client: APIClient) {
        stop()
        self.client = client
        lastError = nil
        pollTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if Task.isCancelled { break }
                await refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard let client else { return }
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snap = try await (kind == .market ? client.fetchMarket() : client.fetchRadar())
            let changed = snap.version != snapshot?.version || snap.fetchedAt != snapshot?.fetchedAt
            snapshot = snap
            lastError = nil
            lastRefreshAt = .now
            if changed { onSnapshot?(snap) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// SSE ping：版本前进才重拉（事件不带全量数据，契约 §2）
    func noteRemoteVersion(_ version: String?) {
        guard let version, version != snapshot?.version else { return }
        Task { await refresh() }
    }

    // MARK: - 派生

    var items: [MarketItem] { snapshot?.items ?? [] }

    func ageMinutes(now: Date = .now) -> Double? {
        snapshot.map { MarketMeta.ageMinutes(fetchedAt: $0.fetchedAt, now: now) }
    }

    func isStale(now: Date = .now) -> Bool {
        guard let age = ageMinutes(now: now), let snapshot else { return false }
        return age > MarketMeta.staleness(source: snapshot.source).staleTipMin
    }

    func isDotStale(now: Date = .now) -> Bool {
        guard let age = ageMinutes(now: now), let snapshot else { return true }
        return age > MarketMeta.staleness(source: snapshot.source).staleDotMin
    }
}
