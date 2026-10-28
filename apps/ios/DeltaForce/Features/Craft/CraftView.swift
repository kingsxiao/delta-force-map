// CraftView.swift — 特勤处制造利润：工作台 / 防具台 / 技术中心 / 制药台
// 数据：/craft/craft.json（契约 §1.3）；最佳口径 = 价格完整配方中「每小时利润」
// 最大（制造台同一时间只能跑一条，时利才是真实约束）。SSE craft 事件驱动重拉。
// 动效对齐 MOTION.md §4.2：首载骨架（主卡位 + 8 条配方行，替代裸 ProgressView）/
// 配方区四态互切 contentSwap / 行级数字维持瞬时更新（§3-E，原则 3 不做整表滚动）
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
    // 显式导航栈：UI 巡检 -openCraftFirst 需要 programmatically push 详情
    // （NavigationPath 装 CraftItem，与行内 NavigationLink 同轨）
    @State private var path = NavigationPath()

    // 本页局部触觉 tick（刷新成败二分 / 筛选切换；对齐雷达页范式）
    @State private var refreshOkTick = 0
    @State private var refreshErrTick = 0
    @State private var toggleTick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 筛选变化后滚回榜首的锚点 id（§4.3-5）
    private static let topAnchor = "craft-top"

    private var feed: FeedModel<CraftSnapshot> { app.craft }

    /// 数据源错误横幅文案：有快照的后台刷新失败才在此提示，正常态 nil
    /// （首拉失败由配方区 RetryErrorRow 承担，不同屏双份；对齐 AmmoView.bannerMessage）
    private var bannerMessage: String? {
        feed.snapshot != nil ? feed.lastError : nil
    }

    /// 配方区四态：共享 FeedTableState 单一定义（Components.swift，MOTION.md §4.2——一致性评审
    /// 收口：三页逐字重复的私有 TableState 收编，防判据漂移；判据口径注释见共享定义处）；
    /// 也是 .contentSwap 的切换键
    private var tableState: FeedTableState {
        FeedTableState(
            hasSnapshot: feed.snapshot != nil,
            lastError: feed.lastError,
            isEmpty: rows.isEmpty
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                List {
                    Section {
                        // 顶部只要筛选：制造台单选 chips 直选（不用下拉）+ 价格 / 排序两个次级菜单。
                        // 错误横幅同行情 / 雷达口径：有快照的后台刷新失败才在此提示，首拉失败走列表区 RetryErrorRow
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            FeedErrorBanner(message: bannerMessage)
                            placeChipsRow
                            HStack(spacing: Theme.Space.sm) {
                                priceMenu
                                sortMenu
                            }
                        }
                    }
                    .listRowBackground(Theme.card)
                    .id(Self.topAnchor)

                    // 时利最佳（跟随制造台筛选；页面唯一主角数字 §1.1）
                    if let best {
                        Section {
                            // 主卡可点进配方详情（与行内 NavigationLink 同轨，destination 见下）：
                            // 页面唯一主角卡原先没有入口，想看它的材料清单 / 参照区间得去下方
                            // 列表找同名行——主角反而比次级行难到达。按压走共享 PressableButtonStyle
                            // 的 lift 面（§3-D），替换系统灰高亮，与全站可点卡片同一手感
                            NavigationLink(value: best) {
                                CraftBestCard(item: best, placeLabel: placeLabel(of: best.place))
                            }
                            .buttonStyle(PressableButtonStyle())
                            // 换制造台 = 换主角配方：整卡换身份，挡掉 hero 数字跨配方滚动——
                            // 数字滚动（.numericChange）只留给同一配方刷新时的数值变化（§3-E）
                            .id(best.id)
                            .swapTransition() // 首载骨架→内容：淡入 + 6pt 轻上移（§3-H）
                        }
                        .listRowBackground(Theme.card)
                        // 换台 / 静默刷新换最佳时 best.id 变 → 整卡换身份：本事务让 .swapTransition
                        // 真正淡入淡出（原先没有动画驱动，换台瞬现瞬隐）。刻意挂在 Section 局部而非
                        // List 层：挂 List 层会让换台的同一事务给配方行增删带上默认动画，违背
                        // MOTION.md §3-B「大表重排无动画」的既定取舍（重排感知只靠回顶承担）
                        .motion(Theme.animSwap, value: best.id)
                    } else if tableState == .skeleton {
                        // 首载骨架的主卡位（web /craft 首载 variant="hero" 的 iOS 对应，MOTION.md
                        // §4.1 / 原则 4 双端同语义）：结构对齐 CraftBestCard，快照落地随整页事务退场。
                        // 判据对齐四态机而非裸看 snapshot == nil：首拉失败时下方配方区已切
                        // RetryErrorRow，主卡骨架却仍在扫光——「系统工作中」与「加载失败」同屏
                        // 矛盾；错误优先（§4.2），错误态主卡位随之退场，重试成功回到骨架再进内容
                        Section {
                            CraftBestSkeleton()
                                .transition(.opacity) // 骨架只淡出不位移（§4.2，防布局跳动）
                        }
                        .listRowBackground(Theme.card)
                    }

                    // 骨架期间（无快照）Section 头隐藏计数（MOTION.md §4.2）：否则「配方 · 0 项」与 8 条假行同屏矛盾
                    Section(feed.snapshot == nil ? "配方" : "配方 · \(rows.count) 项") {
                        // 四态互切（MOTION.md §4.2，对齐 AmmoView.tableState）：Group 在 List 里是透明
                        // 容器，各态子视图各自成行；.contentSwap 挂一次到分支容器上——.transition 只在
                        // 分支切换且事务带动画时生效，原先错误 / 空态两处 .transition 没有动画驱动，从未真正淡入
                        Group {
                            switch tableState {
                            case .error(let err):
                                // 首拉失败（§4.1-6 / C10）：busy 时禁用重试 + 内联进度，消除空转
                                RetryErrorRow(
                                    message: err,
                                    retry: { Task { await feed.refresh() } },
                                    busy: feed.isLoading
                                )
                                .transition(.opacity) // 错误态淡入淡出（§3-H）
                            case .skeleton:
                                // 首载骨架（MOTION.md §4 P0）：8 条 CraftRow 同构行替代原裸
                                // ProgressView + 文案行；行数固定不随屏幕堆、刷新绝不回骨架、
                                // 扫光 / RM 静态由共享基块内建。不直接用共享 SkeletonList：那是
                                // AmmoRow 同构（无名次槽 / 多 56pt 尾槽），落位跳动违背 §4「结构贴近真实布局」
                                CraftSkeletonRows(rows: 8)
                                    .transition(.opacity) // 骨架只淡出不位移（防布局跳动）
                            case .empty:
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
                                .swapTransition() // 空态进场淡入 + 6pt 轻上移（§3-H 内容分支口径）
                            case .rows:
                                EmptyView()
                            }
                        }
                        .contentSwap(tableState)
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
                // 首载「骨架→内容」整页同步交叉淡化（MOTION.md §4.2，对齐 AmmoView）：主卡骨架 /
                // 配方骨架与真实内容分属不同 Section，只挂配方分支会出现「骨架淡出、主卡硬切」的
                // 半截动画，故 List 层挂统一事务。键只认 snapshot == nil：60s 静默刷新与筛选 /
                // 排序重排不触发（原则 3——行级数字瞬时更新，不整表滚动）
                .contentSwap(feed.snapshot == nil)
                // 后台刷新失败横幅进出场淡入淡出（§3-F 提示条口径）：键只认有无横幅，文案变化
                // 不触发；横幅在首行 VStack 内，带事务后 chips / 菜单随布局平滑让位而非整列跳动
                .motion(Theme.animSwap, value: bannerMessage != nil)
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
                // 排序切换与筛选同口径（行情页 filter/sort 双挂先例 AmmoView.swift:347-348）：
                // 换排序 = 换榜单（缺此行时排序切换既无 selection 触感也不回顶，长列表深处
                // 切「成本」后停在原位，新榜首不可见）
                .onChange(of: sort) { _, _ in scopeChanged(proxy) }
                // UI 巡检钩子（同 RootView -startTab 模式，生产无此参数）：-openCraftFirst
                // 等首个快照落地后 push 首个配方详情、-wfScrollEnd 滚到列表末尾补拍折叠区
                .task { await shotHook(proxy) }
            }
        }
    }

    /// UI 巡检钩子：等首个快照落地（最多 10s，网络快照非即时）再执行；详情 push
    /// 与行内 NavigationLink 同轨（显式 path.append）
    @MainActor
    private func shotHook(_ proxy: ScrollViewProxy) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-openCraftFirst") || args.contains("-wfScrollEnd") else { return }
        for _ in 0..<100 {
            if feed.snapshot != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if args.contains("-openCraftFirst"), let first = rows.first {
            path.append(first)
        }
        if args.contains("-wfScrollEnd") {
            // List 懒加载行首次布局完成前 scrollTo 会落空，数据就绪后再等一拍才滚；
            // 目标取最后一行自己的 id——滚 topAnchor 只能把首 Section 对进首屏，到不了列表末尾
            try? await Task.sleep(for: .milliseconds(800))
            if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    /// 制造台单选 chips：直选直切（比下拉少一跳）；一行放不下时退横向滚动
    /// （ViewThatFits 降级，AX 韧性 §7-6；快照未到时用内置四台兜底，chips 不闪空）
    private static let fallbackPlaces: [CraftPlace] = [
        CraftPlace(id: "workbench", label: "工作台"),
        CraftPlace(id: "armory", label: "防具台"),
        CraftPlace(id: "tech", label: "技术中心"),
        CraftPlace(id: "pharmacy", label: "制药台"),
    ]

    private var places: [CraftPlace] { feed.snapshot?.places ?? Self.fallbackPlaces }

    private struct PlaceChip: Identifiable {
        let scope: PlaceScope
        let label: String
        var id: String { label }
    }

    private var placeChips: [PlaceChip] {
        [PlaceChip(scope: .all, label: "全部")] + places.map { PlaceChip(scope: .place($0.id), label: $0.label) }
    }

    private var placeChipsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { ForEach(placeChips) { placeChip($0) } }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { ForEach(placeChips) { placeChip($0) } }
            }
            .padding(.vertical, 1)
            // 右缘渐隐滚动提示（对齐 TTK 筛选 chips 行先例 TtkView.swift:163-179）：降级分支被
            // ViewThatFits 选中即证明一行放不下，「制药台」在视口右缘被硬切而无任何可滑暗示。
            // 尾端 16pt 白→透明 mask——mask 只取 alpha、与行底色解耦（按底色叠渐变会错色成带），
            // 且不影响命中测试；本分支必然溢出故渐隐恒开，无需 TTK 那套内容宽/视口宽测量。
            // 不走 listRowInsets trailing 归零出血：chips 与错误横幅/菜单同处一个 List row，
            // 行内边距归零会波及整行（TTK 的 chips 是独立 row 才能这么做）
            .mask(
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                }
            )
        }
    }

    private func placeChip(_ c: PlaceChip) -> some View {
        let on = place == c.scope
        return Button {
            guard place != c.scope else { return }
            place = c.scope
        } label: {
            Text(c.label)
                .font(Theme.font(.sm, weight: .semibold))
                .foregroundStyle(on ? Theme.accent : Theme.dim)
                // 内边距对齐同卡紧邻下一行的 FilterChipLabel（Components.swift h13/v8）：两行 chip 同为
                // .sm semibold 字阶、同处一个 VStack，原 14/7 让本行比价格 / 排序 chip 矮 2pt、
                // 左右各宽 1pt——同层级同字号却不同高，叠在一起肉眼可辨；web 两组本就共用同一个
                // .chip 类（CraftView.vue:741）。触控垫层 / 选中态 / 按压面不受影响
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(on ? Theme.accentBg : Theme.card2, in: Capsule())
                // 激活描边走 accentDim 令牌（T4）：FilterChipLabel 收编时已把「accent.opacity(0.45) 裸值」
                // 点名为第三种激活长相（Components.swift 注释），本 chip 与价格 / 排序 chip 同屏上下并置
                // 却是全仓最后一处漏网——0.45 与 0.38 两档描边相邻两行肉眼可辨，同页激活态必须同配方
                .overlay(Capsule().strokeBorder(on ? Theme.accentDim : Theme.line, lineWidth: 1))
                // 触控垫层（HIG 44pt 下限）：chip 视觉仅 ~34pt，垫高命中区到 44——视觉尺寸不变、
                // 只扩大 hit test；命中形状随垫层由胶囊换矩形（垫层上下空白同样可点）
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                // 选中三态（文字 / 底 / 描边）animFast 渐变、无位移（§3-B chip 选中档）：
                // 切台时旧 chip 褪色、新 chip 点亮同步交叉，原先硬切；RM 门内建于 .motion
                .motion(Theme.animFast, value: on)
        }
        // 按压态由系统 .plain 整体变暗换为全站统一 lift 面（MOTION.md §3-D）：共享 PressableButtonStyle
        // 已开放 radius 参数，传 .infinity（RoundedRectangle 钳到宽高一半）即胶囊取形——收编原本地
        // CapsulePressStyle 副本（与 ItemDetailView CalcChip / PlaybookView 时段 chip 同款先例），
        // lift 面 / animFast / RM 门三项配方回归共享层单点维护。
        // 按压光面覆盖 44pt 命中区（=触控垫层）而非仅视觉胶囊——反馈区与命中区一致，按压感知诚实
        .buttonStyle(PressableButtonStyle(radius: .infinity))
        .accessibilityAddTraits(on ? .isSelected : [])
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
            withAnimation(Theme.animMed) { // 档位预设（§2.2，等价原字面值 .easeOut(durMed)）
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
                // 含中文眉题：默认 design（Theme.swift monoFont 注释「仅限纯 ASCII」；全仓唯一把
                // monoFont 套在中文字面量上的位置——与 MethodNote「口径」/ TTK 眉题同口径收编）
                Text("时利最佳")
                    .font(Theme.font(.micro, weight: .bold))
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
                    // 徽标行 ViewThatFits 降级（§4.2-2 / §7-6，对齐 ItemDetailView 头部与本文件 CraftRow）：
                    // 三枚徽标皆 fixedSize 恒保理想宽，而本列与右侧 hero 数字列同行分宽——字阶放大一两档
                    // 徽标行就先于名称溢出、挤进 hero 列。降级顺序：先省「Lv.N」（详情页仍有）再省台名
                    // （筛「全部」时它是「最佳出自哪台」的唯一标识，故晚于 Lv 退场），等级徽标恒留
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            CategoryChip(text: placeLabel)
                            GradeBadge(grade: item.output.grade)
                            if let lv = item.requiredLevel {
                                StatusChip(text: "Lv.\(lv)", tint: Theme.dim)
                            }
                        }
                        HStack(spacing: 6) {
                            CategoryChip(text: placeLabel)
                            GradeBadge(grade: item.output.grade)
                        }
                        GradeBadge(grade: item.output.grade)
                    }
                }
                Spacer(minLength: Theme.Space.sm)
                // 主角数字：时利（hero 档 + 语义色，§1.3 同层级同档）；数字滚动（§3-E 单点
                // 关键数字，SSE 快照替换后自动跟随；跨配方切换由调用处 .id(best.id) 换身份挡掉）。
                // 列内垂直间距 Space.xs（T8 收编字面量 2；ItemDetailView 头部 hero 列同位同值，
                // 骨架 CraftBestSkeleton 同槽早已是 xs——真实卡反而与自己的骨架不同构）
                VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                    Mono(hourlyText, step: .hero, color: profitColor, minScale: 0.7)
                        .numericChange(value: item.profitPerHour)
                    Text("每小时")
                        .font(Theme.font(.micro))
                        .foregroundStyle(Theme.faint)
                }
            }

            StatQuadRow(
                // 标签对齐 web hero-stats「单次净利润」与详情拆解「净利润」：同一数字此前在卡片 / 拆解 /
                // web 端三个名字（单次利润 / 净利润 / 单次净利润），点卡进详情后同值换名有对不上账的观感；
                // 「净」字点明已扣手续费口径，与右邻「材料成本」并置时语义闭环
                StatCell(label: "单次净利润", value: Fmt.price(item.profit), color: profitColor, emphasis: .hero),
                // 输入类数据（成本 / 耗时）降 dim 让位主角（§1.1），与详情页利润拆解同格同色——
                // 原先两格 txStrong 与 hero 利润近似平权，主数字立权被稀释
                StatCell(label: "材料成本", value: Fmt.price(item.cost), color: Theme.dim),
                StatCell(label: "制造耗时", value: item.periodLabel ?? "—", color: Theme.dim),
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
        // 占位「—」faint 而非 dim：与「成本回报」格真实数值的 ok/danger 拉开，
        // 「没数据」不冒充分级数据（全站缺价口径，详见 CraftDetailView 参照区）
        return Theme.faint
    }
    private var profitColor: Color {
        if let p = item.profit { return p >= 0 ? Theme.ok : Theme.danger }
        return Theme.dim
    }
    private var bestA11y: String {
        var parts = ["时利最佳", placeLabel, item.output.name]
        if let p = item.profitPerHour { parts.append("每小时利润 \(Fmt.price(p))") }
        if let profit = item.profit { parts.append("单次净利润 \(Fmt.price(profit))") }
        // 四格里成本 / 耗时 / 回报三格此前不进朗读：整卡 .combine 后只读显式 label，可见信息对
        // VoiceOver 缺席（§7-1 成句纪律；CraftRow.a11yLabel 已转述耗时，主卡反而少读）。语序对齐视觉：
        // 四格自左向右
        if let cost = item.cost { parts.append("材料成本 \(Fmt.price(cost))") }
        if let period = item.periodLabel { parts.append("制造耗时 \(period)") }
        if item.roi != nil { parts.append("成本回报 \(roiText)") }
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
        // 行级数字（时利 / 单次利润）不做滚动：列表多行 60s 静默刷新 + 排序 / 筛选重排，
        // 整表滚动 = 噪声（MOTION.md §3-E / 原则 3）——瞬时更新；滚动语义只留给主卡与详情页的单点 hero
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            // 缺价配方的服务端字段是 0 而非 null（契约 §1.3 降级展示）：
            // 一律以 hasEstimate 为显示门槛，「+0」绿色时利是估算可用的假象
            if item.hasEstimate, let p = item.profitPerHour {
                Mono(p >= 0 ? "+\(Fmt.price(p))" : Fmt.price(p), step: .lead, color: p >= 0 ? Theme.ok : Theme.danger, minScale: 0.75)
            } else {
                // 缺价占位「—」= faint + 常规字重（web .na 同口径，CraftView.vue「不覆盖会出现一枚
                // 加粗的『—』」）：lead 档默认 semibold 会把占位符画成一道粗杠，与真实数字同重——
                // 「没数据」不该和「有数据」一样有分量；色（faint）与重（regular）两层一起降
                Mono("—", step: .lead, weight: .regular, color: Theme.faint)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Text("利润").font(Theme.font(.micro)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: true, vertical: false)
                // 缺价占位「—」faint + regular 与次级数值 dim + semibold 分色分重：同色同重时
                // 「没数据」会被读成一条次级数据（与同列主数字「—」、web 端 .na 口径一致）
                if item.hasEstimate {
                    Mono(Fmt.price(item.profit), step: .sub, color: Theme.dim)
                } else {
                    Mono("—", step: .sub, weight: .regular, color: Theme.faint)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var a11yLabel: String {
        var parts = ["第 \(rank) 名", placeLabel, item.output.name]
        if !item.isComplete { parts.append("价格缺失") }
        if item.hasEstimate {
            if let p = item.profitPerHour { parts.append("每小时利润 \(Fmt.price(p))") }
            if let profit = item.profit { parts.append("单次利润 \(Fmt.price(profit))") }
        }
        if let period = item.periodLabel { parts.append("耗时 \(period)") }
        return parts.joined(separator: "，")
    }
}

// MARK: - 首载骨架（MOTION.md §4；共享基块 SkeletonBlock / SkeletonLine 直接复用，
// 行结构为 CraftRow / CraftBestCard 专属同构——见下方各类型注释）

/// 骨架行集合（对齐共享 SkeletonList 的 Group 容器形态）：Group 在 List 里是透明容器，
/// 每条 CraftSkeletonRow 各自成行；行数固定 8（§4.2 共性红线，不随屏幕无限堆）
private struct CraftSkeletonRows: View {
    var rows: Int = 8

    var body: some View {
        Group {
            ForEach(0..<max(0, rows), id: \.self) { _ in
                CraftSkeletonRow()
            }
        }
    }
}

/// 制造页骨架行（对齐 CraftRow 结构：名次槽 / 36 缩略图位 / 名称+徽标条 / 右列 lead+sub
/// 数字条）。不直接用共享 SkeletonRow——那是 AmmoRow 同构（无名次槽、拇指位差 4pt、多
/// 56pt 分位条尾槽），骨架→内容落位会整体错位，违背 §4「结构贴近真实布局」；待共享层
/// 把行结构参数化后收编（见 sharedRequests）。无分隔线（骨架纪律：低对比、安静）；
/// 行底与行内边距**不覆写**——继承配方 Section 的 Theme.card 与默认 insets，与真实行同壳。
private struct CraftSkeletonRow: View {
    var body: some View {
        HStack(spacing: 10) {
            SkeletonLine(width: 20, height: 12) // 名次「01」（sub 档）
                .frame(minWidth: 30, alignment: .leading) // 对齐 CraftRow.rankMinWidth 槽位
            SkeletonBlock(width: 36, height: 36) // ItemThumb 36
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                SkeletonLine(width: 100, height: 14) // 产物名（md 档行高位）
                SkeletonLine(width: 72, height: 10) // 台名 + 等级徽标行（micro 档）
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                SkeletonLine(width: 72, height: 14) // 时利（lead 档行高位）
                SkeletonLine(width: 56, height: 11) // 「利润 N」（sub 档）
            }
        }
        // 近似预留 NavigationLink 尾缘 chevron 位，让右列数字条与真实行落位一致
        // （骨架纪律：结构预告；具体值按 insetGrouped 行 chevron 区估取）
        .padding(.trailing, 26)
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
        .accessibilityHidden(true) // 纯装饰占位整行隐藏，加载语义由页面状态承担
    }
}

/// 时利最佳主卡的骨架位（对齐 web /craft 首载 variant="hero"，MOTION.md §4.1 / 原则 4
/// 双端同语义；iOS §4.2 表未列，按「结构贴近真实布局」本地补齐）：眉标条 / 44 缩略图位 +
/// 名称与徽标条 / 右列 hero 数字条 / 四格统计行，与 CraftBestCard 同间距同层级。
private struct CraftBestSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            SkeletonLine(width: 56, height: 10) // 「时利最佳」眉标（micro 档）
            HStack(spacing: Theme.Space.md) {
                SkeletonBlock(width: 44, height: 44) // ItemThumb 44
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    SkeletonLine(width: 120, height: 15) // 产物名（md 档行高位）
                    SkeletonLine(width: 92, height: 12) // 台名 + 等级 + Lv 徽标行
                }
                Spacer(minLength: Theme.Space.sm)
                VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                    SkeletonLine(width: 96, height: 20) // 时利 hero（22pt 档）
                    SkeletonLine(width: 32, height: 10) // 「每小时」（micro 档）
                }
            }
            HStack(spacing: 10) {
                // StatQuadRow 四格位：label + 值两条，等宽铺满（对齐真实四格布局）
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 4) {
                        SkeletonLine(width: 40, height: 10)
                        SkeletonLine(width: 56, height: 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityHidden(true) // 纯装饰占位整块隐藏
    }
}

// 制造台 chip 的按压态已收编为共享 PressableButtonStyle(radius: .infinity)（Components.swift，
// MOTION.md §3-D）：行为逐项等价（lift 面 + animFast 档 + RM 置 nil 但色面态仍生效），
// 本页不再保留私有 CapsulePressStyle 副本（与 AmmoView 信号卡 / ItemDetailView CalcChip 同一收口）
