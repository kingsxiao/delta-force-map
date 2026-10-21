// RadarView.swift — 全品类异动雷达：kkrb 涨幅榜 Top10 + 双源交叉验证
import DeltaForceCore
import SwiftUI

struct RadarView: View {
    @Environment(AppModel.self) private var app
    @State private var anomalyOnly = false
    // 本页局部触觉 tick（自选切换 / 刷新完成 / 筛选切换；trigger 只绑本页 State）
    @State private var favTick = 0
    @State private var refreshTick = 0
    @State private var toggleTick = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    FeedHeader(
                        feed: app.radar,
                        channel: app.channel,
                        subtitle: statsLine
                    )
                }
                .listRowBackground(Theme.card)

                Section {
                    Toggle(isOn: $anomalyOnly) {
                        Label("只看双源异常", systemImage: "exclamationmark.triangle")
                            .font(Theme.font(.sm))
                    }
                    // 不覆盖 tint：选中色回落 App 根的统一主色，警示金只留给行内异常徽标
                }
                .listRowBackground(Theme.card)

                Section("涨幅榜 · \(rows.count) 项") {
                    if rows.isEmpty {
                        if app.radar.snapshot == nil, let err = app.radar.lastError {
                            // 首拉失败：错误态 + 重试（与行情页同款）
                            FeedErrorView(message: err) {
                                Task { await app.radar.refresh() }
                            }
                        } else if app.radar.snapshot == nil {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.mini)
                                Text("正在拉取雷达数据…").font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                            }
                        } else {
                            // 筛选空态：给一条出路
                            ContentUnavailableView {
                                Label("没有符合条件的条目", systemImage: "dot.radiowaves.left.and.right")
                            } description: {
                                Text(anomalyOnly ? "当前榜单没有双源异常条目" : "榜单暂无条目")
                            } actions: {
                                if anomalyOnly {
                                    Button("显示全部条目") { anomalyOnly = false }
                                }
                            }
                        }
                    }
                    ForEach(rows) { item in
                        NavigationLink(value: item) { RadarRow(item: item) }
                            .swipeActions(edge: .leading) {
                                // 与行情页完全一致的自选滑动操作（同标签 / 同 tint / 同局部 tick 触感）
                                Button {
                                    app.favorites.toggle(item.name)
                                    favTick += 1
                                } label: {
                                    let starred = app.favorites.contains(item.name)
                                    Label(starred ? "取消自选" : "加入自选", systemImage: starred ? "star.slash" : "star")
                                }
                                .tint(Theme.warn)
                            }
                    }
                }
                .listRowBackground(Theme.card)

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        // 含中文标题：默认 design + 等宽数字（mono 只留给纯 ASCII）
                        Text("口径").font(Theme.font(.xs, weight: .bold)).monospacedDigit().foregroundStyle(Theme.accent)
                        Text("异动清单来自 kkrb「全物品价格变化曲线」涨幅榜 Top10；逐项补 moligod 全品类小时曲线 + 分钟级现价，用与子弹页完全相同的分位数回归出信号（非子弹无税后字段，税率兜底 15%）。同一物品两源曲线在重叠小时上的中位偏差 > 15% 判「双源异常」：信号强制观望、不通知。")
                            .font(Theme.font(.xs)).foregroundStyle(Theme.dim)
                    }
                }
                .listRowBackground(Theme.card)
            }
            .themedList()
            .listStyle(.insetGrouped)
            .navigationTitle("异动雷达")
            .navigationDestination(for: MarketItem.self) { ItemDetailView(item: $0) }
            .refreshable {
                await app.radar.refresh()
                refreshTick += 1 // 刷新完成：轻触反馈
            }
            .sensoryFeedback(.success, trigger: favTick)
            .sensoryFeedback(.impact(weight: .light), trigger: refreshTick)
            .sensoryFeedback(.selection, trigger: toggleTick)
            .onChange(of: anomalyOnly) { _, _ in toggleTick += 1 }
        }
    }

    private var rows: [MarketItem] {
        let items = app.radar.items.sorted { ($0.hiRank ?? 99) < ($1.hiRank ?? 99) }
        return anomalyOnly ? items.filter(\.isAnomaly) : items
    }

    private var statsLine: String? {
        guard let s = app.radar.snapshot?.stats else { return nil }
        return "榜单 \(s.total) 项 · 买入 \(s.buy) / 卖出 \(s.sell) / 关注 \(s.watch) · 双源异常 \(s.anomaly ?? 0)"
    }
}

struct RadarRow: View {
    let item: MarketItem
    /// 榜名列对齐宽随字阶缩放（minWidth 而非固定宽）
    @ScaledMetric(relativeTo: .body) private var rankMinWidth = 30

    var body: some View {
        HStack(spacing: 10) {
            Mono("#\(item.hiRank ?? 0)", size: 13, color: Theme.accent)
                .frame(minWidth: rankMinWidth, alignment: .leading)
            ItemThumb(pic: item.pic, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                // 徽标行宽度不足时按「分类 → 等级」次序省略（信号徽标必须保留），绝不折行竖排
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        if let c = item.category { CategoryChip(text: c) }
                        GradeBadge(grade: item.grade)
                        SignalChip(signal: item.signal, anomaly: item.isAnomaly)
                    }
                    HStack(spacing: 6) {
                        GradeBadge(grade: item.grade)
                        SignalChip(signal: item.signal, anomaly: item.isAnomaly)
                    }
                    SignalChip(signal: item.signal, anomaly: item.isAnomaly)
                }
            }
            .layoutPriority(1) // 名称列优先取宽（radar-2）：溢出压力由右列缩放 / 徽标降档承担，不挤折名称
            Spacer(minLength: 4)
            // 右列 + 走势线整体 ViewThatFits：行宽吃紧时先省略走势线（纯装饰、a11y 已隐藏），
            // 保住名称列与价格数字都单行完整
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    trailing
                    Sparkline(curve: item.curve, color: item.isAnomaly ? Theme.warn : Theme.signal(item.signal))
                        .frame(width: 50, height: 24)
                }
                trailing
            }
        }
        .padding(.vertical, 2)
        // 整行合并为单一朗读元素：名次 / 名称 / 分类 / 信号 / 现价 / 分位 / 双源偏差 一句话转述
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// 右列（现价 / 分位 / 偏差）：单行 + 随宽缩一档兜底（同 StatCell），不折行
    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Mono(Fmt.price(item.current), size: 14)
            HStack(spacing: 4) {
                Text("分位").font(Theme.font(.micro)).foregroundStyle(Theme.faint)
                Mono(Fmt.rankPercent(item.rank), size: 12, weight: .medium, color: Theme.dim, relativeTo: .footnote)
                if let dev = item.crossDev {
                    // 含中文（「偏差」）：默认 design + 等宽数字
                    Text("偏差 \(Fmt.pct(dev).replacingOccurrences(of: "+", with: ""))")
                        .font(Theme.font(.xs, weight: .medium)).monospacedDigit()
                        .foregroundStyle(item.isAnomaly ? Theme.warn : Theme.faint)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    /// 成句转述，替代逐控件拼读
    private var a11yLabel: String {
        var parts: [String] = ["涨幅榜第 \(item.hiRank ?? 0) 名"]
        parts.append(item.name)
        if let category = item.category { parts.append(category) }
        parts.append(item.isAnomaly ? "双源异常" : item.signal.label)
        if let current = item.current { parts.append("现价 \(Fmt.price(current))") }
        if let rank = item.rank { parts.append("分位 \(Fmt.rankPercent(rank))") }
        if let dev = item.crossDev { parts.append("双源偏差 \(Fmt.pct(dev))") }
        return parts.joined(separator: "，")
    }
}
