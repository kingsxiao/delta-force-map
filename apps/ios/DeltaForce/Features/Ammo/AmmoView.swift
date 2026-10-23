// AmmoView.swift — 子弹行情：买入 / 卖出信号卡 + 全表（筛选 / 排序 / 搜索 / 自选置顶）
// 精修对齐 DESIGN.md §4.1：列表行权重反转 / 信号卡主数字立权 / 刷新二分触感 /
// 筛选排序回顶 / RetryErrorRow 防空转 / 可点卡片按压态
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: Filter = .all
    @State private var sort: Sort = .profit
    @State private var query = ""
    @State private var showPlaybook = false
    // 显式导航栈：通知深链（app.pendingDetailName）需要从视图外 programmatically
    // push 详情；NavigationPath 装 MarketItem（Hashable，与行内 NavigationLink 同轨）
    @State private var path = NavigationPath()
    // 本页局部触觉 tick（规范：trigger 只绑本页 State，共享 Store 派生值会被详情页 / 雷达页等入口误触发）
    @State private var favTick = 0
    @State private var posTick = 0 // 移出囤货（台账是本地账本操作，非买卖成败：用 selection 触感）
    @State private var refreshOkTick = 0 // 刷新成功（§4.1-3 二分：成功 .success / 失败 .error 各自触感）
    @State private var refreshErrTick = 0 // 刷新失败
    @State private var menuTick = 0
    @State private var sheetTick = 0

    /// 筛选/排序切换后滚回榜首的锚点 id（§4.1-4，对齐 TTK topAnchor 方案）
    private static let topAnchor = "ammo-top"

    /// 信号卡入口（§4.1-7）：可点卡片按压态——lift 按压面由本样式承担、lineHover 描边由
    /// SignalCard 的 card(hoverable:) 常驻给出；拆独立函数避免链式修饰符撑爆 ForEach 闭包的 type-checker
    private func signalCardLink(_ item: MarketItem) -> some View {
        NavigationLink(value: item) {
            SignalCard(item: item)
        }
        .buttonStyle(SignalCardPressStyle())
    }

    /// 卖出信号卡同款入口（拆独立函数同 signalCardLink：避免链式修饰符撑爆 type-checker）
    private func sellCardLink(_ item: MarketItem) -> some View {
        NavigationLink(value: item) {
            SellSignalCard(item: item)
        }
        .buttonStyle(SignalCardPressStyle())
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                List {
                    Section {
                        FeedHeader(feed: app.market, channel: app.channel)
                            .id(Self.topAnchor)
                    }
                    .listRowBackground(Theme.card)

                    // 我的囤货（纯本地台账，有持仓才显示）：页头总览之下、买入信号之上，
                    // 不新增筛选档位；浮盈 / 到价状态随行情快照实时 join，左滑移出
                    if !app.positions.positions.isEmpty {
                        Section("我的囤货 · \(app.positions.positions.count)") {
                            ForEach(app.positions.positions) { pos in
                                positionRow(pos)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            app.positions.remove(pos.name)
                                            posTick += 1
                                        } label: {
                                            Label("移出囤货", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .listRowBackground(Theme.card)
                    }

                    if filter == .all, query.isEmpty {
                        let buys = app.market.items.filter { $0.signal == .buy }
                        if !buys.isEmpty {
                            Section("买入信号 · \(buys.count)") {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(buys) { item in
                                            signalCardLink(item)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                // §4.1-8：卡片滚出行缘不裁剪（视觉出血暗示可横滑）。
                                // 注意：DESIGN 命名的 .scrollClipPadding 在任何已发布 SwiftUI 中都不存在
                                // （已在 iPhoneSimulator27.1 SDK 的 SwiftUI.swiftinterface 验证：0 命中），
                                // 出血意图改用 iOS 16 的 scrollClipDisabled() 实现（P2 非必须项的降级落地）
                                .scrollClipDisabled()
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            }
                            .listRowBackground(Color.clear)
                        }

                        // 卖出信号（与网页端「卖出高位简表」对齐）：按分位降序（越贴近 7 天
                        // 高位越靠前）；买入区块之下、全表之上，同款横滑卡与出血口径
                        let sells = app.market.items
                            .filter { $0.signal == .sell }
                            .sorted { ($0.rank ?? 0) > ($1.rank ?? 0) }
                        if !sells.isEmpty {
                            Section("卖出信号 · \(sells.count)") {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(sells) { item in
                                            sellCardLink(item)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .scrollClipDisabled()
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            }
                            .listRowBackground(Color.clear)
                        }
                    }

                    Section("\(filter.rawValue) · \(rows.count) 种") {
                        if rows.isEmpty {
                            if app.market.snapshot == nil, let err = app.market.lastError {
                                // 首拉失败：换共享 RetryErrorRow（§4.1-6 / C10）——busy 时禁用重试 + 内联进度，消除空转
                                RetryErrorRow(
                                    message: err,
                                    retry: { Task { await app.market.refresh() } },
                                    busy: app.market.isLoading
                                )
                                .transition(.opacity) // 错误行出现淡入（§5）
                            } else if app.market.snapshot == nil {
                                HStack(spacing: Theme.Space.sm) {
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
                                .transition(.opacity) // 空态出现淡入（§5）
                            }
                        }
                        ForEach(rows) { item in
                            NavigationLink(value: item) {
                                AmmoRow(item: item, pen: pen(of: item), starred: app.favorites.contains(item.name))
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
                // TTK 联动：穿透徽章的数据源是 bundle 内 ttk.json（加载一次，毫秒级）；
                // 行情是首 Tab，用户可能从未进过 TTK 页，这里兜底触发首次加载
                .onAppear {
                    app.ttk.loadIfNeeded()
                    // 通知深链兜底：点击通知时若本页尚未挂载（停在别的 Tab），onChange
                    // 已错过置位时机，onAppear 补消费一次（已挂载场景由 onChange 承担）
                    consumePendingDetail(app.pendingDetailName)
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索弹药")
                .navigationTitle("子弹行情")
                .navigationDestination(for: MarketItem.self) { ItemDetailView(item: $0) }
                .refreshable {
                    await app.market.refresh()
                    // 刷新反馈二分（§4.1-3）：失败 .error / 成功 .success；年龄归零（C6）与错误胶囊（C7）已由共享层承担
                    if app.market.lastError != nil {
                        refreshErrTick += 1
                    } else {
                        refreshOkTick += 1
                    }
                }
                .sensoryFeedback(.success, trigger: favTick)
                .sensoryFeedback(.selection, trigger: posTick)
                .sensoryFeedback(.success, trigger: refreshOkTick)
                .sensoryFeedback(.error, trigger: refreshErrTick)
                .sensoryFeedback(.selection, trigger: menuTick)
                .sensoryFeedback(.selection, trigger: sheetTick)
                .onChange(of: filter) { _, _ in filterChanged(proxy) }
                .onChange(of: sort) { _, _ in filterChanged(proxy) }
                // 通知深链：弹名在当前快照 → 直达详情；查不到（下架 / 改名 / 快照
                // 未拉到）→ 兑底走 pendingQuery 搜索词通道。消费后置 nil 防重复触发
                .onChange(of: app.pendingDetailName) { _, name in consumePendingDetail(name) }
                .onChange(of: app.pendingQuery) { _, q in
                    guard let q, !q.isEmpty else { return }
                    app.pendingQuery = nil
                    query = q
                }
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
    }

    /// 筛选/排序切换（§4.1-4）：轻触反馈 + 回顶（换筛选=换榜单，不停在长列表深处）；
    /// Reduce Motion 下改无动画直达（§7-9，触感保留）
    private func filterChanged(_ proxy: ScrollViewProxy) {
        menuTick += 1
        if reduceMotion {
            proxy.scrollTo(Self.topAnchor, anchor: .top)
        } else {
            withAnimation(.easeOut(duration: Theme.durMed)) {
                proxy.scrollTo(Self.topAnchor, anchor: .top)
            }
        }
    }

    /// 通知深链消费：先置 nil（防 onChange/onAppear 双路径重复触发），再按弹名在
    /// 当前快照查条目 push；查不到时绝不 append 空值，兑底转 pendingQuery 搜索词
    private func consumePendingDetail(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        app.pendingDetailName = nil
        if let item = app.market.items.first(where: { $0.name == name }) {
            path.append(item)
        } else {
            app.pendingQuery = name
        }
    }

    private var menuActive: Bool { filter != .all || sort != .profit }

    /// TTK 联动：弹名 → 穿透等级（别名映射见 shared/data/ammo-alias.js 的口径——
    /// 一对多歧义 / 国服命名无同型 / 弓弩箭矢一律返回 nil，不显徽章，宁缺勿错）
    private func pen(of item: MarketItem) -> Int? {
        app.ammoAlias.pen(marketName: item.name, calibers: app.ttk.data?.calibers ?? [:])
    }

    /// 囤货行：弹名仍在当前快照 → 可点进详情；已不在（下架 / 改名）→ 灰行只读，
    /// 保留账本记录不自动删（快照可能只是暂时缺这条）
    @ViewBuilder
    private func positionRow(_ pos: AmmoPosition) -> some View {
        if let item = app.market.items.first(where: { $0.name == pos.name }) {
            NavigationLink(value: item) { PositionRow(position: pos, item: item) }
        } else {
            PositionRow(position: pos, item: nil)
        }
    }

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
    /// 穿透等级（TTK 联动；nil = 无映射不显徽章）
    var pen: Int? = nil
    var starred = false

    var body: some View {
        HStack(spacing: 10) {
            ItemThumb(pic: item.pic, size: 40)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    if starred { Image(systemName: "star.fill").font(Theme.font(.micro)).foregroundStyle(Theme.warn) }
                    Text(item.name).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                }
                .layoutPriority(1) // 名称行优先保住单行高度，宽度不足时由本行截断承担
                HStack(spacing: 6) {
                    GradeBadge(grade: item.grade)
                    if let pen { PenBadge(pen: pen) }
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
            Spacer(minLength: Theme.Space.xs)
            // 右列权重反转（§4.1-1）：收益率/预赚在上（lead + ok——默认排序依据即扫读主角），
            // 现价降次级（sub + tx）在下；无收益率数据（曲线不足）时现价即本行主数字、占 lead（§1.3 档位跟层级走）
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                if let p = item.profitPerRound, item.rank != nil {
                    Mono("\(p >= 0 ? "+" : "")\(Fmt.price(p)) \(Fmt.pct(item.profitPct))", step: .lead, color: p > 0 ? Theme.ok : Theme.faint)
                    Mono(Fmt.price(item.current), step: .sub, color: Theme.tx)
                } else {
                    Mono(Fmt.price(item.current), step: .lead)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75) // 徽标保理想宽后溢压移到价格列：随行内可用宽缩一档，不折行（同 StatCell 兜底）
            Sparkline(curve: item.curve, color: Theme.signal(item.signal))
                .frame(width: 56, height: 26)
        }
        .padding(.vertical, 2)
        // 整行合并为单一朗读元素：名称 / 等级 / 信号 / 分位 / 预赚 / 现价 / 自选 一句话转述
        // （语序对齐视觉 §4.1-1：预赚在上先读；缩略图与走势线已 accessibilityHidden，不重复聚焦）
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// 成句转述，替代逐控件拼读
    private var a11yLabel: String {
        var parts: [String] = [item.name]
        if let grade = item.grade { parts.append("\(grade)级") }
        if let pen { parts.append("穿透 \(pen) 级") }
        parts.append(item.isAnomaly ? "双源异常" : item.signal.label)
        if let rank = item.rank { parts.append("7 天分位 \(Fmt.rankPercent(rank))") }
        // 语序对齐视觉（§4.1-1）：预赚在上、现价在下
        if let p = item.profitPerRound, item.rank != nil {
            parts.append("预赚 \(p >= 0 ? "+" : "")\(Fmt.price(p)) 每发（\(Fmt.pct(item.profitPct))）")
        }
        if let current = item.current { parts.append("现价 \(Fmt.price(current))") }
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
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                ItemThumb(pic: item.pic, size: 30)
                Text(item.name).font(Theme.font(.sm, weight: .bold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                Spacer()
                GradeBadge(grade: item.grade)
            }
            HStack(spacing: 10) {
                // 三格输入数据（§4.1-2）：StatCell plain 即 sub 档（14 semibold），让位主数字
                StatCell(label: "买入 ≤", value: Fmt.price(item.current))
                StatCell(label: "挂卖", value: Fmt.price(item.targetSell), color: Theme.danger)
                StatCell(label: "到手", value: Fmt.price(item.netSell))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // 主数字立权（§4.1-2）：预赚与收益率升 lead 档 ok 加粗。
                // 「预赚 …/发」中英混排：默认 design + 等宽数字（lead=16/body，mono 只留给纯 ASCII）
                Text("预赚 +\(Fmt.price(item.profitPerRound))/发")
                    .font(Theme.font(.lg, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ok)
                Mono(Fmt.pct(item.profitPct), step: .lead, color: Theme.ok)
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
        // 可点卡片（§4.1-7）：描边换 lineHover 暗示入口；按压 lift 面见 SignalCardPressStyle
        .card(hoverable: true)
    }
}

/// 卖出信号卡（与网页端「卖出高位简表」口径对齐）：现价 / 7 天最高 /
/// 距最高涨幅（高位分位）；信号语义 = 现价贴近 7 天高位，持仓建议出货。
struct SellSignalCard: View {
    let item: MarketItem
    /// 缩放宽：与买入卡同节奏，字阶放大时卡片同步变宽
    @ScaledMetric(relativeTo: .body) private var cardWidth = 250

    /// 距 7 天最高还有多少涨幅空间（%）；最高缺数据或现价异常时为 nil
    private var liftToHigh: Double? {
        guard let c = item.current, let high = item.weekHigh, c > 0 else { return nil }
        return (high - c) / c
    }

    var body: some View {
        let eta = SellEtaEngine.predict(item: item)
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                ItemThumb(pic: item.pic, size: 30)
                Text(item.name).font(Theme.font(.sm, weight: .bold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                Spacer()
                GradeBadge(grade: item.grade)
            }
            HStack(spacing: 10) {
                StatCell(label: "现价", value: Fmt.price(item.current))
                StatCell(label: "7天最高", value: Fmt.price(item.weekHigh), color: Theme.danger)
                StatCell(label: "到手", value: Fmt.price(item.netHigh))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // 主数字立权（同买入卡 §4.1-2）：高位分位 lead 档 danger；距最高为辅读数
                Mono(highRankText, step: .lead, color: Theme.danger)
                if let liftToHigh {
                    Text("距最高 +\(Fmt.pct(liftToHigh))")
                        .font(Theme.font(.md, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                }
            }
            RankBar(item: item)
            if let eta, let peak = SellEtaEngine.fmtPeak(start: eta.peakStart, end: eta.peakEnd) {
                Text("已贴近 7 天高位，日内 \(peak) 通常最贵").font(Theme.font(.xs)).foregroundStyle(Theme.dim)
            } else {
                Text("已贴近 7 天高位，持仓建议出货").font(Theme.font(.xs)).foregroundStyle(Theme.dim)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
        .card(hoverable: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    private var highRankText: String {
        guard let rank = item.rank else { return "高位 —" }
        return "高位 \(Int((rank * 100).rounded()))%"
    }

    private var a11yLabel: String {
        var parts = [item.name, "卖出信号，现价 \(Fmt.price(item.current))"]
        if let liftToHigh { parts.append("距 7 天最高 +\(Fmt.pct(liftToHigh))")
        }
        parts.append("持仓建议出货")
        return parts.joined(separator: "，")
    }
}

/// 囤货台账行（「我的囤货」Section 用）：数量 × 成本 → 现价 / 到价浮盈（挂 P75
/// 税后口径）；item=nil = 弹名已不在当前行情快照（下架 / 改名），只展示账本本体
struct PositionRow: View {
    let position: AmmoPosition
    let item: MarketItem?

    /// 现价已达挂卖价（targetSell）：右列浮盈即可兑现，行内徽章提示
    private var atTarget: Bool {
        guard let c = item?.current, let t = item?.targetSell else { return false }
        return c >= t
    }

    /// 到价浮盈：挂 P75 税后到手（netSell）口径，行内主数字
    private var gainNet: Double? {
        guard let netSell = item?.netSell else { return nil }
        return (netSell - position.cost) * Double(position.qty)
    }

    var body: some View {
        HStack(spacing: 10) {
            if let item { ItemThumb(pic: item.pic, size: 40) }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    Text(position.name).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                    if atTarget { StatusChip(text: "已到挂卖价", tint: Theme.danger) }
                    if item == nil { StatusChip(text: "不在当前行情", tint: Theme.faint) }
                }
                .layoutPriority(1) // 名称行优先保住单行，宽度不足时由本行截断承担（同 AmmoRow）
                Text("\(position.qty) 发 × 成本 \(Fmt.price(position.cost))")
                    .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.faint)
            }
            Spacer(minLength: Theme.Space.xs)
            // 右列对齐 AmmoRow 权重：浮盈在上（lead + ok/danger），现价在下（sub + tx）
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                if let item { Mono(Fmt.price(item.current), step: .sub, color: Theme.tx) }
                if let gainNet {
                    Mono("\(gainNet >= 0 ? "+" : "-")\(Fmt.price(abs(gainNet)))", step: .lead, color: gainNet >= 0 ? Theme.ok : Theme.danger)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75) // 同 AmmoRow：徽标保理想宽后溢压移到数字列
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// 成句转述，替代逐控件拼读
    private var a11yLabel: String {
        var parts = [position.name, "\(position.qty) 发，成本 \(Fmt.price(position.cost)) 每发"]
        if let item {
            if let c = item.current { parts.append("现价 \(Fmt.price(c))") }
            if let gainNet {
                parts.append("到价浮盈 \(gainNet >= 0 ? "+" : "-")\(Fmt.price(abs(gainNet)))")
            }
            if atTarget { parts.append("已到挂卖价，可出货") }
        } else {
            parts.append("已不在当前行情")
        }
        return parts.joined(separator: "，")
    }
}

/// 信号卡按压态（§4.1-7）：按压叠 lift 面（白 6%）、durFast 淡出；Reduce Motion 直接切换（§7-9）
private struct SignalCardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .fill(Theme.lift)
                    .opacity(configuration.isPressed ? 1 : 0)
            )
            .animation(reduceMotion ? nil : .easeOut(duration: Theme.durFast), value: configuration.isPressed)
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
