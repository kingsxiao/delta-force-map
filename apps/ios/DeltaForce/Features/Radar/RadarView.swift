// RadarView.swift — 全品类异动雷达：kkrb 涨幅榜 Top10 + 双源交叉验证
// 动效对齐 MOTION.md §4.2：首载骨架（替代裸 ProgressView）/ 涨幅榜区四态互切 contentSwap /
// 后台刷新失败横幅淡入淡出；筛选换榜与 60s 静默刷新刻意不加行级动画（原则 3——回顶 + 触感即反馈）
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

    /// 数据源错误横幅文案：有快照的后台刷新失败才在此提示，正常态 nil
    /// （首拉失败由涨幅榜区 RetryErrorRow 承担，含重试出口，不同屏双份）
    private var bannerMessage: String? {
        app.radar.snapshot != nil ? app.radar.lastError : nil
    }

    /// 涨幅榜区四态：共享 FeedTableState 单一定义（Components.swift，MOTION.md §4.2——一致性评审
    /// 收口：三页逐字重复的私有 TableState 收编，防判据漂移；判据口径注释见共享定义处）；
    /// 也是 .contentSwap 的切换键
    private var tableState: FeedTableState {
        FeedTableState(
            hasSnapshot: app.radar.snapshot != nil,
            lastError: app.radar.lastError,
            isEmpty: rows.isEmpty
        )
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            // 数据源错误横幅：无快照的首拉失败由下方 RetryErrorRow 承担（含重试出口），
                            // 有快照（后台刷新失败）仍由此处提示——此时列表有数据可看、无 RetryErrorRow；
                            // 进出场淡入淡出由 List 层 .motion(animSwap, value: bannerMessage != nil) 驱动
                            FeedErrorBanner(message: bannerMessage)
                            // 市场态势行（§4.3-1）：本页唯一全局口径以语义胶囊组呈现（C2 StatusChip）；
                            // 特大字号 / 窄屏折两行（AX 韧性 §7-6）
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
                                // 计数一组读完，不再逐枚滑动；combine 的拼读停顿不可控，补成句 label
                                // 用顿号显式断句（成句纪律同 RadarRow.a11yLabel 的「，」分隔）
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("买入 \(s.buy)、卖出 \(s.sell)、关注 \(s.watch)、异常 \(s.anomaly ?? 0)、榜单 \(s.total) 项")
                            }
                            // 「只看双源异常」并入 chip 族（§4.3-2）：偏离默认值时描边点亮 accent。
                            // 同行右缀数据年龄（§1.5 闭环反馈的雷达页对应物）：下拉刷新成功而价格全无
                            // 变化时页面原本零可见变化（只剩触感），年龄行让「刷过了」肉眼可见且即时归零；
                            // ViewThatFits 两档兜底 AX 特大字号（§7-6）——同龄放不下时年龄换行右对齐，
                            // FilterMenu 永不消失
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: Theme.Space.sm) {
                                    scopeMenu
                                    Spacer(minLength: Theme.Space.xs)
                                    freshness
                                }
                                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                    scopeMenu
                                    freshness.frame(maxWidth: .infinity, alignment: .trailing)
                                }
                            }
                        }
                        .id(Self.topAnchor)
                    }
                    .listRowBackground(Theme.card)

                    // 骨架期间（无快照）Section 头隐藏计数（MOTION.md §4.2）：否则「涨幅榜 · 0 项」与 10 条假行同屏矛盾
                    Section(app.radar.snapshot == nil ? "涨幅榜" : "涨幅榜 · \(rows.count) 项") {
                        // 四态互切（MOTION.md §4.2）：Group 在 List 里是透明容器，各态子视图各自成行；
                        // .contentSwap 挂一次到分支容器上——.transition 只在分支切换且事务带动画时生效，
                        // 原先错误 / 空态 / 加载行三处 if-else 没有任何 .animation 驱动，一直是硬切
                        Group {
                            switch tableState {
                            case .error(let err):
                                // 首拉失败：换共享 RetryErrorRow（C10 安全序第 ② 步；busy 防空转——
                                // isLoading 守卫在 State/FeedModel.swift:55，加载中禁用 + 内联进度）；
                                // 重试走 refreshWithFeedback——成败二分触感与下拉刷新同一条闭环，
                                // 错误态唯一的主动作不再「只有视觉回声、没有可触结果」
                                RetryErrorRow(
                                    message: err,
                                    retry: { Task { await refreshWithFeedback() } },
                                    busy: app.radar.isLoading
                                )
                                .transition(.opacity) // 错误态淡入淡出（§3-H）
                            case .skeleton:
                                // 首载骨架（MOTION.md §4 P0）：10 条 RadarRow 同构骨架行（榜名槽 / 36 缩略图 /
                                // 右列「现价 + 走势线」槽），替代原裸 ProgressView + 文案行。不再用共享
                                // SkeletonList——那是 AmmoRow 同构（无名次槽、拇指 40、尾部多 56×8 分位条槽），
                                // 骨架→内容落位整体错位，违背 §4「结构贴近真实布局」；CraftView 已同因改本地行
                                //（CraftSkeletonRow）。行数固定不随屏幕堆、扫光 / RM 静态由共享基块内建
                                RadarSkeletonRows(rows: 10)
                                    .transition(.opacity) // 骨架只淡出不位移（防布局跳动）
                            case .empty:
                                // 筛选空态：给一条出路
                                ContentUnavailableView {
                                    Label("没有符合条件的条目", systemImage: "dot.radiowaves.left.and.right")
                                } description: {
                                    Text(anomalyOnly ? "当前榜单没有双源异常条目" : "榜单暂无条目")
                                } actions: {
                                    if anomalyOnly {
                                        Button("显示全部条目") { scope = .all }
                                    } else {
                                        // 非筛选性空态（榜单本身为空）也给一条出路：显式刷新对齐 web 空态
                                        // retry 按钮（MarketRadarView.vue:278），下拉刷新之外的等效出口；
                                        // busy 转内联进度防空转（模型层 isLoading 守卫双保险，同 RetryErrorRow 口径）
                                        Button {
                                            Task { await refreshWithFeedback() }
                                        } label: {
                                            HStack(spacing: 6) {
                                                if app.radar.isLoading { MiniSpin() }
                                                // 字阶与 RetryErrorRow 重试按钮同款（sm semibold），两态按钮不因所在分支不同而异档
                                                Text(app.radar.isLoading ? "刷新中" : "刷新")
                                                    .font(Theme.font(.sm, weight: .semibold))
                                            }
                                        }
                                        // 与错误态 RetryErrorRow 的「重试」逐项同构（bordered + large）：
                                        // Components.swift:426 实测口径——bordered 默认 ~34pt 偏小，large 才达
                                        // §7-8 触控目标 44pt。空态「刷新」是榜单为空时唯一的网络动作出口，
                                        // 与错误态「重试」同为四态主动作（busy 进度 / 文案切换 / disabled 三件全同），
                                        // 命中区与样式不该低一档。「显示全部条目」是筛选切换出口（全仓空态切换
                                        // 按钮 plain 同款），不随动
                                        .buttonStyle(.bordered)
                                        .controlSize(.large)
                                        .disabled(app.radar.isLoading)
                                    }
                                }
                                .swapTransition() // 空态进场淡入 + 6pt 轻上移、离场只淡出（§3-H 内容分支口径）
                            case .rows:
                                EmptyView()
                            }
                        }
                        .contentSwap(tableState)
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
                            // 正文含 Top10 / 15% 等实义数字：等宽数字与标题及全页数字节拍一致
                            //（AmmoView 口径行同款做法，AmmoView.swift:849 注释口径）
                            Text("异动清单为全品类涨幅榜 Top10；逐项结合小时曲线与分钟级现价，用与子弹页完全相同的分位数回归出信号（非子弹无税后字段，税率兜底 15%）。同一物品两路独立曲线在重叠小时上的中位偏差 > 15% 判「双源异常」：信号强制观望、不通知。")
                                .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
                .themedList()
                .listStyle(.insetGrouped)
                // 首载「骨架→内容」整页同步交叉淡化（MOTION.md §4.2）：态势胶囊组（首 Section）与骨架 / 涨幅榜行
                // 分属不同 Section，只挂在数据分支上会出现「骨架淡出、胶囊硬切」的半截动画，故 List 层再挂一次
                // 统一事务。键只认 snapshot == nil：有数据后的 60s 静默刷新与筛选换榜不触发（原则 3）
                .contentSwap(app.radar.snapshot == nil)
                // 后台刷新失败横幅进出场淡入淡出（§3-F 提示条口径的 iOS 对应物）：键只认有无横幅，文案变化不触发；
                // 横幅在首 Section 行内，带动画时同行 chip 组随之平滑让位而非整列跳动
                .motion(Theme.animSwap, value: bannerMessage != nil)
                .navigationTitle("异动雷达")
                .navigationDestination(for: MarketItem.self) { ItemDetailView(item: $0) }
                .refreshable {
                    // 刷新反馈二分（§4.3-6 / §5）：成功 .success / 失败 .error 触感，替换原无条件
                    // impact(light)；与错误态重试 / 空态刷新共用同一条闭环（见 refreshWithFeedback）
                    await refreshWithFeedback()
                }
                // 触感语义分层（本轮调研收紧）：自选切换是轻交互而非任务结果，.success 收回给
                // 刷新成败类（下行两条）——本条降 .impact(.light) 轻档，与「轻交互给轻 impact」对齐
                .sensoryFeedback(.impact(weight: .light), trigger: favTick)
                .sensoryFeedback(.success, trigger: refreshOkTick)
                .sensoryFeedback(.error, trigger: refreshErrTick)
                .sensoryFeedback(.selection, trigger: toggleTick)
                .onChange(of: scope) { _, _ in
                    scopeChanged(proxy)
                }
                // UI 巡检钩子（同 RootView -startTab 模式，生产无此参数）：
                // -wfScrollEnd 等首个快照落地后滚到列表末尾，补拍折叠区
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("-wfScrollEnd") else { return }
                    for _ in 0..<100 {
                        if app.radar.snapshot != nil { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    // List 懒加载行首次布局完成前 scrollTo 会落空，数据就绪后再等一拍才滚；
                    // 目标取最后一行自己的 id——滚 topAnchor 只能把首 Section 对进首屏，到不了列表末尾
                    try? await Task.sleep(for: .milliseconds(800))
                    if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// 「双源」筛选 chip（§4.3-2）：抽成员供 ViewThatFits 两档共用同一构造，防两处口径漂移
    private var scopeMenu: some View {
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

    /// 数据年龄（§1.5 闭环反馈在雷达页的对应物）：有快照才渲染（嵌在 stats 同一行的兄弟位置）。
    /// 两个刷新驱动互补——lastRefreshAt 前进时 body 重算（@Observable 追踪）年龄即时归零；
    /// 数据不变时 TimelineView 每 30s 给新「现在」让年龄继续走字（对齐原 FeedHeader 年龄行
    /// 的 30s 周期口径）。超数据源保鲜阈值转 warn 且文案读出「可能过期」（色觉之外的第二通道），
    /// 判定复用 FeedModel.isStale 的数据源口径而非硬编码分钟数（零魔法数）。文案走 Core 共享
    /// MarketMeta.fmtAge（与行情页 freshness / 详情页同一格式化器：jsRound 取整、含天档）——
    /// 此前私有 ageText 向上取整且小时封顶无天档，同一数据龄在雷达页与行情页显示不同值
    private var freshness: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            if let refreshedAt = app.radar.lastRefreshAt {
                let seconds = ctx.date.timeIntervalSince(refreshedAt)
                let text = seconds < 60 ? "刚刚更新" : "\(MarketMeta.fmtAge(minutes: seconds / 60))前更新"
                let stale = app.radar.isStale(now: ctx.date)
                Text(stale ? "\(text) · 数据可能过期" : text)
                    .font(Theme.font(.micro))
                    .monospacedDigit()
                    .foregroundStyle(stale ? Theme.warn : Theme.faint)
                    .lineLimit(1)
            }
        }
    }

    /// 筛选切换：轻触 + 滚回榜首（§4.3-5，与 TTK / 行情三页一致）；滚动收口共享 scrollToTop
    /// 帮助函数（Components.swift，animMed 预设 / MOTION.md §3-B 筛选回顶档，RM 无动画直达
    /// §7-9 触感保留）。换榜本身刻意不加行级进出动画（§3-B 大表重排口径，双端同为瞬时）：
    /// 回顶 + 触感即「换了榜单」的反馈
    private func scopeChanged(_ proxy: ScrollViewProxy) {
        toggleTick += 1
        scrollToTop(proxy, anchor: Self.topAnchor, reduceMotion: reduceMotion)
    }

    /// 刷新 + 成败二分触感（§4.3-6 / §5 闭环反馈）：下拉刷新、错误态「重试」、空态「刷新」
    /// 三个主动作共用同一条闭环。原先二分触感只挂在 refreshable 里——错误态重试完成后只有
    /// 视觉回声（内容进场 / 横幅滞留），没有可触结果；主动作的回声不该只有下拉手势才配拥有。
    /// 成功侧错误横幅（如有）随 lastError 清空自然退场，失败侧首拉错误行 / 横幅由 lastError 驱动
    private func refreshWithFeedback() async {
        await app.radar.refresh()
        if app.radar.lastError != nil { refreshErrTick += 1 } else { refreshOkTick += 1 }
    }

    private var rows: [MarketItem] {
        let items = app.radar.items.sorted { ($0.hiRank ?? 99) < ($1.hiRank ?? 99) }
        return anomalyOnly ? items.filter(\.isAnomaly) : items
    }
}

struct RadarRow: View {
    let item: MarketItem
    /// 榜名列对齐宽随字阶缩放（minWidth 而非固定宽）；名次已迁 sub 档（§4.3-3），锚跟随 subheadline。
    /// 24（原 30）：两位零填充名次 sub 档实测 ~17pt，24 仍有余量——省下的 6pt 让给右列走势线档落位
    @ScaledMetric(relativeTo: .subheadline) private var rankMinWidth = 24

    /// 名次语言（§4.3-3）：零填充 01、仅前三 accent 其余 faint——与 TTK 名次列同符号同字号（sub）同规则，
    /// accent 从「整列装饰」收回「前三指针」，不再稀释唯一强调色（§1.2）。
    /// 未上榜单（hiRank 缺失）显「—」而非「00」：双端口径对齐 web（`i.hiRank ?? '—'`），
    /// 「00」会被读成第 0 名——诚实缺席好过硬造名次
    private var rankText: String { item.hiRank.map { String(format: "%02d", $0) } ?? "—" }
    private var rankColor: Color {
        if let r = item.hiRank, (1...3).contains(r) { return Theme.accent }
        return Theme.faint
    }

    /// 分位语义色（双端口径对齐 web rb-num.low/.high，MarketRadarView.vue:745-747）：
    /// ≤35% 贴近 7 天低位（P25 买入参考区一侧）标 ok、≥80% 贴近高位（P80 卖出参考）标 danger、
    /// 其余 dim——「现在贵不贵」是雷达行仅次于现价的决策数字，语义色让低位 / 高位在扫读中
    /// 自己跳出、不必逐格读数；缺分位（—）dim 不表态。色只上数据，不上控件（§1.2 纪律）
    private var rankPctColor: Color {
        guard let r = item.rank, r.isFinite else { return Theme.dim }
        if r <= 0.35 { return Theme.ok }
        if r >= 0.8 { return Theme.danger }
        return Theme.dim
    }

    /// 迷你走势线（三档 ViewThatFits 共用）：一律信号色（双端口径对齐 web SIG_COLOR，
    /// MarketRadarView.vue:149——web 端走势线无异常特判，异常行信号已被服务端压制为观望/faint）。
    /// 「双源异常」的警示由 SignalChip 徽标与偏差值两处 warn 承担即可，走势线不再第三处同报
    /// （同信息不三报）；原先的异常警示金还会与「关注」行（watch 信号色=warn 金）走势线同色，
    /// 两种语义的行从曲线上无法分辨
    private var sparkline: some View {
        Sparkline(curve: item.curve, color: Theme.signal(item.signal))
    }

    var body: some View {
        // spacing 8（原 10）：四条间隙共省 8pt——与名次列 30→24 一起，为右列「带走势线档」凑出落位余量
        HStack(spacing: Theme.Space.sm) {
            Mono(rankText, step: .sub, color: rankColor)
                .frame(minWidth: rankMinWidth, alignment: .leading)
            ItemThumb(pic: item.pic, size: 36)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                // priority 落在名称行而非整个 VStack（同 AmmoRow 惯用法）：整列保护会把三枚徽标的
                // 理想宽（常比名称还宽）一并锁死，下方徽标 ViewThatFits 降档永不触发，行宽压力全部
                // 压进右列——现状截图 01-03 行「分位」标签被压成省略号、两个数值双双截断即此成因
                Text(item.name).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                    .layoutPriority(1) // 名称行优先取宽：压力先由徽标降档 / 右列缩放承担，名称最后才截断
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
            Spacer(minLength: Theme.Space.xs)
            // 右列 + 走势线三档 ViewThatFits（本行视觉修复）：原方案把走势线整枚垫在右列右侧，
            // 「带线档」理想宽 ≈ 右列(110pt+,宽头是分位/偏差行) + 间距 + 线宽 ≥ 160pt；而名称行
            // layoutPriority 取足理想宽后，实测留给本组的宽度只有 ~110-125pt（402pt 标准宽像素
            // 测量：01 行名称止于 212.7pt、右列起于 238.3pt）——中间档永远放不进，10 行走势线整体
            // 退场、行尾留大段空白带。改为走势线并入右列首行（现价行 ~64pt，远窄于分位/偏差行）：
            // 带线档理想宽只比纯右列宽 ~2pt，标准宽下真正落位；56×26 全量档（§4.3-4 / C9 决议，
            // 与行情行统一规格）留给 iPad / 横屏。行宽吃紧先退线再缩列（纯装饰、a11y 隐藏语义不变）
            ViewThatFits(in: .horizontal) {
                trailing(spark: sparkline.frame(width: 56, height: 26))
                trailing(spark: sparkline.frame(width: 40, height: 20))
                trailing()
            }
        }
        .padding(.vertical, 2)
        // 整行合并为单一朗读元素：名次 / 名称 / 分类 / 信号 / 现价 / 分位 / 双源偏差 一句话转述
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// 底档重载（走势线退场，仅右列）：裸调 trailing() 时泛型 Spark 无法从 nil 推断，收进无参重载
    private func trailing() -> some View { trailing(spark: EmptyView?.none) }

    /// 右列（§4.3-4 主数字立权）：雷达行主数字=现价升 lead 档、分位 / 偏差迁 sub；
    /// 单行 + 随宽缩一档兜底，不折行。
    /// `spark` 挂在现价行尾的迷你走势线：并入右列首行而非垫在整列右侧——现价行(~64pt)远窄于
    /// 分位/偏差行(~110pt)，带线档的理想宽只比纯右列宽出「线宽+间距」的一小截，三档才真正分得开
    private func trailing<Spark: View>(spark: Spark?) -> some View {
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.sm) {
                Mono(Fmt.price(item.current), step: .lead, minScale: 0.75)
                if let spark { spark }
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                // 微标签 fixedSize（同徽标单行纪律）：宽度压力下 2 字标签永不压成「分…」，
                // 截断让位给右侧数值（尾端省略号仍可读出「分位 42…」）
                Text("分位").font(Theme.font(.micro)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: true, vertical: false)
                Mono(Fmt.rankPercent(item.rank), step: .sub, color: rankPctColor, minScale: 0.75)
                if let dev = item.crossDev {
                    // 偏差标签含中文用默认 design，数值纯 ASCII 走 Mono sub；非异常实测偏差 dim、
                    // 异常 warn、重叠不足 faint——三档可辨（双端口径对齐 web .cross 三态，
                    // MarketRadarView.vue:814-831：实测 dim / 缺席 faint / 异常 warn。原先非异常
                    // 偏差也 faint，「已验证且一致」会被读成与「未下结论」同档）；
                    // leading +xs 把组间距拉到 8（组内 4）：读作「分位42% / 偏差1.6%」两组而非四个等距词元
                    Text("偏差").font(Theme.font(.micro)).foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.leading, Theme.Space.xs)
                    Mono(Fmt.pct(dev).replacingOccurrences(of: "+", with: ""), step: .sub, color: item.isAnomaly ? Theme.warn : Theme.dim, minScale: 0.75)
                } else if let overlap = item.crossOverlap {
                    // 双源第三态（对齐 web 端 crossLabel 口径 MarketRadarView.vue:106-107）：偏差数据
                    // 缺失 ≠ 无交叉验证——重叠不足 24h 时两路曲线不下双源结论，显示「重叠 Nh」
                    // 让「未验证」与「已验证且一致」可区分，弱化 faint 呈现（信息价值低于已验证偏差）
                    Text("重叠").font(Theme.font(.micro)).foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.leading, Theme.Space.xs)
                    Mono("\(overlap)h", step: .sub, color: Theme.faint, minScale: 0.75)
                }
            }
        }
        // minScale 逐 Mono 传参（T3 通道）而非挂容器：容器级 .minimumScaleFactor 不会传播到
        // 子 Text（AmmoRow 实测截断教训，AmmoView.swift:501-503 同款修复）——AX 大字号 / 长价格
        // 串下行宽吃紧，缩放必须在 Text 自身生效，否则截断成「12,3…」
        .lineLimit(1)
    }

    /// 成句转述，替代逐控件拼读。未上榜单不报「第 0 名」（与视觉「—」同口径），首位直接读名称
    private var a11yLabel: String {
        var parts: [String] = []
        if let rank = item.hiRank { parts.append("涨幅榜第 \(rank) 名") }
        parts.append(item.name)
        if let category = item.category { parts.append(category) }
        if item.isAnomaly {
            // 异常态补读被压制的原始信号（对齐 web 展开行口径 MarketRadarView.vue:487）：只读「双源异常」
            // 不说「原本是什么、被压制成什么」，视障用户拼不出「原始买入但口径分歧、只能观望」的判断链；
            // rawSignal 缺席（旧快照无此字段）退化为主语句，不硬造信号（宁缺勿错）
            let raw = item.rawSignal?.label
            parts.append(raw.map { "双源异常，原始信号 \($0) 已压制为观望" } ?? "双源异常，信号已压制为观望")
        } else {
            parts.append(item.signal.label)
        }
        if let current = item.current { parts.append("现价 \(Fmt.price(current))") }
        if let rank = item.rank { parts.append("分位 \(Fmt.rankPercent(rank))") }
        // 双源第三态与视觉同步（web 端 a11y 口径，MarketRadarView.vue:400）：重叠不足 24h 要读出
        // 「未下双源结论」，不能与「已验证一致」混淆
        if let dev = item.crossDev {
            parts.append("双源偏差 \(Fmt.pct(dev))")
        } else if let overlap = item.crossOverlap {
            parts.append("双路曲线重叠仅 \(overlap) 小时，不足 24 小时未下双源结论")
        }
        return parts.joined(separator: "，")
    }
}

// MARK: - 首载骨架（MOTION.md §4；基块复用共享 SkeletonBlock / SkeletonLine，
// 行结构为 RadarRow 专属同构——CraftView 本地骨架行同款先例）

/// 骨架行集合（对齐共享 SkeletonList 的 Group 容器形态）：Group 在 List 里是透明容器，
/// 每条 RadarSkeletonRow 各自成行；行数固定 10（§4.2 共性红线：与涨幅榜真实量级同数、不随屏幕堆）
private struct RadarSkeletonRows: View {
    var rows: Int = 10

    var body: some View {
        Group {
            ForEach(0..<max(0, rows), id: \.self) { _ in
                RadarSkeletonRow()
            }
        }
    }
}

/// 雷达骨架行：逐槽对齐 RadarRow——榜名槽（sub 档 + 同款 minWidth）/ ItemThumb 36 / 名称与
/// 徽标两行 / 右列「现价 lead + 迷你走势线 56×26」首行 + 「分位/偏差 sub」次行（走势线并入
/// 首行而非尾槽，取真实行三档 ViewThatFits 的首档形态）。待共享层把 SkeletonRow 行结构
/// 参数化后收编（见 sharedRequests）。行底与行内边距不覆写——继承涨幅榜 Section 的
/// Theme.card 与默认 insets，与真实行同壳
private struct RadarSkeletonRow: View {
    /// 榜名槽宽与 RadarRow.rankMinWidth 同步（ScaledMetric 随字阶缩放，防 AX 档槽位错位）
    @ScaledMetric(relativeTo: .subheadline) private var rankMinWidth = 24

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            SkeletonLine(width: 18, height: 12) // 榜名「01」（sub 档两位零填充）
                .frame(minWidth: rankMinWidth, alignment: .leading) // 对齐 RadarRow 榜名槽位
            SkeletonBlock(width: 36, height: 36) // ItemThumb 36
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                SkeletonLine(width: 110, height: 14) // 物品名（md 档行高位）
                SkeletonLine(width: 96, height: 10) // 分类 + 等级 + 信号徽标行（micro 档）
            }
            Spacer(minLength: Theme.Space.xs)
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.sm) {
                    SkeletonLine(width: 64, height: 16) // 现价（lead 档行高位）
                    SkeletonBlock(width: 56, height: 26, radius: 4) // 迷你走势线槽（C9 统一规格）
                }
                SkeletonLine(width: 110, height: 11) // 分位 / 偏差（sub 档）
            }
        }
        .padding(.vertical, 2) // 与真实行同壳（RadarRow 行内垂直 padding 同值）
        .listRowSeparator(.hidden) // 骨架纪律：低对比、安静（同共享 / Craft 骨架行）
        .accessibilityHidden(true) // 纯装饰占位整行隐藏，加载语义由页面状态承担
    }
}
