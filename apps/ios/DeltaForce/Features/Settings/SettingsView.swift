// SettingsView.swift — 数据状态 / 信号通知 / 关于
// 字阶 / 色令牌接入（DESIGN.md §4.5-1）：标题 .md 档 tx 色、行值走 MonoStep.sub / 同锚默认 design，
// Section 眉题 micro accent（对齐各页「口径」标题心智），不再用系统默认字号与系统灰。
import DeltaForceCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    // §7-9 Reduce Motion：为 true 时跳过 symbolEffect（触感不属动效，保留）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var refreshing = false // 两路快照刷新进行中（防连点）
    // 触觉反馈 tick：全部为本页局部状态、操作后自增（禁绑 Store 派生值）。
    // §4.5-3 刷新反馈二分：两路 lastError 任一非空 → .error，否则 → .success（原固定 .success）
    @State private var refreshOkTick = 0
    @State private var refreshErrTick = 0
    @State private var notifyTick = 0

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                Section {
                    // §4.5-2 连接状态行改造：共享 ConnectionDot（C11）替代纯文本行值——
                    // live 显 ok 点、其余 faint，行值随通道状态可见变化（消除左右同文的无信息行）；
                    // 本页只传 state，error/stale 维度归 FeedHeader 全参调用
                    LabeledContent {
                        ConnectionDot(state: app.channel.state)
                    } label: {
                        rowTitle("连接状态")
                    }
                    LabeledContent {
                        // 版本号为日期数字串（§4.5-4 等宽对齐：monospacedDigit + MonoStep.sub）
                        Mono(MarketMeta.formatVersionLabel(app.market.snapshot?.version), step: .sub, color: Theme.dim)
                    } label: {
                        rowTitle("行情版本")
                    }
                    LabeledContent {
                        Mono(MarketMeta.formatVersionLabel(app.radar.snapshot?.version), step: .sub, color: Theme.dim)
                    } label: {
                        rowTitle("雷达版本")
                    }
                    if app.channel.eventCount > 0 {
                        LabeledContent {
                            // 「N 次」含中文：默认 design + 等宽数字（mono design 仅限纯 ASCII），
                            // 锚定 .md（subheadline）与同列 MonoStep.sub 同档同行高
                            Text("\(app.channel.eventCount) 次")
                                .font(Theme.font(.md, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.dim)
                        } label: {
                            rowTitle("收到推送")
                        }
                    }
                    Button {
                        guard !refreshing else { return }
                        refreshing = true
                        Task {
                            await app.market.refresh()
                            await app.radar.refresh()
                            refreshing = false
                            // 成功侧 refresh 会清掉自身 lastError，完成后判两路即成败二分
                            if app.market.lastError != nil || app.radar.lastError != nil {
                                refreshErrTick += 1
                            } else {
                                refreshOkTick += 1
                            }
                        }
                    } label: {
                        HStack(spacing: Theme.Space.sm) {
                            Label("立即刷新两路快照", systemImage: "arrow.clockwise")
                                .font(Theme.font(.md, weight: .semibold))
                                // §5 刷新中图标微动效：DESIGN 标注的 .rotate 实为 iOS 18 API（RotateSymbolEffect），
                                // iOS 17 目标下以 .repeating .pulse 等价表达「进行中」；Reduce Motion 跳过
                                .symbolEffect(.pulse, options: .repeating, isActive: refreshing && !reduceMotion)
                            if refreshing { ProgressView().controlSize(.small) } // 进行中内联进度（保持）
                        }
                    }
                    .disabled(refreshing)
                } header: {
                    sectionHeader("数据")
                }
                .listRowBackground(Theme.card)

                Section {
                    Toggle(isOn: $settings.settings.notificationsEnabled) {
                        rowTitle("买入 / 卖出信号通知")
                    }
                    .onChange(of: settings.settings.notificationsEnabled) { _, on in
                        notifyTick += 1
                        if on { Task { await app.notifications.requestAuthorization() } }
                    }
                    LabeledContent {
                        // 纯中文行值：默认 design（同列锚定），已允许 txStrong / 未允许 dim 分层
                        Text(app.notifications.authorized ? "已允许" : "未允许")
                            .font(Theme.font(.md, weight: .semibold))
                            .foregroundStyle(app.notifications.authorized ? Theme.txStrong : Theme.dim)
                    } label: {
                        rowTitle("系统授权")
                    }
                    if let t = app.notifications.lastDelivered {
                        LabeledContent {
                            // 本地化时间含中文（上午/下午）：默认 design + 等宽数字（§4.5-4）
                            Text(t.formatted(date: .omitted, time: .shortened))
                                .font(Theme.font(.md, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.dim)
                        } label: {
                            rowTitle("上次通知")
                        }
                    }
                } header: {
                    sectionHeader("通知")
                } footer: {
                    Text("首次出现立即通知；信号切换需连续 2 轮确认；同信号 6 小时冷却；买入信号冷却期内再跌 5% 重报。通知只在 App 处于前台拿到最新数据时判定。")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.faint)
                }
                .listRowBackground(Theme.card)

                Section {
                    LabeledContent {
                        // §4.5-5「版本」值迁 mono（"x.y.z (build)" 纯 ASCII → MonoStep.sub）
                        Mono(appVersion, step: .sub, color: Theme.dim)
                    } label: {
                        rowTitle("版本")
                    }
                    Text("数据来源：三角洲攻略站 moligod（分钟级）、KK三角洲一图流 kkrb.net（兜底 / 涨幅榜）。游戏素材版权归腾讯/天美所有，本 App 仅供个人学习参考。历史分位不代表未来走势，信号仅供参考。")
                        .font(Theme.font(.xs)) // 版权/来源声明下限 footnote（原 11pt 固定字号不随系统字号设置）
                        .foregroundStyle(Theme.faint)
                } header: {
                    sectionHeader("关于")
                }
                .listRowBackground(Theme.card)
            }
            .themedList()
            // iPad/横屏 regular：表单列上限 600 居中（与详情 640 同一可读列节奏，§4.5-6 保持不动）；
            // 外层再满宽铺 Theme.bg，600pt 之外不露 NavigationStack 系统底色（与详情/手册同一写法）
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .background(Theme.bg)
            .navigationTitle("设置")
            .onAppear {
                Task { await app.notifications.refreshAuthorization() }
            }
            // §4.5-3 二分触感：成功 / 失败各自 tick，分别挂不同 sensoryFeedback
            .sensoryFeedback(.success, trigger: refreshOkTick) // 两路快照刷新成功
            .sensoryFeedback(.error, trigger: refreshErrTick) // 任一路刷新失败
            .sensoryFeedback(.success, trigger: notifyTick) // 通知开关
        }
    }

    /// 行标题统一 .md 档 + tx 正文色（§4.5-1，替代系统默认灰标题）
    private func rowTitle(_ s: String) -> some View {
        Text(s).font(Theme.font(.md)).foregroundStyle(Theme.tx)
    }

    /// Section 眉题（§4.5-1）：micro accent 小节题，对齐各页「口径」标题心智
    private func sectionHeader(_ s: String) -> some View {
        Text(s).font(Theme.font(.micro, weight: .bold)).foregroundStyle(Theme.accent)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
