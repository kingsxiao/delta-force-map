// SettingsView.swift — 数据状态 / 信号通知 / 关于
import DeltaForceCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var refreshing = false // 两路快照刷新进行中（防连点）
    // 触觉反馈 tick：全部为本页局部状态、操作后自增（禁绑 Store 派生值）
    @State private var refreshTick = 0
    @State private var notifyTick = 0

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                Section("数据") {
                    LabeledContent("实时推送") {
                        Text(app.channel.state.label).monospacedDigit()
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
                    Text("首次出现立即通知；信号切换需连续 2 轮确认；同信号 6 小时冷却；买入信号冷却期内再跌 5% 重报。通知只在 App 处于前台拿到最新数据时判定。")
                }
                .listRowBackground(Theme.card)

                Section("关于") {
                    LabeledContent("版本") {
                        Text(appVersion).monospacedDigit()
                    }
                    Text("数据来源：三角洲攻略站 moligod（分钟级）、KK三角洲一图流 kkrb.net（兜底 / 涨幅榜）。游戏素材版权归腾讯/天美所有，本 App 仅供个人学习参考。历史分位不代表未来走势，信号仅供参考。")
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
                Task { await app.notifications.refreshAuthorization() }
            }
            .sensoryFeedback(.success, trigger: refreshTick) // 两路快照刷新完成
            .sensoryFeedback(.success, trigger: notifyTick) // 通知开关
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
