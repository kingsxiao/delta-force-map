// LiveChannel.swift — 实时通道编排：先探 /health（与网页端 gate 一致），探到才连 SSE
// 探不到 → unavailable，每 5 分钟再探（期间 FeedModel 按 60s 轮询兜底）；
// SSE 断线由 SSEClient 自带指数退避重连，这里只映射状态给 UI。
import DeltaForceCore
import Foundation
import Observation

@MainActor
@Observable
final class LiveChannel {
    enum State: Equatable {
        case idle
        case probing
        case connecting
        case live
        case reconnecting(String)
        case unavailable

        var isLive: Bool { self == .live }

        var label: String {
            switch self {
            case .idle: "未连接"
            case .probing: "检查服务…"
            case .connecting: "连接中…"
            case .live: "实时推送"
            case .reconnecting: "重连中"
            case .unavailable: "定时刷新"
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var lastHeartbeat: Date?
    private(set) var lastEventAt: Date?
    private(set) var eventCount = 0

    var onEvent: ((LiveEvent) -> Void)?
    var onStateChange: ((State) -> Void)?

    private var task: Task<Void, Never>?
    private let reprobeInterval: Duration = .seconds(300)

    func start(client: APIClient) {
        stop()
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                set(.probing)
                let healthy = (try? await client.health()) != nil
                if Task.isCancelled { return }
                guard healthy else {
                    set(.unavailable)
                    try? await Task.sleep(for: reprobeInterval)
                    continue
                }
                set(.connecting)
                for await ev in SSEClient.stream(url: client.eventsURL) {
                    if Task.isCancelled { return }
                    switch ev {
                    case .open:
                        set(.live)
                    case .heartbeat:
                        lastHeartbeat = .now
                    case .event(let raw):
                        lastEventAt = .now
                        eventCount += 1
                        onEvent?(LiveEvent.parse(raw))
                    case .closed(let reason):
                        set(.reconnecting(reason))
                    }
                }
                // 流结束（只会在取消时发生）
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        set(.idle)
    }

    private func set(_ s: State) {
        guard state != s else { return }
        state = s
        onStateChange?(s)
    }
}
