// SettingsView.swift — 服务器地址 / 演示模式 / 信号通知 / 关于
import DeltaForceCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var draft = ""
    @State private var probe: ProbeState = .idle
    @State private var refreshing = false // 两路快照刷新进行中（防连点）
    // 触觉反馈 tick：全部为本页局部状态、操作后自增（禁绑 Store 派生值）
    @State private var saveTick = 0
    @State private var refreshTick = 0
    @State private var notifyTick = 0
    @State private var demoTick = 0

    private enum ProbeState: Equatable {
        case idle, testing, ok(String), fail(String)
    }

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                Section {
                    TextField("http://服务器IP:8080 或 https://域名", text: $draft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.monoFont(.lg)) // URL 为纯 ASCII：等宽 body 字阶，随 Dynamic Type 缩放
                        .submitLabel(.go)
                        .onSubmit { saveAndConnect() }
                    // 特大字号下横排放不下时自动纵向堆叠
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            testButton
                            Spacer()
                            saveButton
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            testButton
                            saveButton
                        }
                    }
                    probeRow
                } header: {
                    Text("自托管服务（与网页端同一后端）")
                } footer: {
                    // 启动命令为纯 ASCII：等宽 footnote 呈现，不再露出 markdown 反引号
                    Text("服务端：仓库根 ")
                        + Text("npm run build && npm run serve").font(Theme.monoFont(.xs))
                        + Text("（默认 0.0.0.0:8080），或按 deploy/aliyun.md 部署到云服务器。App 读 /ammo/market.json、/market/radar.json 快照，连 /events 实时通道；明文 http 已在 Info.plist 放行。")
                }
                .listRowBackground(Theme.card)

                Section("数据") {
                    Toggle("演示模式（内置样本，离线可看）", isOn: $settings.settings.demoMode)
                        .onChange(of: settings.settings.demoMode) { _, _ in
                            app.applySettings()
                            demoTick += 1
                        }
                    LabeledContent("实时通道") {
                        Text(app.settings.settings.demoMode ? "—" : app.channel.state.label).monospacedDigit()
                    }
                    LabeledContent("行情版本") {
                        Text(MarketMeta.formatVersionLabel(app.market.snapshot?.version)).monospacedDigit()
                    }
                    LabeledContent("雷达版本") {
                        Text(MarketMeta.formatVersionLabel(app.radar.snapshot?.version)).monospacedDigit()
                    }
                    if app.channel.eventCount > 0 {
                        LabeledContent("收到推送") {
                            Text("\(app.channel.eventCount) 次").monospacedDigit()
                        }
                    }
                    Button {
                        guard !refreshing else { return }
                        refreshing = true
                        Task {
                            await app.market.refresh()
                            await app.radar.refresh()
                            refreshing = false
                            refreshTick += 1 // 刷新完成轻触反馈
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Label("立即刷新两路快照", systemImage: "arrow.clockwise")
                            if refreshing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(refreshing)
                }
                .listRowBackground(Theme.card)

                Section {
                    Toggle("买入 / 卖出信号通知", isOn: $settings.settings.notificationsEnabled)
                        .onChange(of: settings.settings.notificationsEnabled) { _, on in
                            notifyTick += 1
                            if on { Task { await app.notifications.requestAuthorization() } }
                        }
                    LabeledContent("系统授权", value: app.notifications.authorized ? "已允许" : "未允许")
                    if let t = app.notifications.lastDelivered {
                        LabeledContent("上次通知") {
                            Text(t.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                        }
                    }
                } header: {
                    Text("通知")
                } footer: {
                    Text("去抖与后端 notify-policy 同口径：首次出现立即通知；信号切换需连续 2 轮确认；同信号 6 小时冷却；买入信号冷却期内再跌 5% 重报。通知只在 App 在前台拉到新快照时判定（iOS 无常驻后台），要 7×24 推送请在服务端跑 --notify。")
                }
                .listRowBackground(Theme.card)

                Section("关于") {
                    LabeledContent("版本") {
                        Text(appVersion).monospacedDigit()
                    }
                    LabeledContent("技术栈", value: "Swift 6 · SwiftUI · Swift Charts · URLSession SSE")
                    LabeledContent("接口契约", value: "shared/API.md")
                    Link(destination: URL(string: "https://github.com/kingsxiao/delta-force-map")!) {
                        Label("GitHub 仓库", systemImage: "link")
                    }
                    Text("数据来源：三角洲攻略站 moligod（分钟级）、KK三角洲一图流 kkrb.net（兜底 / 涨幅榜）。点位与打法整理自社区公开资料；游戏素材版权归腾讯/天美所有，本 App 仅供个人学习参考。历史分位不代表未来走势，信号仅供参考。")
                        .font(Theme.font(.xs)) // 版权/来源声明下限 footnote（原 11pt 固定字号不随系统字号设置）
                        .foregroundStyle(Theme.faint)
                }
                .listRowBackground(Theme.card)
            }
            .themedList()
            // iPad/横屏 regular：表单列上限 600 居中（与详情 640 同一可读列节奏）；
            // 外层再满宽铺 Theme.bg，600pt 之外不露 NavigationStack 系统底色（与详情/手册同一写法）
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .background(Theme.bg)
            .navigationTitle("设置")
            .onAppear {
                if draft.isEmpty { draft = app.settings.settings.baseURL }
                Task { await app.notifications.refreshAuthorization() }
            }
            .sensoryFeedback(.success, trigger: saveTick) // 保存并连接成功
            .sensoryFeedback(.success, trigger: refreshTick) // 两路快照刷新完成
            .sensoryFeedback(.success, trigger: notifyTick) // 通知开关
            .sensoryFeedback(.success, trigger: demoTick) // 演示模式开关
            .sensoryFeedback(trigger: probe) { _, newState in // 探测出结果：在线成功 / 失败警示
                switch newState {
                case .ok: return .success
                case .fail: return .warning
                default: return nil
                }
            }
        }
    }

    private var testButton: some View {
        Button {
            Task { await testConnection() }
        } label: {
            Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
        }
        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || probe == .testing)
    }

    private var saveButton: some View {
        Button("保存并连接") { saveAndConnect() }
            .buttonStyle(.borderedProminent)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @ViewBuilder
    private var probeRow: some View {
        switch probe {
        case .idle: EmptyView()
        case .testing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("探测 /health …").font(Theme.font(.xs)).foregroundStyle(Theme.dim)
            }
        case .ok(let s): Label(s, systemImage: "checkmark.circle.fill").font(Theme.font(.xs)).foregroundStyle(Theme.ok)
        case .fail(let s): Label(s, systemImage: "xmark.octagon.fill").font(Theme.font(.xs)).foregroundStyle(Theme.danger)
        }
    }

    /// 保存地址、退出演示模式并立即探测 /health（复用 probeRow 展示在线/失败，连接成败当场可见）
    private func saveAndConnect() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        app.settings.settings.baseURL = draft
        app.settings.settings.demoMode = false
        app.applySettings()
        saveTick += 1
        Task { await testConnection() }
    }

    private func testConnection() async {
        probe = .testing
        do {
            let client = APIClient(baseURL: try APIClient.parseBaseURL(draft))
            let h = try await client.health()
            probe = .ok("在线 · 源 \(h.source ?? "—") · 版本 \(MarketMeta.formatVersionLabel(h.version)) · 已抓 \(h.cycles ?? 0) 轮")
        } catch {
            probe = .fail(error.localizedDescription)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
