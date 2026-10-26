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

    /// 买入信号卡数据源（卖出简表同源过滤）：从 body 局部 let 提为计算属性，
    /// 供 Section 渲染与 anchorHost 宿主判定共用同一份数据，避免两处口径漂移
    private var buys: [MarketItem] { app.market.items.filter { $0.signal == .buy } }

    /// 卖出信号（按分位降序，越贴近 7 天高位越靠前——与网页端「卖出高位简表」同口径）
    private var sells: [MarketItem] {
        app.market.items
            .filter { $0.signal == .sell }
            .sorted { ($0.rank ?? 0) > ($1.rank ?? 0) }
    }

    /// 数据源错误横幅文案：有快照的后台刷新失败才在此提示，正常态 nil
    /// （首拉失败由全表区 RetryErrorRow 承担，见 body 内注释）
    private var bannerMessage: String? {
        app.market.snapshot != nil ? app.market.lastError : nil
    }

    /// 回顶锚点宿主：锚点行必须常驻且永远在列表最顶部（§4.1-4 scrollTo 落点 = 真顶）。
    /// banner 态随 banner Section；正常态随「首个真实渲染的 Section」首行
    /// （囤货 > 买入信号 > 卖出信号 > 全表）——省去原先独占一节的空 banner 行
    private enum AnchorHost { case banner, positions, buys, sells, table }

    private var anchorHost: AnchorHost {
        if bannerMessage != nil { return .banner }
        if !app.positions.positions.isEmpty { return .positions }
        if filter == .all, query.isEmpty {
            if !buys.isEmpty { return .buys }
            if !sells.isEmpty { return .sells }
        }
        return .table
    }

    /// 筛选回顶锚点：零高度隐形行（同一时刻仅 anchorHost 命中的一处渲染，id 不冲突），
    /// 保证 scrollTo(ammo-top) 永远有目标
    private var topAnchorRow: some View {
        Color.clear
            .frame(height: 0)
            .accessibilityHidden(true)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .id(Self.topAnchor)
    }

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
                    // 数据源错误横幅（有快照的后台刷新失败提示）。无快照的首拉失败由下方
                    // 全表区的 RetryErrorRow 承担（带重试出口），不同屏双份。
                    // 正常态整个 Section 条件退场：原先 banner（if let 空渲染）+ 零高锚点独占
                    // 一节，无内容仍占 List 行壳 + 节距，实测搜索栏下多出 ~92pt 死空间
                    // （其余三 Tab 仅 ~13pt——它们把 banner 嵌在有内容的行内）
                    if bannerMessage != nil {
                        Section {
                            FeedErrorBanner(message: bannerMessage)
                            if anchorHost == .banner { topAnchorRow }
                        }
                        .listRowBackground(Theme.card)
                    }

                    // 我的囤货（纯本地台账，有持仓才显示）：页头总览之下、买入信号之上，
                    // 不新增筛选档位；浮盈 / 到价状态随行情快照实时 join，左滑移出
                    if !app.positions.positions.isEmpty {
                        Section("我的囤货 · \(app.positions.positions.count)") {
                            if anchorHost == .positions { topAnchorRow }
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
                        if !buys.isEmpty {
                            Section("买入信号 · \(buys.count)") {
                                if anchorHost == .buys { topAnchorRow }
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
                        if !sells.isEmpty {
                            Section("卖出信号 · \(sells.count)") {
                                if anchorHost == .sells { topAnchorRow }
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
                        if anchorHost == .table { topAnchorRow }
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
                // UI 巡检钩子（同 RootView -startTab 模式，生产无此参数）：-openDetailFirst
                // 等首个快照落地后 push 首行详情、-openPlaybook 直达倒卖手册、
                // -wfScrollEnd 滚到列表末尾补拍折叠区
                .task { await shotHook(proxy) }
            }
        }
    }

    /// UI 巡检钩子：等首个快照落地（最多 10s，网络快照非即时）再执行，避免深链
    /// 落在空列表上；详情 push 与行内 NavigationLink 同轨（path.append）
    @MainActor
    private func shotHook(_ proxy: ScrollViewProxy) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-openDetailFirst") || args.contains("-openPlaybook") || args.contains("-wfScrollEnd") else { return }
        for _ in 0..<100 {
            if !app.market.items.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if args.contains("-openDetailFirst"), let first = app.market.items.first {
            path.append(first)
        }
        if args.contains("-openPlaybook") { showPlaybook = true }
        if args.contains("-wfScrollEnd") {
            // List 懒加载行首次布局完成前 scrollTo 会落空，数据就绪后再等一拍才滚；
            // 目标取最后一行自己的 id——滚 topAnchor 只能把首 Section 对进首屏，到不了列表末尾
            try? await Task.sleep(for: .milliseconds(800))
            if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
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

    /// 等级 / 穿透 / 信号三枚徽章（全部 fixedSize，恒保理想宽）
    @ViewBuilder
    private var badgeTray: some View {
        GradeBadge(grade: item.grade)
        if let pen { PenBadge(pen: pen) }
        SignalChip(signal: item.signal, anomaly: item.isAnomaly)
    }

    /// 徽章行第 4 元素：有分位读「分位 N%」（含中文默认 design + 等宽数字），无分位给原因说明
    @ViewBuilder
    private var rankOrReason: some View {
        if let rank = item.rank {
            Text("分位 \(Fmt.rankPercent(rank))")
                .font(Theme.font(.xs)).monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(Theme.faint)
        } else {
            Text(item.reason ?? "数据不足")
                .font(Theme.font(.xs))
                .lineLimit(1)
                .foregroundStyle(Theme.faint)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ItemThumb(pic: item.pic, size: 40)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    if starred { Image(systemName: "star.fill").font(Theme.font(.micro)).foregroundStyle(Theme.warn) }
                    Text(item.name).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                }
                .layoutPriority(1) // 名称行优先保住单行高度，宽度不足时由本行截断承担
                // 徽章行：三枚 fixedSize 徽章恒保理想宽（§7-3），第 4 元素（分位 / 原因）
                // 放不下时整体省略而非压成墨团——原实现它是行内唯一可压缩元素，实测被挤成
                // 「分位」墨团 + 数字竖痕（全部行不可读）。候选内的文本也 fixedSize：
                // 可截断的文本会让 ViewThatFits 的适配判定永远命中候选 1，省略退化失效
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        badgeTray
                        rankOrReason.fixedSize()
                    }
                    HStack(spacing: 6) {
                        badgeTray
                    }
                }
            }
            Spacer(minLength: Theme.Space.xs)
            // 右列权重反转（§4.1-1）：收益率/预赚在上（lead + ok——默认排序依据即扫读主角），
            // 现价降次级（sub + tx）在下；无收益率数据（曲线不足）时现价即本行主数字、占 lead（§1.3 档位跟层级走）
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                if let p = item.profitPerRound, item.rank != nil {
                    // minScale 直接传给每枚 Mono（T3 通道）：容器级 .minimumScaleFactor 不会
                    // 传播到子 Text（实测截断成「-851 -…」），长串必须在 Text 自身随宽缩放
                    Mono("\(p >= 0 ? "+" : "")\(Fmt.price(p)) \(Fmt.pct(item.profitPct))", step: .lead, color: p > 0 ? Theme.ok : Theme.faint, minScale: 0.75)
                    Mono(Fmt.price(item.current), step: .sub, color: Theme.tx, minScale: 0.75)
                } else {
                    Mono(Fmt.price(item.current), step: .lead, minScale: 0.75)
                }
            }
            .lineLimit(1) // 徽标保理想宽后溢压移到价格列：缩放由各 Mono 的 minScale(0.75) 承担（T3）
            // 右列提优先权（§1.1 主数字立权）：HStack 空间谈判对「可截断名称+fixedSize 徽章」的
            // 左列天然让步过度——实测双源异常等宽徽章行右列被压到 0.75 缩放后仍截断（「-292 -…」），
            // 左列徽章行右侧却仍有余量。提权后右列先于左列取足缩放下限以上的宽度，长串整体缩放到
            // 放得下为止（不再截断），名称行承担截断（§7-3）；徽章超宽时绘制进列间空白，
            // 与数字不同层（徽章在下、主数字在上）且现价左缘远于徽章右缘，不重叠
            .layoutPriority(1)
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
                // 弹名允许折两行：卡宽 250 固定，缩略图 + fixedSize 等级徽章挤压后单行可用
                // 仅 ~139pt，长弹名（12.7x55mm PD12双头弹 / .357 Magnum 9号霰射"鼠弹"）
                // 单行截断过半失去识别信息（终验实测「12 Ga…」「12.7x5…」）；两行全名可读，
                // 头行增高 ~2pt（两行 footnote ≈ 32pt ≈ 缩略图 30pt），横滑轨齐高几乎不受影响
                Text(item.name).font(Theme.font(.sm, weight: .bold)).foregroundStyle(Theme.txStrong).lineLimit(2)
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
                // 「预赚 …/发」中英混排：默认 design + 等宽数字（lead=16/body，mono 只留给纯 ASCII）。
                // 符号跟 Fmt 口径：正数补 +、负数的 - 由 Fmt.price 自带（外层硬拼 + 会得到「+-123」）
                Text("预赚 \(item.profitPerRound.map { $0 >= 0 ? "+" : "" } ?? "")\(Fmt.price(item.profitPerRound))/发")
                    .font(Theme.font(.lg, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ok)
                Mono(Fmt.pct(item.profitPct), step: .lead, color: Theme.ok)
            }
            RankBar(item: item)
            if let eta, let med = eta.medianH, eta.episodes >= 2 {
                Text("预计 \(SellEtaEngine.fmtHours(med)) 到价（\(eta.etaLabel ?? "—")，\(eta.episodes) 次样本）")
                    .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
            } else if let eta, let peak = SellEtaEngine.fmtPeak(start: eta.peakStart, end: eta.peakEnd) {
                Text("日内 \(peak) 通常最贵").font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
        // 可点卡片（§4.1-7）：描边换 lineHover 暗示入口；按压 lift 面见 SignalCardPressStyle
        .card(hoverable: true)
        // 合并朗读（§7-1）：与 SellSignalCard / AmmoRow 同款成句转述，替代逐控件拼读
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// 成句转述（语序对齐视觉：三格输入 → 预赚主数字）
    private var a11yLabel: String {
        var parts = [item.name, "买入信号"]
        parts.append("买入不高于 \(Fmt.price(item.current))，挂卖 \(Fmt.price(item.targetSell))，税后到手 \(Fmt.price(item.netSell))")
        if let p = item.profitPerRound {
            parts.append("预赚 \(p >= 0 ? "+" : "")\(Fmt.price(p)) 每发（\(Fmt.pct(item.profitPct))）")
        }
        return parts.joined(separator: "，")
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
                // 与买入卡同款：折两行保全名（卖出 19 张同款卡，长弹名单行截断过半失去识别）
                Text(item.name).font(Theme.font(.sm, weight: .bold)).foregroundStyle(Theme.txStrong).lineLimit(2)
                Spacer()
                GradeBadge(grade: item.grade)
            }
            HStack(spacing: 10) {
                StatCell(label: "现价", value: Fmt.price(item.current))
                StatCell(label: "7天最高", value: Fmt.price(item.weekHigh), color: Theme.danger)
                StatCell(label: "到手", value: Fmt.price(item.netHigh))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // 主数字立权（同买入卡 §4.1-2）：高位分位 lead 档 danger；距最高为辅读数。
                // 「高位 N%」中英混排：与买入卡「预赚 …/发」同配方——默认 design + 等宽数字（lg semibold），
                // 两张上下相邻的信号卡主数字字阶与数字设计一致（mono design 只留给纯 ASCII）
                Text(highRankText)
                    .font(Theme.font(.lg, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.danger)
                if let liftToHigh {
                    // Fmt.pct 正数自带 +、负数自带 -（MarketMeta.swift:95），外层再拼 + 会渲染成「++0.0%」
                    Text("距最高 \(Fmt.pct(liftToHigh))")
                        .font(Theme.font(.md, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                }
            }
            RankBar(item: item)
            if let eta, let peak = SellEtaEngine.fmtPeak(start: eta.peakStart, end: eta.peakEnd) {
                Text("已贴近 7 天高位，日内 \(peak) 通常最贵").font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
            } else {
                Text("已贴近 7 天高位，持仓建议出货").font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
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
        if let liftToHigh { parts.append("距 7 天最高 \(Fmt.pct(liftToHigh))") // Fmt.pct 自带符号，不重复拼 +（与视觉行同口径）
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
            // 正文含 P25/8%/15% 等实义数字：同样走等宽数字，与标题及全页数字节拍一致
            Text(MarketMeta.methodDataLine(source)).font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
            Text("买卖点 = 近 7 天小时曲线分位数回归：现价 ≤ P25 且税后收益率 ≥ 8% 判「买入」、≥ P80 判「卖出」、≤ P35 判「关注」；目标挂卖价取 P75，税率按税后价实测反推（约 15%）。历史分位不代表未来走势，信号仅供参考。")
                .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
        }
    }
}
