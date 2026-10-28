// AmmoView.swift — 子弹行情：买入 / 卖出信号卡 + 全表（筛选 / 排序 / 搜索 / 自选置顶）
// 精修对齐 DESIGN.md §4.1：列表行权重反转 / 信号卡主数字立权 / 刷新二分触感 /
// 筛选排序回顶 / RetryErrorRow 防空转 / 可点卡片按压态
// 动效对齐 MOTION.md §4.2：首载骨架（替代裸 ProgressView）/ 全表区四态互切 contentSwap /
// 横幅与星标进出场；60s 静默刷新与筛选重排刻意不加动画（原则 3）
// 第 1 轮前沿落地：信号卡吸附轮播 + 近缘渐隐 / 手册半屏 sheet / 回顶浮动钮（TopAwayProbe 探测）/
// 星标触感语义分层降档
// 第 2 轮手感深化：全表头数据年龄回声（对齐雷达页 freshness）/ 空态按成因分文案与出路 /
// 囤货移出补位动画 / 囤货行防截断配方与缩略图槽位对齐 AmmoRow
// 第 3 轮一致性与口径：口径页脚对齐信号 v2 定稿 / 买入卡按收益率降序（与 web、服务端同序）/
// 无买点提示态（对齐 web .no-buy-tip）/ 搜索词回顶补齐筛选闭环 / 行内间距收编 Space.sm 对齐雷达 TTK 行
// 第 4 轮终审：囤货行首载不误报「不在当前行情」（marketReady）/ 买入区出货窗提示（对齐 web .buy-clock-tip）/
// 信号卡 a11y 转述补齐主数字、分位与 ETA（§7-1）
import DeltaForceCore
import SwiftUI

struct AmmoView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", buy = "买入", sell = "卖出", watch = "关注", favorites = "自选"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case profit = "收益率", rank = "分位（低→高）", price = "现价", grade = "等级", name = "名称", dayTradeEta = "日抛耗时"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: Filter = .all
    @State private var sort: Sort = .profit
    @State private var query = ""
    // 日抛 toggle（对齐 web 全表控制条 toggle chip，AmmoMarketView.vue 同名开关）：
    // 与信号筛选正交的约束维度——现价买入 ≤24h 能涨到税后净利 ≥5% 卖价的弹
    // （口径单一源 SellEtaEngine.isDayTrade，见 DeltaForceCore SellEta.swift 日抛块）
    @State private var dayTradeOnly = false
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
    @State private var showBackTop = false // 回顶浮动钮显隐（离顶探测见共享 ListTopAwayProbe，长表专用）

    /// 筛选/排序切换后滚回榜首的锚点 id（§4.1-4，对齐 TTK topAnchor 方案）
    private static let topAnchor = "ammo-top"

    /// 回顶钮探测用的列表命名坐标系（挂在 List 上 = 列表可视口，ListTopAwayProbe 的 frame 参照）
    private static let listSpace = "ammo-list"

    /// 买入信号卡数据源（卖出简表同源过滤）：从 body 局部 let 提为计算属性，
    /// 供 Section 渲染与 anchorHost 宿主判定共用同一份数据，避免两处口径漂移。
    /// 按收益率降序：对齐 web 端 buyList（AmmoMarketView.vue:614）与服务端 signals.buy
    /// （analyze.mjs analyzeMarket 同键降序）——此前沿用 items 目录原序，横滑轨首卡并非最优买点，
    /// 与「第一眼看到决策最关键的数字」的扫读路径相悖；缺收益率沉底（-inf 哨兵，同 rows 的 profit 排序）
    private var buys: [MarketItem] {
        app.market.items
            .filter { $0.signal == .buy }
            .sorted { ($0.profitPct ?? -.infinity) > ($1.profitPct ?? -.infinity) }
    }

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

    /// 「买入信号」区块的无买点提示态：有快照、有条目、但当前零买入信号。
    /// 为什么要有这一态：v2 严选口径下（analyze.mjs 头注：21 天回测仅 14 笔）零买点是行情常态而非异常，
    /// 区块整体消失会让用户分不清「今天没买点」与「功能没了」——web 端同位有 .no-buy-tip 常驻文案
    /// （AmmoMarketView.vue:891）。快照无条目由全表区「暂无行情数据」空态承担，不在此重复
    /// （buys 由调用方传入：body 单次求值收编口径，见 body 内注释）
    private func showNoBuyHint(_ buys: [MarketItem]) -> Bool {
        app.market.snapshot != nil && !app.market.items.isEmpty && buys.isEmpty
    }

    /// 市场时钟「出货窗」判读（买入区提示行的开关，对齐 web .buy-clock-tip：
    /// AmmoMarketView.vue:939 的 clockVerdict === 'sell'）：全市场处日内相对高位时，
    /// 买入卡上方提示「追高易买在时段顶部、可等低位窗再进场」。为什么要补：
    /// 买入信号只含 7 天分位 + 企稳门槛、不含日内节律（web 端注释同口径：展示层提示、
    /// 不改 analyze 信号），这句是决策点的最后一块拼图；iOS 的完整节律卡此前只在
    /// 倒卖手册 sheet 内（PlaybookView MarketClockCard），行情页决策点无提醒。
    /// marketClock 是 Core 纯函数（手册页同源对拍），样本不足返回 nil 即静默不提示
    private var clockAtSell: Bool {
        SellEtaEngine.marketClock(app.market.items)?.verdict == .sell
    }

    /// 出货窗提示行（买入卡上方）：warn 色左边条 + dim xs 正文——web .buy-clock-tip
    /// 的 border-left 2px warn 80% + padding-left 10 的 iOS 对应物；文案与 web 逐字一致
    /// （双端同口径，第 3 轮 METHOD 对齐同一理由），仅尾缀多一句手册指引（web 的节律卡
    /// 就在同页下方、iOS 要进 sheet 才能看到，指引补上这条断链）。分隔线隐藏：
    /// 卡片行是透明底，提示卡与其间的系统分隔线会悬在 bg 上像一根杂线
    private var clockTip: some View {
        Text("市场时钟判读：当前处日内高位窗，追高扫货易买在时段顶部——不急可等低位窗（通常 02:00–05:00）再进场。完整 24 小时节律见右上「倒卖手册」。")
            .font(Theme.font(.xs))
            .monospacedDigit()
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.card)
    }

    /// 日抛开启中的口径提示行（对齐 web .dt-tip，AmmoMarketView.vue 同文案族）：
    /// 门槛一句话 + 「建议叠加关注 / 买入」的组合指引。历史统计不代表未来——
    /// 展示层必须带这句（sellEta.swift 头注约定）
    private var dayTradeTip: some View {
        Text("日抛口径：现价买入 ≤24 小时能涨到税后净利 ≥5% 的卖价（近 7 天上涨段中位，样本 ≥2），建议叠加「关注 / 买入」信号使用。历史统计不代表未来。")
            .font(Theme.font(.xs))
            .monospacedDigit()
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.card)
    }

    /// 全表区四态：共享 FeedTableState 单一定义（Components.swift，MOTION.md §4.2——一致性评审
    /// 收口：三页逐字重复的私有 TableState 收编，防判据漂移；判据口径注释见共享定义处）；
    /// 也是 .contentSwap 的切换键（rows 由调用方传入：body 单次求值收编口径）
    private func tableState(_ rows: [MarketItem]) -> FeedTableState {
        FeedTableState(
            hasSnapshot: app.market.snapshot != nil,
            lastError: app.market.lastError,
            isEmpty: rows.isEmpty
        )
    }

    /// 回顶锚点宿主：锚点行必须常驻且永远在列表最顶部（§4.1-4 scrollTo 落点 = 真顶）。
    /// banner 态随 banner Section；正常态随「首个真实渲染的 Section」首行
    /// （囤货 > 买入信号 > 卖出信号 > 全表）——省去原先独占一节的空 banner 行
    private enum AnchorHost { case banner, positions, buys, sells, table }

    private func anchorHost(_ buys: [MarketItem]) -> AnchorHost {
        if bannerMessage != nil { return .banner }
        if !app.positions.positions.isEmpty { return .positions }
        if filter == .all, query.isEmpty {
            // 买入区块两态恒在（有卡 / 无买点提示行），任一态渲染即为宿主
            if !buys.isEmpty || showNoBuyHint(buys) { return .buys }
            if !sells.isEmpty { return .sells }
        }
        return .table
    }

    /// 筛选回顶锚点：零高度隐形行（同一时刻仅 anchorHost 命中的一处渲染，id 不冲突），
    /// 保证 scrollTo(ammo-top) 永远有目标；背景挂离顶探测（回顶浮动钮的数据源，见共享 ListTopAwayProbe）
    private var topAnchorRow: some View {
        Color.clear
            .frame(height: 0)
            .background(ListTopAwayProbe(space: Self.listSpace, away: $showBackTop))
            .accessibilityHidden(true)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .id(Self.topAnchor)
    }

    /// 信号卡入口（§4.1-7）：可点卡片按压态——lift 按压面由共享 PressableButtonStyle 承担
    /// （MOTION.md §3-D，animFast 档、RM 置 nil 但色面态仍生效）、lineHover 描边由 SignalCard 的
    /// card(hoverable:) 常驻给出；拆独立函数避免链式修饰符撑爆 ForEach 闭包的 type-checker
    private func signalCardLink(_ item: MarketItem) -> some View {
        // RM 值先取出来再进闭包：scrollTransition 的 transition 闭包标 @Sendable，
        // 直接捕获 self（View 结构体非 Sendable）会被 Swift 6 严格并发拒掉
        let rm = reduceMotion
        return NavigationLink(value: item) {
            SignalCard(item: item)
        }
        .buttonStyle(PressableButtonStyle())
        // 近缘渐隐（思路库「卡片边缘渐隐」，iOS 17）：横滑轨两端未完全入框的信号卡降透明度，
        // 与 scrollClipDisabled 出血共同构成「轨道还有内容、可横滑」的暗示；只动 opacity（§6-1）。
        // RM 返回原样（identity）——渐隐属装饰性滚动反馈，关动效时完整不透明呈现
        .scrollTransition(.animated(Theme.animMed)) { effect, phase in
            effect.opacity(rm || phase.isIdentity ? 1 : 0.45)
        }
    }

    /// 卖出信号卡同款入口（拆独立函数同 signalCardLink：避免链式修饰符撑爆 type-checker）
    private func sellCardLink(_ item: MarketItem) -> some View {
        let rm = reduceMotion // 同 signalCardLink：@Sendable 闭包外先取值
        return NavigationLink(value: item) {
            SellSignalCard(item: item)
        }
        .buttonStyle(PressableButtonStyle())
        .scrollTransition(.animated(Theme.animMed)) { effect, phase in
            effect.opacity(rm || phase.isIdentity ? 1 : 0.45)
        }
    }

    var body: some View {
        // buys / rows 单次求值收编：两者是无缓存计算属性，此前一次 body 求值内被
        // anchorHost / Section 条件 / ForEach / 表头计数各自重算一遍 filter+sort；
        // body 顶部各取一次局部值向下传，纯收编不改行为
        let buys = self.buys
        let rows = self.rows
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
                            if anchorHost(buys) == .banner { topAnchorRow }
                        }
                        .listRowBackground(Theme.card)
                    }

                    // 我的囤货（纯本地台账，有持仓才显示）：页头总览之下、买入信号之上，
                    // 不新增筛选档位；浮盈 / 到价状态随行情快照实时 join，左滑移出
                    if !app.positions.positions.isEmpty {
                        Section("我的囤货 · \(app.positions.positions.count)") {
                            if anchorHost(buys) == .positions { topAnchorRow }
                            ForEach(app.positions.positions) { pos in
                                positionRow(pos)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            // 移出带补位动画（MOTION.md §3-B「小列表增删重排（囤货台账 ≤20 行）」口径，
                                            // web 端台账 .flip 过渡的 iOS 对应物）：哪一行走了、下方如何补位一眼可辨，
                                            // 最后一条移出时整节随之收起而非硬消失。原则 3 的「不加动画」针对 60s 静默
                                            // 刷新与大表重排，本地台账的显式删除是因果反馈，正是该动的一类（原则 1）；
                                            // RM 下 withAnimation(nil) 瞬时（§7-9），触感保留
                                            withAnimation(reduceMotion ? nil : Theme.animMed) {
                                                app.positions.remove(pos.name)
                                            }
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
                                if anchorHost(buys) == .buys { topAnchorRow }
                                // 出货窗提示（web .buy-clock-tip 对齐，见 clockTip 注释）：
                                // 放卡片轨上方。插拔刻意不加动画（原则 3）——判读翻转与新快照
                                // 同帧到达，List 层动画事务会把全表行重排一并动起来（banner 的
                                // motion 无此耦合：失败时数据不变）；web 同位 v-if 也无过渡，双端同口径
                                if clockAtSell { clockTip }
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(buys) { item in
                                            signalCardLink(item)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                    // 吸附轮播（思路库「信号卡吸附轮播」，iOS 17）：HStack 标记为
                                    // 吸附目标布局、配合下方 viewAligned——长轨道松手逐卡停驻，
                                    // 不再停在两卡接缝；卡宽恒 250，对齐边即卡缘
                                    .scrollTargetLayout()
                                }
                                // §4.1-8：卡片滚出行缘不裁剪（视觉出血暗示可横滑）。
                                // 注意：DESIGN 命名的 .scrollClipPadding 在任何已发布 SwiftUI 中都不存在
                                // （已在 iPhoneSimulator27.1 SDK 的 SwiftUI.swiftinterface 验证：0 命中），
                                // 出血意图改用 iOS 16 的 scrollClipDisabled() 实现（P2 非必须项的降级落地）
                                .scrollClipDisabled()
                                // 与 scrollTargetLayout 配对生效（iOS 17）
                                .scrollTargetBehavior(.viewAligned)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            }
                            .listRowBackground(Color.clear)
                        } else if showNoBuyHint(buys) {
                            // 无买点提示态（对齐 web .no-buy-tip，AmmoMarketView.vue:891）：节头同构「名 · 数」
                            // 恒在、内容换一行成因文案并给出路（低位「关注」见全表）。门槛数字取服务端真值
                            // （analyze.mjs RULES.BUY_MIN_NET_PCT 0.10）；字阶与口径页脚正文同档（xs dim +
                            // 等宽数字）——它是「无内容」的说明而非数据行，不该比行情行更重
                            Section("买入信号 · 0") {
                                if anchorHost(buys) == .buys { topAnchorRow }
                                Text("当前没有触发买入条件的弹种（7 天低位企稳 + 税后收益率 ≥ 10%），低位「关注」中的弹种见下方全表。")
                                    .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
                            }
                            .listRowBackground(Theme.card)
                        }

                        // 卖出信号（与网页端「卖出高位简表」对齐）：按分位降序（越贴近 7 天
                        // 高位越靠前）；买入区块之下、全表之上，同款横滑卡与出血口径
                        if !sells.isEmpty {
                            Section("卖出信号 · \(sells.count)") {
                                if anchorHost(buys) == .sells { topAnchorRow }
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(sells) { item in
                                            sellCardLink(item)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                    // 吸附轮播：与买入信号轨同款（viewAligned + scrollTargetLayout 成对）
                                    .scrollTargetLayout()
                                }
                                .scrollClipDisabled()
                                .scrollTargetBehavior(.viewAligned)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            }
                            .listRowBackground(Color.clear)
                        }
                    }

                    // Section 头见 tableHeader：筛选 · 计数（骨架期间隐藏计数，MOTION.md §4.2）+ 右缀数据年龄（§1.5）
                    Section {
                        if anchorHost(buys) == .table { topAnchorRow }
                        // 日抛开启中的口径提示行（web .dt-tip 对应物；clockTip 同款配方）：
                        // 吸顶控制条没有 iOS 对应物，菜单开关是隐藏式的——开启后在全表头部
                        // 常驻一句口径，让「这批行为什么在」不必猜；空态由 emptyState 承担不重复
                        if dayTradeOnly, case .rows = tableState(rows) {
                            dayTradeTip
                        }
                        // 四态互切（MOTION.md §4.2）：Group 在 List 里是透明容器，各态子视图各自成行；
                        // .contentSwap 挂一次到分支容器上——.transition 只在分支切换且事务带动画时生效，
                        // 原先错误 / 空态两处 .transition 没有任何 .animation 驱动，从未真正淡入
                        Group {
                            switch tableState(rows) {
                            case .error(let err):
                                // 首拉失败：换共享 RetryErrorRow（§4.1-6 / C10）——busy 时禁用重试 + 内联进度，消除空转
                                RetryErrorRow(
                                    message: err,
                                    retry: { Task { await app.market.refresh() } },
                                    busy: app.market.isLoading
                                )
                                .transition(.opacity) // 错误态淡入淡出（§3-H）
                            case .skeleton:
                                // 首载骨架（MOTION.md §4 P0）：信号卡位一行 + 8 条 AmmoRow 同构行，替代原裸
                                // ProgressView + 「正在拉取行情…」；行数固定不随屏幕堆，扫光 / RM 静态由共享层内建
                                SkeletonList(rows: 8, cards: true)
                                    .transition(.opacity) // 骨架只淡出不位移（防布局跳动）
                            case .empty:
                                // 筛选 / 搜索空态：按成因分文案与出路（见 emptyState）
                                emptyState
                                    .swapTransition() // 空态进场淡入 + 6pt 轻上移、离场只淡出（§3-H 内容分支口径）
                            case .rows:
                                EmptyView()
                            }
                        }
                        .contentSwap(tableState(rows))
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
                    } header: {
                        tableHeader(rows)
                    }
                    .listRowBackground(Theme.card)

                    Section {
                        MethodNote(source: app.market.snapshot?.source, rules: app.market.snapshot?.rules)
                    }
                    .listRowBackground(Theme.card)
                }
                .themedList()
                .listStyle(.insetGrouped)
                // 首载「骨架→内容」整页同步交叉淡化（MOTION.md §4.2）：信号卡区 / 全表行 / 口径页脚与骨架
                // 分属不同 Section，只挂在全表分支上会出现「骨架淡出、卡片硬切」的半截动画，故 List 层再挂一次
                // 统一事务。键只认 snapshot == nil：有数据后的 60s 静默刷新与筛选重排不触发（原则 3）
                .contentSwap(app.market.snapshot == nil)
                // 后台刷新失败横幅进出场淡入淡出（§3-F 提示条口径的 iOS 对应物）：键只认有无横幅，文案变化不触发；
                // 横幅 Section 在列表顶部，带动画时下方内容随之平滑让位而非整列跳动
                .motion(Theme.animSwap, value: bannerMessage != nil)
                // 回顶浮动钮（思路库「回顶浮动钮」）：命名坐标系给 ListTopAwayProbe 当参照（列表可视口）；
                // 钮本体收口共享 BackTopButton（Components.swift），行为逐字不变
                .coordinateSpace(name: Self.listSpace)
                .overlay(alignment: .bottomTrailing) { BackTopButton(proxy: proxy, anchor: Self.topAnchor, visible: showBackTop) }
                // 钮进出场 animFast 档——web 端 BackTop .totop 的 iOS 对应物（MOTION.md §3-A「返回顶部」）；RM 置 nil 瞬时
                .motion(Theme.animFast, value: showBackTop)
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
                // 自选是轻交互而非任务成败：按触感语义分层收紧（success/error 只给任务结果，
                // 刷新成败已各占 success/error），星标降档 impact(.light)——确认感保留、成败暗示不再滥用
                .sensoryFeedback(.impact(weight: .light), trigger: favTick)
                .sensoryFeedback(.selection, trigger: posTick)
                .sensoryFeedback(.success, trigger: refreshOkTick)
                .sensoryFeedback(.error, trigger: refreshErrTick)
                .sensoryFeedback(.selection, trigger: menuTick)
                .sensoryFeedback(.selection, trigger: sheetTick)
                .onChange(of: filter) { _, _ in filterChanged(proxy) }
                .onChange(of: sort) { _, _ in filterChanged(proxy) }
                // 日抛是第三个筛选维度：开关=换榜单，同款触感与回顶（§4.1-4 闭环一致）
                .onChange(of: dayTradeOnly) { _, _ in filterChanged(proxy) }
                // 搜索词是第三个筛选维度，同样「换词 = 换榜单」回顶（§4.1-4 闭环补齐）：此前列表停在深处时
                // 输入首字符，匹配行数骤减、滚动位越界被系统弹到内容末尾——用户看到的是口径页脚而非匹配行；
                // 深链 pendingQuery 写入搜索词（下方 onChange）同受益。不走 filterChanged：键盘逐键已有
                // 系统触感，再补 selection 即双响，这里只回顶（复用共享 scrollToTop：animMed / RM 直达同口径）
                .onChange(of: query) { _, _ in scrollToTop(proxy, anchor: Self.topAnchor, reduceMotion: reduceMotion) }
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
                                Label("日抛耗时", systemImage: "clock").tag(Sort.dayTradeEta)
                            }
                            Divider()
                            // 日抛 toggle：菜单内的开关项（选中打勾），与信号筛选正交——
                            // web 端同为 toggle chip 而非单选档，双端语义一致
                            Toggle(isOn: $dayTradeOnly) {
                                Label("日抛（24 小时内一买一卖）", systemImage: "clock.arrow.circlepath")
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
                .sheet(isPresented: $showPlaybook) {
                    // 半屏手册（思路库「手册半屏 sheet」）：medium/large 双档 + 拖动指示——
                    // 手册是对照阅读物（时段窗口 vs 实时行情），半屏时列表保持可见边看边对；
                    // detents 配方与 TTK 穿透矩阵 sheet（TtkView.swift:116）同款，双页一致
                    PlaybookView()
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
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
    /// 滚动收口共享 scrollToTop 帮助函数（Components.swift，animMed / RM 直达同口径）
    private func filterChanged(_ proxy: ScrollViewProxy) {
        menuTick += 1
        scrollToTop(proxy, anchor: Self.topAnchor, reduceMotion: reduceMotion)
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

    private var menuActive: Bool { filter != .all || sort != .profit || dayTradeOnly }

    /// 全表区 Section 头（§1.5 闭环反馈的行情页对应物）：左「筛选 · 计数」文案与此前完全一致
    /// （骨架期间无快照退化为中性词「行情」，否则「全部 · 0 种」与 8 条假行同屏矛盾，MOTION.md §4.2），
    /// 右缀数据年龄 freshness。为什么要加：雷达页早有同款年龄行（RadarView.freshness），行情页此前
    /// 下拉刷新成功而价格全无变化时页面零可见变化、只剩 .success 触感——年龄文案即时归零让「刷过了」
    /// 肉眼可见，两页信息面也对齐。放 Section 头而非独占一节：第 1 轮已实测顶部空节带来 ~92pt 死空间
    /// （见 body 内 banner 注释），头部右侧是零额外高度的空位。ViewThatFits 两档：同行放不下
    /// （AX 特大字号 / 「可能过期」长文案）时年龄换行右对齐，计数永不被挤截（§7-6）
    @ViewBuilder
    private func tableHeader(_ rows: [MarketItem]) -> some View {
        let title = app.market.snapshot == nil
            ? "行情"
            : "\(filter.rawValue)\(dayTradeOnly ? " · 日抛" : "") · \(rows.count) 种"
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.sm) {
                Text(title)
                Spacer(minLength: Theme.Space.xs)
                freshness
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                freshness.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// 数据年龄（配方对齐雷达页 freshness）：两个刷新驱动互补——lastRefreshAt 前进时 body 重算
    /// （@Observable 追踪）年龄即时归零；数据不变时 TimelineView 每 30s 给新「现在」让年龄续走字。
    /// 文案走 Core 共享 MarketMeta.fmtAge（与详情页「数据 N 分钟前」同一格式化器，不另造私有副本；
    /// <60s 读「刚刚更新」——刷新回声的关键一帧）。超保鲜阈值转 warn 并读出「可能过期」（色觉之外的
    /// 第二通道），阈值复用 FeedModel.isStale 的数据源口径：年龄看客户端拉取时间、过期看服务端 fetchedAt，
    /// 「刚刚更新 · 数据可能过期」= 刚拉过但上游未更新，两条信息各自为真
    private var freshness: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            if let refreshedAt = app.market.lastRefreshAt {
                let seconds = ctx.date.timeIntervalSince(refreshedAt)
                let text = seconds < 60 ? "刚刚更新" : "\(MarketMeta.fmtAge(minutes: seconds / 60))前更新"
                let stale = app.market.isStale(now: ctx.date)
                Text(stale ? "\(text) · 数据可能过期" : text)
                    .font(Theme.font(.micro))
                    .monospacedDigit()
                    .foregroundStyle(stale ? Theme.warn : Theme.faint)
                    .lineLimit(1)
            }
        }
    }

    /// 空态按成因分文案与出路（对齐 TTK 空态 §4.4-1「按成因分文案，不让用户逐个猜」）。
    /// 原先一句「没有符合条件的弹药 / 换个筛选或清空搜索再试」+「清除筛选与搜索」把三种成因混为一谈，
    /// 且唯一出路一键全清——在「买入」里搜不到、想只清词保留筛选都做不到。成因按条件由窄到宽判定：
    /// ① 搜索无命中（最窄条件，先解它；筛选非默认时附带「同时清筛选」第二出路）
    /// ② 自选为空：教「向右滑动点亮星标」——swipe 手势没有任何可见入口，DESIGN §8-4 不引 TipKit，
    ///    空态是唯一自然的教学位；已有自选但不在本次快照（下架 / 改名）单独陈述，不误导成「没自选过」
    /// ③ 某信号当前无：这是行情事实而非操作失误，如实陈述并指向下拉刷新
    /// ③b 日抛筛空（dayTradeOnly 开启且筛完为空）：同为行情事实，出路是「关闭日抛」
    /// ④ 全部为空（快照无条目）兜底。「查看全部」只改 filter，触感与回顶由 onChange(of: filter) 统一承担
    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView {
                Label("没有匹配「\(query)」的弹药", systemImage: "magnifyingglass")
            } description: {
                Text(filter == .all ? "换个关键词再试" : "正在「\(filter.rawValue)」范围内搜索，可只清词保留筛选")
            } actions: {
                Button("清空搜索") {
                    query = ""
                    menuTick += 1 // 清词不经 onChange(of: filter)，这里补 .selection 触感（与换筛选同档回声）
                }
                if filter != .all {
                    Button("清除筛选与搜索") {
                        filter = .all
                        query = ""
                    }
                }
            }
        } else if filter == .favorites {
            let none = app.favorites.names.isEmpty
            ContentUnavailableView {
                Label(none ? "还没有自选弹药" : "自选弹药不在当前行情", systemImage: "star")
            } description: {
                Text(none
                    ? "在行情列表任意一行向右滑动，点亮星标即可加入自选并置顶"
                    : "已自选的弹药暂不在本次快照中（下架或改名），下拉刷新再试")
            } actions: {
                Button("查看全部") { filter = .all }
            }
        } else if dayTradeOnly {
            // ⑤ 日抛筛空：行情事实而非操作失误（口径与 web METHOD 日抛条同源）——
            // 如实陈述门槛 + 给「关闭日抛」出路（触发感与回顶由 onChange(of: dayTradeOnly) 统一承担）
            ContentUnavailableView {
                Label("当前没有可日抛的弹药", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("日抛口径：现价买入 ≤24 小时能涨到税后净利 ≥5% 的卖价（近 7 天上涨段中位，样本 ≥2）；现价处 7 天新低 / 新高的不算。高位盘整期命中稀少是行情事实，可下拉刷新再试")
            } actions: {
                Button("关闭日抛") { dayTradeOnly = false }
            }
        } else if filter == .all {
            ContentUnavailableView {
                Label("暂无行情数据", systemImage: "tray")
            } description: {
                Text("本次快照没有任何条目，下拉刷新再试")
            }
        } else {
            ContentUnavailableView {
                Label("当前没有\(filter.rawValue)信号", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("信号随行情约每分钟更新，可下拉立即刷新")
            } actions: {
                Button("查看全部") { filter = .all }
            }
        }
    }

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
            // marketReady：快照已落地才算「真下架 / 改名」——首载骨架期 / 首拉失败期
            // items 恒空，此时 item == nil 只是「还没拉到行情」，不能亮「不在当前行情」角标
            PositionRow(position: pos, item: nil, marketReady: app.market.snapshot != nil)
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
        // 日抛 toggle（正交约束，与 web 端 filtered 的 state.dayTrade 同位同口径）：
        // 信号锚定当下该买还是该卖，日抛约束一轮买卖的完成时限
        if dayTradeOnly {
            list = list.filter { SellEtaEngine.isDayTrade(item: $0) }
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
            case .dayTradeEta:
                // 默认升序=最快到价在前（对齐 web SORT_DIR.eta 'asc'）；无估计沉底
                let ae = SellEtaEngine.dayTradeEta(item: a)?.medianH ?? .infinity
                let be = SellEtaEngine.dayTradeEta(item: b)?.medianH ?? .infinity
                return ae < be
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
        // 行内横向间距 Space.sm（原字面量 10）：对齐雷达行（RadarView.swift:337，已注明「8（原 10）」收编）
        // 与 TTK 行（TtkView.swift:392）——三页列表行同层级同间距（T8 收编口径）；右列防截断配方只因此更宽松
        HStack(spacing: Theme.Space.sm) {
            ItemThumb(pic: item.pic, size: 40)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    if starred {
                        Image(systemName: "star.fill").font(Theme.font(.micro)).foregroundStyle(Theme.warn)
                            // 自选星标进出（MOTION.md §3-D 星标切换的行内对应物）：缩放 + 淡入 = 因果反馈。
                            // 详情页用 symbolEffect(.bounce)，但那是常驻图标；行内星标是条件插入视图，
                            // bounce 在插入帧不触发，改用 transition（只动 opacity / transform，§6-1）
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(item.name).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                }
                .layoutPriority(1) // 名称行优先保住单行高度，宽度不足时由本行截断承担
                // animFast 档只作用于本名称行子树：ForEach 行序变化（自选置顶）在其外，仍瞬时重排（原则 3）；RM 置 nil
                .motion(Theme.animFast, value: starred)
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
                    Mono("\(Fmt.signedPrice(p)) \(Fmt.pct(item.profitPct))", step: .lead, color: p > 0 ? Theme.ok : Theme.faint, minScale: 0.75)
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
            parts.append("预赚 \(Fmt.signedPrice(p)) 每发（\(Fmt.pct(item.profitPct))）")
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
                Text("预赚 \(Fmt.signedPrice(item.profitPerRound))/发")
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
        // 可点卡片（§4.1-7）：描边换 lineHover 暗示入口；按压 lift 面见共享 PressableButtonStyle（入口处挂载）
        .card(hoverable: true)
        // 合并朗读（§7-1）：与 SellSignalCard / AmmoRow 同款成句转述，替代逐控件拼读
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// 成句转述（语序对齐视觉：三格输入 → 预赚主数字 → 分位 → ETA）。显式 label 会
    /// 覆盖合并朗读，卡内可见的分位条与 ETA 行必须进转述（§7-1），否则 VO 用户拿不到
    /// 「等多久能卖」这个关键决策输入；两行 gate 与 body 视觉分支逐字同判（零口径漂移）
    private var a11yLabel: String {
        var parts = [item.name, "买入信号"]
        parts.append("买入不高于 \(Fmt.price(item.current))，挂卖 \(Fmt.price(item.targetSell))，税后到手 \(Fmt.price(item.netSell))")
        parts.append("预赚 \(Fmt.signedPrice(item.profitPerRound)) 每发（\(Fmt.pct(item.profitPct))）")
        if let rank = item.rank { parts.append("7 天分位 \(Fmt.rankPercent(rank))") }
        let eta = SellEtaEngine.predict(item: item)
        if let eta, let med = eta.medianH, eta.episodes >= 2 {
            parts.append("预计 \(SellEtaEngine.fmtHours(med)) 到价")
        } else if let eta, let peak = SellEtaEngine.fmtPeak(start: eta.peakStart, end: eta.peakEnd) {
            parts.append("日内 \(peak) 通常最贵")
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

    /// 成句转述（语序对齐视觉：三格 → 高位分位主数字 → 距最高 → 建议）。此前漏读了卡内
    /// 唯一主数字「高位 N%」（lead 档 danger，§4.1-2 立权的那一枚）与 7 天最高 / 到手两格——
    /// 显式 label 覆盖合并朗读，视觉主角在 VO 下反而缺席，违背 §1.1 / §7-1；按视觉顺序补齐
    private var a11yLabel: String {
        var parts = [item.name, "卖出信号"]
        parts.append("现价 \(Fmt.price(item.current))，7 天最高 \(Fmt.price(item.weekHigh))，税后到手 \(Fmt.price(item.netHigh))")
        parts.append(highRankText) // 主数字与视觉同文（「高位 N%」/ 缺分位「高位 —」）
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
    /// 行情快照是否已落地（false = 首载骨架期 / 首拉失败期）：此时 item == nil 只说明
    /// 「还没拉到行情」而非「下架 / 改名」——不亮「不在当前行情」角标，否则冷启动头几秒
    /// 整节台账全部误报下架（下架语义只在有快照可查时才成立，与 emptyState 各成因分判同思路）
    var marketReady = true

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
        HStack(spacing: Theme.Space.sm) { // 同 AmmoRow：行内横向间距对齐雷达 / TTK 行（Space.sm）
            // 缩略图槽位常驻：item == nil（下架 / 改名）的行也占 40pt 位，否则该行名称列左缘比同节其它行
            // 前移约 50pt，台账列对齐被打断（数据行扫读「每行同构」）；pic 为 nil 走 ItemThumb 既有无图呈现
            ItemThumb(pic: item?.pic, size: 40)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    Text(position.name).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                    if atTarget { StatusChip(text: "已到挂卖价", tint: Theme.danger) }
                    // 角标只在快照可查时亮（marketReady 见属性注释）：未加载 ≠ 下架
                    if item == nil, marketReady { StatusChip(text: "不在当前行情", tint: Theme.faint) }
                }
                .layoutPriority(1) // 名称行优先保住单行，宽度不足时由本行截断承担（同 AmmoRow）
                Text("\(position.qty) 发 × 成本 \(Fmt.price(position.cost))")
                    .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.faint)
            }
            Spacer(minLength: Theme.Space.xs)
            // 右列对齐 AmmoRow 权重（§1.1 主数字立权）：浮盈在上（lead + ok/danger，本行决策主数字）、
            // 现价在下（sub + tx）。原先现价渲染在前、浮盈沉底——与 AmmoRow「主上次下」倒挂，
            // 囤货行的扫读主角被次级数字压住
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                if let gainNet {
                    Mono(Fmt.signedPrice(gainNet), step: .lead, color: gainNet >= 0 ? Theme.ok : Theme.danger, minScale: 0.75)
                }
                if let item { Mono(Fmt.price(item.current), step: .sub, color: Theme.tx, minScale: 0.75) }
            }
            .lineLimit(1)
            // 对齐 AmmoRow 已实测的防截断配方（见 AmmoRow 右列注释）：minScale 直接传给每枚 Mono（T3 通道，
            // 容器级 .minimumScaleFactor 不传播到子 Text、长串会被截成「-851 -…」）+ 右列 layoutPriority(1)
            // （左列「可截断名称 + fixedSize 状态胶囊」的空间谈判中右列否则先被压截）。囤货浮盈 = 数量 × 差价，
            // 位数天然比行情行更长（如 +12,345），是本页最易溢出的数字列
            .layoutPriority(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// 成句转述，替代逐控件拼读
    private var a11yLabel: String {
        var parts = [position.name, "\(position.qty) 发，成本 \(Fmt.price(position.cost)) 每发"]
        if let item {
            // 语序对齐视觉（§4.1-1 同款：浮盈在上先读、现价在下后读）
            if let gainNet {
                parts.append("到价浮盈 \(Fmt.signedPrice(gainNet))")
            }
            if let c = item.current { parts.append("现价 \(Fmt.price(c))") }
            if atTarget { parts.append("已到挂卖价，可出货") }
        } else if marketReady {
            parts.append("已不在当前行情")
        } else {
            parts.append("行情未加载") // a11y 同口径：未加载 ≠ 下架，如实说明价格缺席的原因
        }
        return parts.joined(separator: "，")
    }
}

// 信号卡按压态已收编为共享 PressableButtonStyle（Components.swift，MOTION.md §3-D）：
// 行为逐项等价（lift 面 + animFast 档 + RM 置 nil 但色面态仍生效），本页不再保留私有副本

struct MethodNote: View {
    let source: String?
    /// 快照顶层 rules（analyze.mjs RULES_VIEW_KEYS 展示子集）；nil = 旧快照 / 字段缺席，
    /// 各门槛退 v2 定稿值兜底（同 web AmmoMarketView.vue ruleNum 的缺省参数做法）
    var rules: MarketRules? = nil

    var body: some View {
        // 门槛数字与分位刻度从 rules 取值渲染（契约 shared/API.md §1：不得写死数字；做法对齐 web
        // AmmoMarketView.vue:370-372 ruleNum / buyRankPct 等）：P20 = BUY_RANK_MAX、10% = BUY_MIN_NET_PCT、
        // P35 = WATCH_RANK_MAX、P80 = SELL_RANK_MIN、「近 3 天」= TARGET_WINDOW_H（72h）。此前把 v2 门槛写死在
        // 字面文案里，下次调参 iOS 必再漂移（v1→v2 已翻车一次）。离底 3% / 低点距今 12h / 税率 15% 不在
        // RULES_VIEW_KEYS 展示子集内，维持文字口径
        let buyRank = rulePct(rules?.buyRankMax, 20)
        let buyNet = rulePct(rules?.buyMinNetPct, 10)
        let watchRank = rulePct(rules?.watchRankMax, 35)
        let sellRank = rulePct(rules?.sellRankMin, 80)
        let targetDays = ruleDays(rules?.targetWindowH, 3)
        VStack(alignment: .leading, spacing: 6) {
            // 含中文标题：默认 design + 等宽数字（mono 只留给纯 ASCII）
            Text("口径").font(Theme.font(.xs, weight: .bold)).monospacedDigit().foregroundStyle(Theme.accent)
            // 正文含 P20/10%/15% 等实义数字：同样走等宽数字，与标题及全页数字节拍一致
            Text(MarketMeta.methodDataLine(source)).font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
            // 口径对齐信号 v2 回测定稿（server/ammo/analyze.mjs 头注与 RULES：BUY_RANK_MAX 0.20 /
            // BUY_MIN_NET_PCT 0.10 / 离底 3% + 低点距今 12h + 48h 斜率 ≥ 0 三重止跌确认 / 目标 = 近 72h P75 /
            // SELL 加动能守则）。此前文案是 v1 旧口径「≤ P25 且 ≥ 8%、目标取 7 天 P75」，web 端 METHOD 已随
            // v2 更新而本页滞留：用户按旧口径判读（如 rank 22%、收益 9% 的弹）会误以为 App 漏报买入——
            // 双端同口径是本页「信号仅供参考」这句话成立的前提
            Text("买卖点 = 近 7 天小时曲线分位 + 趋势确认：现价 ≤ P\(buyRank)、已止跌企稳（离 7 天低点 ≥ 3%、近 12 小时无新低、近 48 小时趋势不向下）且按近 \(targetDays) 天 P75 挂卖税后收益率 ≥ \(buyNet)% 判「买入」，低位（≤ P\(watchRank)）但门槛未齐判「关注」；≥ P\(sellRank) 且动能转弱判「卖出」，强势上冲不催卖。目标挂卖价取近 \(targetDays) 天 P75，税率按税后价实测反推（约 15%）。历史分位不代表未来走势，信号仅供参考。")
                .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
        }
    }

    /// rules 分位 / 收益率门槛 → 整数百分比（web buyRankPct 等的 Math.round(x * 100) 同式；
    /// 正数下 rounded() 与 Math.round 一致）；缺席 / 非有限数退 v2 定稿值（同 web ruleNum）
    private func rulePct(_ v: Double?, _ dflt: Int) -> Int {
        guard let v, v.isFinite else { return dflt }
        return Int((v * 100).rounded())
    }

    /// rules 小时窗口 → 天（TARGET_WINDOW_H 72 → 3；web 对 MAX_HOLD_H 同用 Math.round(h / 24)）；
    /// 缺席 / 非正数退 v2 定稿值
    private func ruleDays(_ v: Double?, _ dflt: Int) -> Int {
        guard let v, v.isFinite, v > 0 else { return dflt }
        return Int((v / 24).rounded())
    }
}
