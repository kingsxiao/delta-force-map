// RadarView.swift — 全品类异动雷达：kkrb 涨幅榜 Top10 + 双源交叉验证
import DeltaForceCore
import SwiftUI

struct RadarView: View {
    @Environment(AppModel.self) private var app
    /// 双源筛选域（§4.3-2）：原「一个布尔开关占一张卡」收编进 FilterMenu chip，三页筛选范式归一
    private enum AnomalyScope: Hashable {
        case all
        case anomalyOnly
    }

    @State private var scope: AnomalyScope = .all
    private var anomalyOnly: Bool { scope == .anomalyOnly }

    // 本页局部触觉 tick（自选切换 / 刷新成败二分 / 筛选切换；trigger 只绑本页 State）
    @State private var favTick = 0
    @State private var refreshOkTick = 0
    @State private var refreshErrTick = 0
    @State private var toggleTick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 筛选变化后滚回榜首的锚点 id（§4.3-5，对齐 TTK TtkView 方案）
    private static let topAnchor = "radar-top"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            FeedHeader(feed: app.radar, channel: app.channel)
                            // 市场态势行（§4.3-1）：本页唯一全局口径从 FeedHeader 第三行灰字
                            // 升格为语义胶囊组（C2 StatusChip）；特大字号 / 窄屏折两行（AX 韧性 §7-6）
                            if let s = app.radar.snapshot?.stats {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 6) {
                                        StatusChip(text: "买入 \(s.buy)", tint: Theme.ok)
                                        StatusChip(text: "卖出 \(s.sell)", tint: Theme.danger)
                                        StatusChip(text: "关注 \(s.watch)", tint: Theme.warn)
                                        StatusChip(text: "异常 \(s.anomaly ?? 0)", tint: Theme.warn)
                                        StatusChip(text: "榜单 \(s.total) 项", tint: Theme.dim)
                                    }
                                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                        HStack(spacing: 6) {
                                            StatusChip(text: "买入 \(s.buy)", tint: Theme.ok)
                                            StatusChip(text: "卖出 \(s.sell)", tint: Theme.danger)
                                            StatusChip(text: "关注 \(s.watch)", tint: Theme.warn)
                                        }
                                        HStack(spacing: 6) {
                                            StatusChip(text: "异常 \(s.anomaly ?? 0)", tint: Theme.warn)
                                            StatusChip(text: "榜单 \(s.total) 项", tint: Theme.dim)
                                        }
                                    }
                                }
                                .accessibilityElement(children: .combine) // 计数一组一句话读完，不再逐枚滑动
                            }
                            // 「只看双源异常」并入 chip 族（§4.3-2）：偏离默认值时描边点亮 accent
                            FilterMenu(
                                caption: "双源",
                                options: [
                                    FilterOption(id: AnomalyScope.all, label: "全部"),
                                    FilterOption(id: AnomalyScope.anomalyOnly, label: "仅异常", icon: "exclamationmark.triangle"),
                                ],
                                selection: $scope,
                                defaultId: .all
                            )
                        }
                        .id(Self.topAnchor)
                    }
                    .listRowBackground(Theme.card)

                    Section("涨幅榜 · \(rows.count) 项") {
                        if rows.isEmpty {
                            if app.radar.snapshot == nil, let err = app.radar.lastError {
                                // 首拉失败：换共享 RetryErrorRow（C10 安全序第 ② 步；busy 防空转——
                                // isLoading 守卫在 State/FeedModel.swift:55，加载中禁用 + 内联进度）
                                RetryErrorRow(
                                    message: err,
                                    retry: { Task { await app.radar.refresh() } },
                                    busy: app.radar.isLoading
                                )
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
                                        Button("显示全部条目") { scope = .all }
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
                    // 刷新反馈二分（§4.3-6 / §5）：按 lastError 分流 success / error 触感，
                    // 替换原无条件 impact(light)；成功侧「数据年龄归零」由 FeedHeader 的 C6 id 重建承担
                    if app.radar.lastError != nil { refreshErrTick += 1 } else { refreshOkTick += 1 }
                }
                .sensoryFeedback(.success, trigger: favTick)
                .sensoryFeedback(.success, trigger: refreshOkTick)
                .sensoryFeedback(.error, trigger: refreshErrTick)
                .sensoryFeedback(.selection, trigger: toggleTick)
                .onChange(of: scope) { _, _ in
                    scopeChanged(proxy)
                }
            }
        }
    }

    /// 筛选切换：轻触 + 滚回榜首（§4.3-5，与 TTK / 行情三页一致；Reduce Motion 无动画直达，§7-9）
    private func scopeChanged(_ proxy: ScrollViewProxy) {
        toggleTick += 1
        if reduceMotion {
            proxy.scrollTo(Self.topAnchor, anchor: .top)
        } else {
            withAnimation(.easeOut(duration: Theme.durMed)) {
                proxy.scrollTo(Self.topAnchor, anchor: .top)
            }
        }
    }

    private var rows: [MarketItem] {
        let items = app.radar.items.sorted { ($0.hiRank ?? 99) < ($1.hiRank ?? 99) }
        return anomalyOnly ? items.filter(\.isAnomaly) : items
    }
}

struct RadarRow: View {
    let item: MarketItem
    /// 榜名列对齐宽随字阶缩放（minWidth 而非固定宽）；名次已迁 sub 档（§4.3-3），锚跟随 subheadline
    @ScaledMetric(relativeTo: .subheadline) private var rankMinWidth = 30

    /// 名次语言（§4.3-3）：零填充 01、仅前三 accent 其余 faint——与 TTK 名次列同符号同字号（sub）同规则，
    /// accent 从「整列装饰」收回「前三指针」，不再稀释唯一强调色（§1.2）
    private var rankText: String { String(format: "%02d", item.hiRank ?? 0) }
    private var rankColor: Color {
        if let r = item.hiRank, (1...3).contains(r) { return Theme.accent }
        return Theme.faint
    }

    var body: some View {
        HStack(spacing: 10) {
            Mono(rankText, step: .sub, color: rankColor)
                .frame(minWidth: rankMinWidth, alignment: .leading)
            ItemThumb(pic: item.pic, size: 36)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
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
                        .frame(width: 56, height: 26) // 统一规格 56×26（§4.3-4 / C9 决议，与行情行对齐）
                }
                trailing
            }
        }
        .padding(.vertical, 2)
        // 整行合并为单一朗读元素：名次 / 名称 / 分类 / 信号 / 现价 / 分位 / 双源偏差 一句话转述
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// 右列（§4.3-4 主数字立权）：雷达行主数字=现价升 lead 档、分位 / 偏差迁 sub；
    /// 单行 + 随宽缩一档兜底，不折行
    private var trailing: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            Mono(Fmt.price(item.current), step: .lead)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Text("分位").font(Theme.font(.micro)).foregroundStyle(Theme.faint)
                Mono(Fmt.rankPercent(item.rank), step: .sub, color: Theme.dim)
                if let dev = item.crossDev {
                    // 偏差标签含中文用默认 design，数值纯 ASCII 走 Mono sub（异常态警示金）
                    Text("偏差").font(Theme.font(.micro)).foregroundStyle(Theme.faint)
                    Mono(Fmt.pct(dev).replacingOccurrences(of: "+", with: ""), step: .sub, color: item.isAnomaly ? Theme.warn : Theme.faint)
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
