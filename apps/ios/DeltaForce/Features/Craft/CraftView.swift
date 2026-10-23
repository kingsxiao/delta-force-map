// CraftView.swift — 特勤处制造利润：工作台 / 防具台 / 技术中心 / 制药台
// 数据：/craft/craft.json（契约 §1.3）；最佳口径 = 价格完整配方中「每小时利润」
// 最大（制造台同一时间只能跑一条，时利才是真实约束）。SSE craft 事件驱动重拉。
import DeltaForceCore
import SwiftUI

struct CraftView: View {
    @Environment(AppModel.self) private var app

    /// 制造台筛选（nil = 全部）
    private enum PlaceScope: Hashable {
        case all
        case place(String)
    }
    /// 排序域（与网页端同四项；方向固定：时利/利润降序，成本/耗时升序）
    private enum SortKey: Hashable, CaseIterable {
        case hourly, profit, cost, period
        var label: String {
            switch self {
            case .hourly: "时利"
            case .profit: "单次利润"
            case .cost: "成本"
            case .period: "耗时"
            }
        }
    }
    private enum PriceScope: Hashable {
        case all
        case completeOnly
    }

    @State private var place: PlaceScope = .all
    @State private var sort: SortKey = .hourly
    @State private var priceScope: PriceScope = .all

    // 本页局部触觉 tick（刷新成败二分 / 筛选切换；对齐雷达页范式）
    @State private var refreshOkTick = 0
    @State private var refreshErrTick = 0
    @State private var toggleTick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 筛选变化后滚回榜首的锚点 id（§4.3-5）
    private static let topAnchor = "craft-top"

    private var feed: FeedModel<CraftSnapshot> { app.craft }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        CraftFeedHeader(feed: feed, channel: app.channel)
                        if let snap = feed.snapshot {
                            // 态势计数（StatusChip 族）：配方 / 完整 / 可盈利
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) {
                                    StatusChip(text: "配方 \(snap.stats.total)", tint: Theme.dim)
                                    StatusChip(text: "价格完整 \(snap.stats.complete)", tint: Theme.info)
                                    StatusChip(text: "可盈利 \(snap.stats.profitable)", tint: Theme.ok)
                                }
                                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                    HStack(spacing: 6) {
                                        StatusChip(text: "配方 \(snap.stats.total)", tint: Theme.dim)
                                        StatusChip(text: "价格完整 \(snap.stats.complete)", tint: Theme.info)
                                    }
                                    StatusChip(text: "可盈利 \(snap.stats.profitable)", tint: Theme.ok)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        filterRow
                    }
                    .listRowBackground(Theme.card)
                    .id(Self.topAnchor)

                    // 时利最佳（跟随制造台筛选；页面唯一主角数字 §1.1）
                    if let best {
                        Section {
                            CraftBestCard(item: best, placeLabel: placeLabel(of: best.place))
                        }
                        .listRowBackground(Theme.card)
                    }

                    Section("配方 · \(rows.count) 项") {
                        if rows.isEmpty {
                            if feed.snapshot == nil, let err = feed.lastError {
                                RetryErrorRow(
                                    message: err,
                                    retry: { Task { await feed.refresh() } },
                                    busy: feed.isLoading
                                )
                                .transition(.opacity) // 错误行出现淡入（§5，对齐 AmmoView/RadarView）
                            } else if feed.snapshot == nil {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.mini)
                                    Text("正在拉取特勤处数据…").font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                                }
                            } else {
                                ContentUnavailableView {
                                    Label("没有符合条件的配方", systemImage: "wrench.and.screwdriver")
                                } description: {
                                    Text("可切换制造台或价格口径")
                                } actions: {
                                    Button("显示全部配方") {
                                        place = .all
                                        priceScope = .all
                                    }
                                }
                                .transition(.opacity) // 空态出现淡入（§5，对齐 AmmoView）
                            }
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, item in
                            NavigationLink(value: item) {
                                CraftRow(rank: idx + 1, item: item, placeLabel: placeLabel(of: item.place))
                            }
                        }
                    }
                    .listRowBackground(Theme.card)

                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("口径").font(Theme.font(.xs, weight: .bold)).monospacedDigit().foregroundStyle(Theme.accent)
                            Text("利润为实时估算：材料按现价全部买入、产出按现价 × 数量挂卖并扣手续费（利润 = 收入 − 手续费 − 材料成本）。最佳 = 价格完整配方中每小时利润最高——制造台同一时间只能跑一条，时利才是真实约束。今日 / 7 日最高利润为乐观参照，不构成承诺。")
                                .font(Theme.font(.xs)).foregroundStyle(Theme.dim)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
                .themedList()
                .listStyle(.insetGrouped)
                .navigationTitle("特勤处制造")
                .navigationDestination(for: CraftItem.self) { item in
                    CraftDetailView(item: item, placeLabel: placeLabel(of: item.place))
                }
                .refreshable {
                    await feed.refresh()
                    if feed.lastError != nil { refreshErrTick += 1 } else { refreshOkTick += 1 }
                }
                .sensoryFeedback(.success, trigger: refreshOkTick)
                .sensoryFeedback(.error, trigger: refreshErrTick)
                .sensoryFeedback(.selection, trigger: toggleTick)
                .onChange(of: place) { _, _ in scopeChanged(proxy) }
                .onChange(of: priceScope) { _, _ in scopeChanged(proxy) }
            }
        }
    }

    /// 筛选行：制造台 + 价格口径 + 排序（共享 FilterMenu，§4.3-2 三页筛选范式）。
    /// 换用共享组件后 chip 自带 C8 降级（caption+value 单行放不下时 value 折 2 行），
    /// 且制造台 chip 偏离「全部」时同样点亮 accent（原手拼 chip 漏了该态）；
    /// 三枚并排放不下时折两行（与上方态势计数同款 ViewThatFits 降级，AX 韧性 §7-6）
    private var filterRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.sm) {
                placeMenu
                priceMenu
                sortMenu
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.sm) {
                    placeMenu
                    priceMenu
                }
                sortMenu
            }
        }
    }

    private var placeMenu: some View {
        FilterMenu(
            caption: "制造台",
            options: [FilterOption(id: PlaceScope.all, label: "全部")]
                + (feed.snapshot?.places ?? []).map { FilterOption(id: PlaceScope.place($0.id), label: $0.label) },
            selection: $place,
            defaultId: .all
        )
    }

    private var priceMenu: some View {
        FilterMenu(
            caption: "价格",
            options: [
                FilterOption(id: PriceScope.all, label: "全部"),
                FilterOption(id: PriceScope.completeOnly, label: "价格完整"),
            ],
            selection: $priceScope,
            defaultId: .all
        )
    }

    private var sortMenu: some View {
        FilterMenu(
            caption: "排序",
            options: SortKey.allCases.map { FilterOption(id: $0, label: $0.label) },
            selection: $sort,
            defaultId: .hourly
        )
    }

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

    /* ---------- 派生 ---------- */

    /// 行 / 最佳卡自己的台名（不受筛选范围影响）
    private func placeLabel(of id: String) -> String {
        feed.snapshot?.placeLabel(id) ?? id
    }

    /// 当前筛选 + 排序后的榜单（缺价 / 缺时利行沉底）
    private var rows: [CraftItem] {
        var list = feed.snapshot?.items ?? []
        if case .place(let p) = place { list = list.filter { $0.place == p } }
        if priceScope == .completeOnly { list = list.filter(\.isComplete) }
        let miss: (CraftItem) -> Bool = { !$0.hasEstimate }
        return list.sorted { a, b in
            if miss(a) != miss(b) { return miss(b) } // 可估算在前
            switch sort {
            case .hourly: return (a.profitPerHour ?? 0) > (b.profitPerHour ?? 0)
            case .profit: return (a.profit ?? 0) > (b.profit ?? 0)
            case .cost: return (a.cost ?? .infinity) < (b.cost ?? .infinity)
            case .period: return (a.periodHours ?? .infinity) < (b.periodHours ?? .infinity)
            }
        }
    }

    /// 时利最佳（跟随制造台筛选；价格完整是硬门槛）
    private var best: CraftItem? {
        guard let snap = feed.snapshot else { return nil }
        if case .place(let p) = place { return snap.best(place: p) }
        return snap.best()
    }
}

/// 制造页页头：连接点 / 版本 / 年龄 / 过期提示（FeedHeader 的同构轻量版，
/// 快照形状为 CraftSnapshot）
struct CraftFeedHeader: View {
    let feed: FeedModel<CraftSnapshot>
    let channel: LiveChannel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ConnectionDot(
                        state: channel.state,
                        error: feed.lastError != nil,
                        stale: feed.isDotStale(now: ctx.date),
                        showLabel: false
                    )
                    Spacer()
                    if feed.isLoading { ProgressView().controlSize(.mini) }
                    Mono(MarketMeta.formatVersionLabel(feed.snapshot?.version), step: .micro, color: Theme.dim)
                }
                if let snap = feed.snapshot {
                    Text("\(MarketMeta.sourceLabel(snap.source)) · 数据 \(MarketMeta.fmtAge(minutes: feed.ageMinutes(now: ctx.date)))前")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.faint)
                }
                if let err = feed.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.danger.opacity(0.08), in: Capsule())
                }
                if feed.isStale(now: ctx.date), let snap = feed.snapshot {
                    Text(MarketMeta.staleTipText(source: snap.source, ageMin: feed.ageMinutes(now: ctx.date)))
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.warn)
                }
            }
        }
        .id("\(feed.snapshot?.version ?? "-")-\(Int(feed.lastRefreshAt?.timeIntervalSince1970 ?? 0))")
    }
}

/// 时利最佳主卡：页面唯一主角数字（§1.1 主数字立权）
struct CraftBestCard: View {
    let item: CraftItem
    let placeLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: 6) {
                Image(systemName: "trophy")
                    .font(Theme.font(.micro, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("时利最佳")
                    .font(Theme.monoFont(.micro, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityHidden(true)

            HStack(spacing: Theme.Space.md) {
                ItemThumb(pic: item.output.pic, size: 44)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: 6) {
                        Text(item.output.name)
                            .font(Theme.font(.md, weight: .semibold))
                            .foregroundStyle(Theme.txStrong)
                            .lineLimit(2)
                        if item.output.count > 1 {
                            Text("×\(item.output.count)")
                                .font(Theme.monoFont(.xs, weight: .semibold))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    HStack(spacing: 6) {
                        CategoryChip(text: placeLabel)
                        GradeBadge(grade: item.output.grade)
                        if let lv = item.requiredLevel {
                            StatusChip(text: "Lv.\(lv)", tint: Theme.dim)
                        }
                    }
                }
                Spacer(minLength: Theme.Space.sm)
                // 主角数字：时利（hero 档 + 语义色，§1.3 同层级同档）
                VStack(alignment: .trailing, spacing: 2) {
                    Mono(hourlyText, step: .hero, color: profitColor, minScale: 0.7)
                    Text("每小时")
                        .font(Theme.font(.micro))
                        .foregroundStyle(Theme.faint)
                }
            }

            StatQuadRow(
                StatCell(label: "单次利润", value: Fmt.price(item.profit), color: profitColor, emphasis: .hero),
                StatCell(label: "材料成本", value: Fmt.price(item.cost), color: Theme.txStrong),
                StatCell(label: "制造耗时", value: item.periodLabel ?? "—", color: Theme.txStrong),
                StatCell(label: "成本回报", value: roiText, color: roiColor)
            )
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(bestA11y)
    }

    private var hourlyText: String {
        guard let p = item.profitPerHour else { return "—" }
        return p >= 0 ? "+\(Fmt.price(p))" : Fmt.price(p)
    }
    private var roiText: String {
        guard let roi = item.roi else { return "—" }
        return roi >= 0 ? "+\(Int((roi * 100).rounded()))%" : "\(Int((roi * 100).rounded()))%"
    }
    private var roiColor: Color {
        if let roi = item.roi { return roi >= 0 ? Theme.ok : Theme.danger }
        return Theme.dim
    }
    private var profitColor: Color {
        if let p = item.profit { return p >= 0 ? Theme.ok : Theme.danger }
        return Theme.dim
    }
    private var bestA11y: String {
        var parts = ["时利最佳", placeLabel, item.output.name]
        if let p = item.profitPerHour { parts.append("每小时利润 \(Fmt.price(p))") }
        if let profit = item.profit { parts.append("单次利润 \(Fmt.price(profit))") }
        return parts.joined(separator: "，")
    }
}

/// 榜单行：名次 / 图标 / 名称+徽标 / 右列主数字=时利（lead）次级=单次利润（sub）
struct CraftRow: View {
    let rank: Int
    let item: CraftItem
    let placeLabel: String
    @ScaledMetric(relativeTo: .subheadline) private var rankMinWidth = 30

    private var rankColor: Color { (1...3).contains(rank) ? Theme.accent : Theme.faint }

    var body: some View {
        HStack(spacing: 10) {
            Mono(String(format: "%02d", rank), step: .sub, color: rankColor)
                .frame(minWidth: rankMinWidth, alignment: .leading)
            ItemThumb(pic: item.output.pic, size: 36)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(item.output.name).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                    .layoutPriority(1)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        CategoryChip(text: placeLabel)
                        if !item.isComplete { StatusChip(text: "价格缺失", tint: Theme.warn) }
                        GradeBadge(grade: item.output.grade)
                    }
                    HStack(spacing: 6) {
                        if !item.isComplete { StatusChip(text: "价格缺失", tint: Theme.warn) }
                        GradeBadge(grade: item.output.grade)
                    }
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            if let p = item.profitPerHour {
                Mono(p >= 0 ? "+\(Fmt.price(p))" : Fmt.price(p), step: .lead, color: p >= 0 ? Theme.ok : Theme.danger, minScale: 0.75)
            } else {
                Mono("—", step: .lead, color: Theme.faint)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Text("利润").font(Theme.font(.micro)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: true, vertical: false)
                Mono(Fmt.price(item.profit), step: .sub, color: Theme.dim)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var a11yLabel: String {
        var parts = ["第 \(rank) 名", placeLabel, item.output.name]
        if !item.isComplete { parts.append("价格缺失") }
        if let p = item.profitPerHour { parts.append("每小时利润 \(Fmt.price(p))") }
        if let profit = item.profit { parts.append("单次利润 \(Fmt.price(profit))") }
        if let period = item.periodLabel { parts.append("耗时 \(period)") }
        return parts.joined(separator: "，")
    }
}
