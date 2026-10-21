// AmmoView.swift — 子弹行情：买入信号卡 + 全表（筛选 / 排序 / 搜索 / 自选置顶）
import DeltaForceCore
import SwiftUI

struct AmmoView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", buy = "买入", sell = "卖出", watch = "关注", favorites = "自选"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case profit = "收益率", rank = "分位（低→高）", price = "现价", grade = "等级", name = "名称"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @State private var filter: Filter = .all
    @State private var sort: Sort = .profit
    @State private var query = ""
    @State private var showPlaybook = false
    // 本页局部触觉 tick（规范：trigger 只绑本页 State，共享 Store 派生值会被详情页 / 雷达页等入口误触发）
    @State private var favTick = 0
    @State private var refreshTick = 0
    @State private var menuTick = 0
    @State private var sheetTick = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    FeedHeader(feed: app.market, channel: app.channel)
                }
                .listRowBackground(Theme.card)

                if filter == .all, query.isEmpty {
                    let buys = app.market.items.filter { $0.signal == .buy }
                    if !buys.isEmpty {
                        Section("买入信号 · \(buys.count)") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(buys) { item in
                                        // 不加 .plain：保留系统按压高亮，卡片可被识别为可点入口
                                        NavigationLink(value: item) { SignalCard(item: item) }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        }
                        .listRowBackground(Color.clear)
                    }
                }

                Section("\(filter.rawValue) · \(rows.count) 种") {
                    if rows.isEmpty {
                        if app.market.snapshot == nil, let err = app.market.lastError {
                            // 首拉失败：错误态 + 重试，不再伪装成「正在加载」
                            FeedErrorView(message: err) {
                                Task { await app.market.refresh() }
                            }
                        } else if app.market.snapshot == nil {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.mini)
                                Text("正在拉取行情…").font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                            }
                        } else {
                            // 筛选 / 搜索空态：给一条出路
                            ContentUnavailableView {
                                Label("没有符合条件的弹药", systemImage: "line.3.horizontal.decrease.circle")
                            } description: {
                                Text("换个筛选或清空搜索再试")
                            } actions: {
                                Button("清除筛选与搜索") {
                                    filter = .all
                                    query = ""
                                }
                            }
                        }
                    }
                    ForEach(rows) { item in
                        NavigationLink(value: item) {
                            AmmoRow(item: item, starred: app.favorites.contains(item.name))
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                app.favorites.toggle(item.name)
                                favTick += 1
                            } label: {
                                // 按状态给标签：未自选「加入自选」/ 已自选「取消自选」
                                let starred = app.favorites.contains(item.name)
                                Label(starred ? "取消自选" : "加入自选", systemImage: starred ? "star.slash" : "star")
                            }
                            .tint(Theme.warn)
                        }
                    }
                }
                .listRowBackground(Theme.card)

                Section {
                    MethodNote(source: app.market.snapshot?.source)
                }
                .listRowBackground(Theme.card)
            }
            .themedList()
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索弹药")
            .navigationTitle("子弹行情")
            .navigationDestination(for: MarketItem.self) { ItemDetailView(item: $0) }
            .refreshable {
                await app.market.refresh()
                refreshTick += 1 // 刷新完成：轻触反馈
            }
            .sensoryFeedback(.success, trigger: favTick)
            .sensoryFeedback(.impact(weight: .light), trigger: refreshTick)
            .sensoryFeedback(.selection, trigger: menuTick)
            .sensoryFeedback(.selection, trigger: sheetTick)
            .onChange(of: filter) { _, _ in menuTick += 1 }
            .onChange(of: sort) { _, _ in menuTick += 1 }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        // 选项带 SF 图标：浮层行内图标 + 系统 checkmark（根 tint = Theme.accent），
                        // 与 App Store / 备忘录的下拉筛选同款观感
                        Picker("筛选", selection: $filter) {
                            Label("全部", systemImage: "square.grid.2x2").tag(Filter.all)
                            Label("买入", systemImage: "arrow.down.circle.fill").tag(Filter.buy)
                            Label("卖出", systemImage: "arrow.up.circle.fill").tag(Filter.sell)
                            Label("关注", systemImage: "eye").tag(Filter.watch)
                            Label("自选", systemImage: "star.fill").tag(Filter.favorites)
                        }
                        Picker("排序", selection: $sort) {
                            Label("收益率", systemImage: "chart.line.uptrend.xyaxis").tag(Sort.profit)
                            Label("分位（低→高）", systemImage: "chart.bar.fill").tag(Sort.rank)
                            Label("现价", systemImage: "banknote").tag(Sort.price)
                            Label("等级", systemImage: "shield.lefthalf.filled").tag(Sort.grade)
                            Label("名称", systemImage: "textformat.abc").tag(Sort.name)
                        }
                    } label: {
                        // 偏离默认（全部 / 收益率）时图标点亮，label 附当前值
                        Label(
                            menuActive ? "筛选：\(filter.rawValue) · \(sort.rawValue)" : "筛选",
                            systemImage: menuActive
                                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                        )
                    }
                    Button {
                        sheetTick += 1
                        showPlaybook = true
                    } label: { Label("倒卖手册", systemImage: "book") }
                }
            }
            .sheet(isPresented: $showPlaybook) { PlaybookView() }
        }
    }

    private var menuActive: Bool { filter != .all || sort != .profit }

    private var rows: [MarketItem] {
        var list = app.market.items
        switch filter {
        case .all: break
        case .buy: list = list.filter { $0.signal == .buy }
        case .sell: list = list.filter { $0.signal == .sell }
        case .watch: list = list.filter { $0.signal == .watch }
        case .favorites: list = list.filter { app.favorites.contains($0.name) }
        }
        if !query.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        list.sort { a, b in
            let fa = app.favorites.contains(a.name), fb = app.favorites.contains(b.name)
            if fa != fb { return fa }
            switch sort {
            case .profit: return (a.profitPct ?? -.infinity) > (b.profitPct ?? -.infinity)
            case .rank: return (a.rank ?? 2) < (b.rank ?? 2)
            case .price: return (a.current ?? 0) > (b.current ?? 0)
            case .grade: return (a.grade ?? 0) > (b.grade ?? 0)
            case .name: return a.name < b.name
            }
        }
        return list
    }
}

struct AmmoRow: View {
    let item: MarketItem
    var starred = false

    var body: some View {
        HStack(spacing: 10) {
            ItemThumb(pic: item.pic, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if starred { Image(systemName: "star.fill").font(Theme.font(.micro)).foregroundStyle(Theme.warn) }
                    Text(item.name).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                }
                .layoutPriority(1) // 名称行优先保住单行高度，宽度不足时由本行截断承担
                HStack(spacing: 6) {
                    GradeBadge(grade: item.grade)
                    SignalChip(signal: item.signal, anomaly: item.isAnomaly)
                    if let rank = item.rank {
                        // 含中文（「分位」）：默认 design + 等宽数字
                        Text("分位 \(Fmt.rankPercent(rank))")
                            .font(Theme.font(.xs)).monospacedDigit()
                            .lineLimit(1) // 徽章行统一单行：此文本先于徽标截断
                            .foregroundStyle(Theme.faint)
                    } else {
                        Text(item.reason ?? "数据不足")
                            .font(Theme.font(.xs))
                            .lineLimit(1) // 同上：徽章行统一单行
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Mono(Fmt.price(item.current), size: 15)
                if let p = item.profitPerRound, item.rank != nil {
                    Mono("\(p >= 0 ? "+" : "")\(Fmt.price(p)) \(Fmt.pct(item.profitPct))", size: 12, weight: .medium, color: p > 0 ? Theme.ok : Theme.faint, relativeTo: .footnote)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75) // 徽标保理想宽后溢压移到价格列：随行内可用宽缩一档，不折行（同 StatCell 兜底）
            Sparkline(curve: item.curve, color: Theme.signal(item.signal))
                .frame(width: 56, height: 26)
        }
        .padding(.vertical, 2)
        // 整行合并为单一朗读元素：名称 / 等级 / 信号 / 分位 / 现价 / 预赚 / 自选 一句话转述
        // （缩略图与走势线已 accessibilityHidden，不重复聚焦）
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// 成句转述，替代逐控件拼读
    private var a11yLabel: String {
        var parts: [String] = [item.name]
        if let grade = item.grade { parts.append("\(grade)级") }
        parts.append(item.isAnomaly ? "双源异常" : item.signal.label)
        if let rank = item.rank { parts.append("7 天分位 \(Fmt.rankPercent(rank))") }
        if let current = item.current { parts.append("现价 \(Fmt.price(current))") }
        if let p = item.profitPerRound, item.rank != nil {
            parts.append("预赚 \(p >= 0 ? "+" : "")\(Fmt.price(p)) 每发（\(Fmt.pct(item.profitPct))）")
        }
        if starred { parts.append("已自选") }
        return parts.joined(separator: "，")
    }
}

/// 买入信号卡：买入价 / 挂卖价 / 到手 / 预赚 / 预计到价
struct SignalCard: View {
    let item: MarketItem
    /// 缩放宽：字阶放大时卡片同步变宽，内容不被截断
    @ScaledMetric(relativeTo: .body) private var cardWidth = 250

    var body: some View {
        let eta = SellEtaEngine.predict(item: item)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ItemThumb(pic: item.pic, size: 30)
                Text(item.name).font(Theme.font(.sm, weight: .bold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                Spacer()
                GradeBadge(grade: item.grade)
            }
            HStack(spacing: 10) {
                StatCell(label: "买入 ≤", value: Fmt.price(item.current))
                StatCell(label: "挂卖", value: Fmt.price(item.targetSell), color: Theme.danger)
                StatCell(label: "到手", value: Fmt.price(item.netSell))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // 「预赚 …/发」中英混排：默认 design + 等宽数字
                Text("预赚 +\(Fmt.price(item.profitPerRound))/发")
                    .font(Theme.font(.sm, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.ok)
                Mono(Fmt.pct(item.profitPct), size: 12, weight: .medium, color: Theme.ok, relativeTo: .footnote)
            }
            RankBar(item: item)
            if let eta, let med = eta.medianH, eta.episodes >= 2 {
                Text("预计 \(SellEtaEngine.fmtHours(med)) 到价（\(eta.etaLabel ?? "—")，\(eta.episodes) 次样本）")
                    .font(Theme.font(.xs)).foregroundStyle(Theme.dim)
            } else if let eta, let peak = SellEtaEngine.fmtPeak(start: eta.peakStart, end: eta.peakEnd) {
                Text("日内 \(peak) 通常最贵").font(Theme.font(.xs)).foregroundStyle(Theme.dim)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
        .card()
    }
}

struct MethodNote: View {
    let source: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 含中文标题：默认 design + 等宽数字（mono 只留给纯 ASCII）
            Text("口径").font(Theme.font(.xs, weight: .bold)).monospacedDigit().foregroundStyle(Theme.accent)
            Text(MarketMeta.methodDataLine(source)).font(Theme.font(.xs)).foregroundStyle(Theme.dim)
            Text("买卖点 = 近 7 天小时曲线分位数回归：现价 ≤ P25 且税后收益率 ≥ 8% 判「买入」、≥ P80 判「卖出」、≤ P35 判「关注」；目标挂卖价取 P75，税率按税后价实测反推（约 15%）。历史分位不代表未来走势，信号仅供参考。")
                .font(Theme.font(.xs)).foregroundStyle(Theme.dim)
        }
    }
}

/// 首拉失败错误态（行情 / 雷达共用）：错误文案 +「重试」。
/// 仅在 snapshot 为空且 lastError 非空时由调用方给出，不与加载 / 筛选空态混用。
struct FeedErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Label(message, systemImage: "wifi.exclamationmark")
                .font(Theme.font(.xs))
                .foregroundStyle(Theme.danger)
                .multilineTextAlignment(.center)
            Button("重试", action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
