// NotificationManager.swift — 信号本地通知（去抖口径同 shared/js/notify-policy.js）
// 每次新快照都跑一轮 judge 推进 state（关掉通知也推进，恢复时不会一次性爆发）；
// 只有开关打开且系统已授权才真正投递，最多报 3 条、其余指引进行情页（与 macOS 通知同口径）。
// 前台不静默：delegate 放行 banner + sound（iOS 默认前台只进通知中心不弹横幅），信号出现即提醒。
// 深链：deliver 把首个信号弹名写进 userInfo，didReceive（用户点通知）经 onOpen
// 抛给 AppModel（pendingDetailName → 行情 Tab 直达详情 / 兑底搜索词通道）。
import DeltaForceCore
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class NotificationManager {
    private(set) var authorized = false
    private(set) var lastDelivered: Date?
    /// 通知点击回调（主线程消费）：携带 userInfo 里的首个信号弹名（无则 nil）
    var onOpen: ((String?) -> Void)?
    private var state: NotifyState
    private let defaults: UserDefaults
    private static let stateKey = "notify.state.v1"
    /// 前台横幅放行 + 点击深链（UNUserNotificationCenter 对 delegate 只持弱引用，这里强持有）
    private let presenter = ForegroundPresenter()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        UNUserNotificationCenter.current().delegate = presenter
        if let data = defaults.data(forKey: Self.stateKey),
           let s = try? JSONDecoder().decode(NotifyState.self, from: data) {
            state = s
        } else {
            state = NotifyState()
        }
        // didReceive 由系统回调（非隔离 delegate 方法），闭包内部自行 MainActor hop
        presenter.onOpen = { [weak self] name in
            Task { @MainActor in self?.onOpen?(name) }
        }
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            authorized = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            authorized = false
        }
        return authorized
    }

    func process(snapshot: MarketSnapshot, enabled: Bool) async {
        let verdict = NotifyEngine.judge(state: &state, items: snapshot.items)
        persist()
        guard enabled, authorized, !verdict.isEmpty else { return }
        if !verdict.buys.isEmpty {
            await deliver(
                title: "三角洲子弹买入信号 ×\(verdict.buys.count)",
                lines: verdict.buys.map { "🎯 " + NotifyEngine.buyLine($0) },
                total: verdict.buys.count,
                openName: verdict.buys.first?.name
            )
        }
        if !verdict.sells.isEmpty {
            await deliver(
                title: "三角洲子弹卖出信号 ×\(verdict.sells.count)",
                lines: verdict.sells.map { "📈 " + NotifyEngine.sellLine($0) },
                total: verdict.sells.count,
                openName: verdict.sells.first?.name
            )
        }
    }

    /// openName：首个信号弹名，写入 userInfo 供点击深链（nil = 不带，点击不跳转）
    private func deliver(title: String, lines: [String], total: Int, openName: String? = nil) async {
        let top = Array(lines.prefix(3))
        var body = top.joined(separator: "\n")
        if total > top.count { body += "\n…还有\(total - top.count)种见行情页" }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let openName, !openName.isEmpty {
            content.userInfo = ["openName": openName]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        lastDelivered = .now
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.stateKey)
        }
    }
}

/// 前台放行横幅：无此 delegate 时本地通知在前台只静默进通知中心，App 开着也看不到提醒。
/// 另承接点击深链：didReceive 从 userInfo 取 openName 抛给 onOpen（@Sendable 闭包，
/// 消费方自行 MainActor hop；didReceive 在 init 完成后才会被系统回调，写入先于读取）。
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    /// 通知点击回调（nil = 该通知不带深链弹名）
    var onOpen: (@Sendable (String?) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        onOpen?(response.notification.request.content.userInfo["openName"] as? String)
        completionHandler()
    }
}
