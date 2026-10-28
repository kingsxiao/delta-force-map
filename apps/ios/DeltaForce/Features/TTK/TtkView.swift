// TtkView.swift — 枪械 TTK 排行：兵种 / 部位 / 护甲 / 弹药筛选，逐枪展开全弹药对比，穿透矩阵
// 动效对齐 MOTION.md §4.2：首载不加骨架（TTK 专档决策，见加载态注释）/ 三态互切 contentSwap /
// 空态 swapTransition / 筛选回顶 animMed；榜单重排刻意无动画（§3-B 大表重排口径）
import DeltaForceCore
import SwiftUI

struct TtkView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var classId = "ar"
    @State private var partId = "chest"
    @State private var armor = 4
    @State private var filterTag = "best"
    @State private var showMatrix = false
    @State private var query = ""
    /// 本页局部触觉 tick：筛选 / 分段 / 菜单选择 / 开 sheet 后自增（规范要求绑局部状态，不绑共享 Store 派生值）
    @State private var hapticTick = 0
    // 显式导航栈：UI 巡检 -openGunFirst 需要 programmatically push 枪械详情
    // （NavigationPath 装 Gun，与行内 NavigationLink 同轨）
    @State private var path = NavigationPath()
    /// 「复制错误信息」的可见回执（DESIGN §1.5 闭环反馈）：复制后按钮短暂转「已复制」+ 成功触感，
    /// 2s 后还原；纯视图局部状态
    @State private var errCopied = false
    /// chips 横滚行溢出探测：内容理想宽 / 可视宽两路测量（GeometryReader → PreferenceKey），
    /// 右缘渐隐遮罩仅在真溢出时启用——iPad / 横屏四枚全显时尾枚不虚化
    @State private var chipsContentWidth: CGFloat = 0
    @State private var chipsViewportWidth: CGFloat = 0
    private var chipsOverflow: Bool { chipsContentWidth > chipsViewportWidth + 0.5 }
    /// 回顶浮动钮显隐（思路库「回顶浮动钮」，与行情页同款规范跨页恒量）：离顶探测见
    /// TtkTopAwayProbe（挂在首行 chips 行背景）；TTK 榜 68~200+ 行，深处滚回顶成本高
    @State private var showBackTop = false

    /// 筛选变化后滚回榜首的锚点 id
    private static let topAnchor = "ttk-top"

    /// 回顶钮探测用的列表命名坐标系（挂在 List 上 = 列表可视口，探测的 frame 参照）；
    /// fileprivate：文件尾的 TtkTopAwayProbe（与行情页嵌套写法不同、此处独立成体）要读它
    fileprivate static let listSpace = "ttk-list"

    /// 离顶阈值：首行 minY 低于 -300（≈ 滚过筛选区 + 数行）才浮出回顶钮，浅滚不动声色（行情页同值）
    fileprivate static let topAwayThreshold: CGFloat = 300

    /// 默认口径（DESIGN §4.4-1）：「重置筛选」出口回到这套基准，与四枚 FilterMenu 的 defaultId 同源
    private static let defaultClassId = "ar"
    private static let defaultPartId = "chest"
    private static let defaultArmor = 4
    private static let defaultFilterTag = "best"

    private var filter: AmmoFilter {
        switch filterTag {
        case "best": .bestPerGun
        case "all": .all
        default: .pen(Int(filterTag.dropFirst(3)) ?? 0)
        }
    }

    private var armorOptions: [FilterOption<Int>] {
        [FilterOption(id: 0, label: "无甲")] + (1...6).map { FilterOption(id: $0, label: "\($0) 级甲") }
    }

    private var ammoOptions: [FilterOption<String>] {
        [FilterOption(id: "best", label: "每枪最佳"), FilterOption(id: "all", label: "全部组合")]
            + (0...7).map { FilterOption(id: "pen\($0)", label: "穿透 \($0) 级") }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let data = app.ttk.data {
                    content(data)
                        // 内容进场：淡入 + 6pt 轻上移、离场只淡出（§3-H 内容分支口径；
                        // RM 仅淡入），由下方两枚切换键驱动
                        .swapTransition()
                } else if let err = app.ttk.error {
                    // 错误态给出口（DESIGN §4.4-4）：只给「复制错误信息」——数据自 bundle 一次性加载，
                    // loadIfNeeded 的 guard（State/Stores.swift:69-80，禁改）决定「重试」必空转，诚实降级不给假按钮
                    ContentUnavailableView {
                        Label("TTK 数据不可用", systemImage: "scope")
                    } description: {
                        Text(err)
                    } actions: {
                        Button {
                            UIPasteboard.general.string = err
                            errCopied = true
                        } label: {
                            Label(errCopied ? "已复制" : "复制错误信息", systemImage: errCopied ? "checkmark" : "doc.on.doc")
                        }
                        // 复制是错误态唯一出口：给出可见回执（「已复制」）+ 成功触感（§1.5 闭环反馈；
                        // condition 只在置 true 时触发，2s 还原时不补一声触感）
                        .sensoryFeedback(.success, trigger: errCopied) { _, newValue in newValue }
                        .task(id: errCopied) {
                            guard errCopied else { return }
                            try? await Task.sleep(for: .seconds(2))
                            errCopied = false
                        }
                    }
                    .transition(.opacity) // 错误态出现淡入（DESIGN §5 P2）
                } else {
                    // 加载态：转圈配一句说明，冷启动不再是白屏转圈。
                    // 刻意不上骨架屏（MOTION.md §4.2 TTK 专档）：ttk.json 是 bundle 内同步读 + 解码
                    // （Stores.swift loadIfNeeded 无 await），本分支只存在一帧——骨架只会一帧闪现
                    // 后又整套淡出（原则 3 噪声）；spinner 同为一帧但零布局位移，观感更稳。
                    // 刷新语义不适用：bundle 数据无 refreshable
                    VStack(spacing: Theme.Space.sm) {
                        ProgressView()
                        Text("正在载入 TTK 数据").font(Theme.font(.xs)).foregroundStyle(Theme.dim)
                    }
                    .transition(.opacity) // 只淡出不位移（§3-H，防布局跳动）
                }
            }
            .background(Theme.bg)
            // 三态互切挂载（§4.2 口径，RM 内建置 nil）：双键各管半区——
            // data==nil 管「加载 ↔ 内容」（数据就绪 / 卸载），error!=nil 管「加载 ↔ 错误」
            //（同在 data==nil 半区内的分支换防，原先裸 .animation 只挂 error 键、
            // 且 durFast 是微交互档，状态切换档位归位 animSwap 0.25）
            .contentSwap(app.ttk.data == nil)
            .motion(Theme.animSwap, value: app.ttk.error != nil)
            .navigationTitle("TTK 排行")
            .toolbar {
                Button {
                    hapticTick += 1 // 打开 sheet 给轻触反馈
                    showMatrix = true
                } label: { Label("穿透矩阵", systemImage: "tablecells") }
            }
            .sheet(isPresented: $showMatrix) {
                // 传入当前护甲筛选：矩阵内高亮该列（sheet 切走页面上下文后的查值锚点）
                PenMatrixView(armor: armor).presentationDetents([.medium, .large])
            }
        }
        .onAppear { app.ttk.loadIfNeeded() }
    }

    private func content(_ data: TtkData) -> some View {
        let ranking = TtkEngine
            .ranking(data: data, classId: classId, partId: partId, armorLevel: armor, filter: filter)
            .filter {
                query.isEmpty
                    || $0.gun.zh.localizedCaseInsensitiveContains(query)
                    || $0.gun.en.localizedCaseInsensitiveContains(query)
            }
        let part = data.part(partId)
        return ScrollViewReader { proxy in
            List {
                Section {
                    // 筛选区收敛为一行横滚 chips（DESIGN §4.4-3）：部位 segmented 并入 FilterMenu，
                    // 四枚胶囊同族呈现（原生 Menu 浮层 + 偏离默认描边点亮 accent），榜单首行上移到折叠线内
                    ScrollView(.horizontal, showsIndicators: false) {
                        // chips 间距收 xs（Space 阶梯行内最小档）：402pt 屏上四枚累计过宽，
                        // 第 4 枚「弹药」的左缘原落在渐隐带里、caption 完全进不了首屏（视觉复验）。
                        // 间距 8→4 把尾枚左缘前移 12pt，是唯一不动 FilterChipLabel 内边距（共享组件）的间距杠杆
                        HStack(spacing: Theme.Space.xs) {
                            FilterMenu(
                                caption: "兵种",
                                options: data.classes.map { FilterOption(id: $0.id, label: $0.label) },
                                selection: $classId,
                                defaultId: Self.defaultClassId
                            )
                            FilterMenu(
                                caption: "部位",
                                options: data.parts.map { FilterOption(id: $0.id, label: $0.label) },
                                selection: $partId,
                                defaultId: Self.defaultPartId
                            )
                            FilterMenu(caption: "护甲", options: armorOptions, selection: $armor, defaultId: Self.defaultArmor)
                            FilterMenu(caption: "弹药", options: ammoOptions, selection: $filterTag, defaultId: Self.defaultFilterTag)
                        }
                        .background(
                            // 内容理想宽：横滚轴上 HStack 不被可视宽压缩，量到的是完整理想宽
                            GeometryReader { geo in
                                Color.clear.preference(key: ChipsContentWidthKey.self, value: geo.size.width)
                            }
                        )
                    }
                    // 横滚行的行内边距（对齐行情页信号卡横滚行先例，AmmoView.swift:110）：
                    // leading 12（比常规行 16 轻 4pt 出血）+ trailing 0——默认 16/16 时本行视口止于
                    // 行底右内缘，20pt 渐隐带恰好只罩住第 4 枚「弹药」的残影与空白行底（视觉复验：
                    // caption「弹药」完全进不了首屏、无任何可横滚暗示）。trailing 归零把视口撑到
                    // 卡片右缘，渐隐带随之压到真实 chip 内容上；负 padding 实测不扩 List 行视口，故走本 API
                    .listRowInsets(EdgeInsets(top: 16, leading: 12, bottom: 16, trailing: 0))
                    .background(
                        // 可视宽：ScrollView 边框即视口（含行内边距撑出的出血区域）
                        GeometryReader { geo in
                            Color.clear.preference(key: ChipsViewportWidthKey.self, value: geo.size.width)
                        }
                    )
                    // 离顶探测（回顶浮动钮数据源）：本行恒为列表首行，其在命名坐标系的 minY 即滚动偏移
                    .background(TtkTopAwayProbe(away: $showBackTop))
                    .onPreferenceChange(ChipsContentWidthKey.self) { chipsContentWidth = $0 }
                    .onPreferenceChange(ChipsViewportWidthKey.self) { chipsViewportWidth = $0 }
                    // 右缘渐隐遮罩（视觉复验修复：第 4 枚 chip 首屏被裁切却无「可横滚」暗示）：
                    // 尾端 16pt 白→透明 mask，内容淡出到卡片右缘（本行行底是 card，若按 bg 色做
                    // 渐变叠加会与行底错色成色带；mask 只取 alpha、与底色解耦）。未溢出时渐变恒白
                    // = 无观感变化；mask 不影响命中测试与 Menu 浮层。宽度 20→16：视口右缘已出血到
                    // 卡片边上，渐隐带整体右移压住「弹药」chip 尾部内容，16pt 足够暗示横滚、
                    // 又少吞一枚 caption 的可辨宽度（「弹」全程 alpha 1.0、「药」均值 ~0.7）
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(
                                colors: chipsOverflow ? [.white, .clear] : [.white, .white],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 16)
                        }
                    )
                    .id(Self.topAnchor)
                }
                .listRowBackground(Theme.card)

                Section("排行 · \(ranking.count) 项 · \(part?.label ?? "") · \(armor == 0 ? "无甲" : "\(armor) 级甲")") {
                    if ranking.isEmpty { emptyState() }
                    // TTK 比例条的满条基准：榜首最小「正」TTK（一枪死 ttk=0 不作基准——
                    // 0 基准会令其余弹全塌最小条，web bestTtk 同守卫）；无正基准时条恒画满
                    let bestTtk = ranking.first(where: { $0.ttk > 0 && $0.ttk.isFinite })?.ttk ?? 0
                    ForEach(Array(ranking.enumerated()), id: \.element.id) { idx, combo in
                        NavigationLink(value: combo.gun) {
                            let link = app.marketItem(cal: combo.gun.cal, ammo: combo.ammo.n)
                            RankRow(index: idx + 1, combo: combo, market: link.item, marketReady: link.snapshotReady, best: bestTtk)
                        }
                    }
                }
                .listRowBackground(Theme.card)

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        // 「口径」为中文标题：默认 design（不用 mono）
                        Text("口径").font(Theme.font(.xs, weight: .bold)).foregroundStyle(Theme.accent)
                        Text("100 血单血池；部位倍率 胸 1.0 / 腹 0.9 / 头 1.9（个别枪胸腹同伤）；逐发模拟「碎甲 — 掉血」：护甲未碎时伤害按穿透 × 护甲判定通过率（0 / 50% / 75% / 100%）折算，碎甲发按剩余耐久比例混合；TTK = (BTK − 1) × 60000 / RPM，首发命中即刻出膛不计时间。三连发武器按面板均值匀速近似。")
                            .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
                    }
                }
                .listRowBackground(Theme.card)
            }
            .themedList()
            .listStyle(.insetGrouped)
            // 回顶浮动钮（思路库「回顶浮动钮」，行情页同款）：命名坐标系给 TtkTopAwayProbe 当参照（列表可视口）
            .coordinateSpace(name: Self.listSpace)
            .overlay(alignment: .bottomTrailing) { backTopButton(proxy) }
            // 钮进出场 animFast 档——web 端 BackTop .totop 的 iOS 对应物（MOTION.md §3-A「返回顶部」）；RM 置 nil 瞬时
            .motion(Theme.animFast, value: showBackTop)
            // 搜索栏常驻（DESIGN §4.4-6）：与行情页对齐，数据密集工具搜索是跨 Tab 恒量
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索枪械")
            .sensoryFeedback(.selection, trigger: hapticTick)
            // 空态出现/消失走状态切换档（§3-H / §5 250ms，原 durFast 0.15 属档位误用）；
            // RM 下 contentSwap 内建置 nil = 瞬时呈现（§7-9）
            .contentSwap(ranking.isEmpty)
            .onChange(of: classId) { _, _ in filterChanged(proxy) }
            .onChange(of: partId) { _, _ in filterChanged(proxy) }
            .onChange(of: armor) { _, _ in filterChanged(proxy) }
            .onChange(of: filterTag) { _, _ in filterChanged(proxy) }
            // 搜索词是第五个筛选维度（换词 = 换榜），同样回顶——对齐行情页口径（AmmoView.swift:384）：
            // 本页 68~200+ 行是全 App 最长表，停在深处时输入首字符，匹配行骤减、滚动位越界
            // 被系统弹到口径页脚，用户看到的不是匹配行；web 端 TTK 任意 state 变化重建列表
            // 「从首批行重新看起」（TtkView.vue:156-170），同一心智。不走 filterChanged：
            // 键盘逐键已有系统触感，再补 selection 即双响，这里只回顶（行情页同款取舍）
            .onChange(of: query) { _, _ in scrollToTop(proxy) }
            // UI 巡检钩子（同 RootView -startTab 模式，生产无此参数）：-openGunFirst
            // 进首行枪械详情、-wfScrollEnd 滚到列表末尾补拍折叠区
            .task { await shotHook(proxy) }
            .navigationDestination(for: Gun.self) { gun in
                GunDetailView(gun: gun, data: data, partId: partId, armor: armor)
            }
        }
    }

    /// UI 巡检钩子：bundle 数据毫秒级就绪，仍统一等一拍再执行，避免深链落在加载态上
    @MainActor
    private func shotHook(_ proxy: ScrollViewProxy) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-openGunFirst") || args.contains("-wfScrollEnd") else { return }
        for _ in 0..<100 {
            if app.ttk.data != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if args.contains("-openGunFirst"),
           let data = app.ttk.data,
           let first = TtkEngine
               .ranking(data: data, classId: classId, partId: partId, armorLevel: armor, filter: filter)
               .first(where: { query.isEmpty || $0.gun.zh.localizedCaseInsensitiveContains(query) })?.gun {
            path.append(first)
        }
        if args.contains("-wfScrollEnd"), let data = app.ttk.data {
            // List 懒加载行首次布局完成前 scrollTo 会落空，数据就绪后再等一拍才滚；
            // 目标取最后一行自己的 id——滚 topAnchor 只能把首 Section 对进首屏，到不了列表末尾
            try? await Task.sleep(for: .milliseconds(800))
            let last = TtkEngine
                .ranking(data: data, classId: classId, partId: partId, armorLevel: armor, filter: filter)
                .last
            if let last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    /// 空态按成因分文案（DESIGN §4.4-1）：搜索无果给「清空搜索」、筛选无果给「重置筛选」回默认口径，
    /// 四维度组合无结果不再让用户逐个猜（对齐行情页空态做法）。
    /// 回顶已由 onChange(of: query) 统一承担（键盘输入同轨），按钮只补 selection 轻触——
    /// 键盘逐键有系统触感而按钮出口没有（§1.5 闭环，行情页同款分工）
    @ViewBuilder
    private func emptyState() -> some View {
        if !query.isEmpty {
            ContentUnavailableView {
                Label("没有匹配的枪械", systemImage: "magnifyingglass")
            } description: {
                Text("换个关键词，或清空搜索看全部枪械")
            } actions: {
                Button("清空搜索") {
                    hapticTick += 1
                    query = "" // 回顶走 onChange(of: query)，与逐键输入同一通路
                }
            }
            .frame(maxWidth: .infinity)
            .swapTransition() // 空态进场淡入 + 6pt 轻上移、离场只淡出（§3-H 内容分支口径）
        } else {
            ContentUnavailableView {
                Label("当前筛选无匹配弹药", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("兵种 · 部位 · 护甲 · 弹药组合无结果")
            } actions: {
                Button("重置筛选") {
                    classId = Self.defaultClassId
                    partId = Self.defaultPartId
                    armor = Self.defaultArmor
                    filterTag = Self.defaultFilterTag
                }
            }
            .frame(maxWidth: .infinity)
            .swapTransition() // 空态进场淡入 + 6pt 轻上移、离场只淡出（§3-H 内容分支口径）
        }
    }

    /// 筛选变化：滚回榜首 + 轻触反馈（长榜单深处换筛选不再迷失位置）；
    /// 滚动走 animMed 预设（§3-B 筛选回顶档，等价原字面值 .easeOut(durMed)），Reduce Motion 下
    /// 无动画直达（§7-9）。换榜本身刻意不加行级进出动画（§3-B 大表重排口径）：几十~200 行重排
    /// 的可感反馈由「回顶 + 触感 + Section 头计数瞬时更新」承担，行级 FLIP 代价大于收益
    private func filterChanged(_ proxy: ScrollViewProxy) {
        hapticTick += 1
        scrollToTop(proxy)
    }

    /// 回顶统一实现：换筛选回顶与回顶浮动钮共用；滚动走 animMed 预设（MOTION.md §3-B 回顶档），
    /// Reduce Motion 下改无动画直达（§7-9，触感保留）。与行情页 scrollToTop 同构（跨页恒量）
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(Self.topAnchor, anchor: .top)
        } else {
            withAnimation(Theme.animMed) {
                proxy.scrollTo(Self.topAnchor, anchor: .top)
            }
        }
    }

    /// 回顶浮动钮（思路库「回顶浮动钮」，行情页同款规范）：长表离顶后右下浮现。触控 44pt（§7-8）；
    /// card2 面 + lineHover 描边走面阶分层，轻投影补「悬浮于滚动内容之上」的最后一级分离
    /// （滚动内容与 card2 同亮度，纯面阶分不开，§8「靠面阶」口径不适用于悬浮件）；
    /// 点击走 scrollToTop（animMed 滚回榜首）。web 端 BackTop 的 iOS 对应物
    @ViewBuilder
    private func backTopButton(_ proxy: ScrollViewProxy) -> some View {
        if showBackTop {
            Button {
                scrollToTop(proxy)
            } label: {
                Image(systemName: "chevron.up")
                    .font(Theme.font(.md, weight: .semibold)) // 图标字号跟字阶走（§6.1-3）
                    .foregroundStyle(Theme.tx)
                    .frame(width: 44, height: 44)
                    .background(Theme.card2, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.lineHover, lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            }
            .buttonStyle(PressableButtonStyle(radius: 22))
            .accessibilityLabel("回到顶部")
            // 淡入 + 8pt 上移进出场：对齐 web BackTop 的 .totop（只动 opacity/transform，§6-1）
            .transition(.opacity.combined(with: .offset(y: 8)))
            .padding(.trailing, Theme.Space.lg)
            // 让位悬浮 Tab 胶囊：凸钮顶距屏底实测 ≈121pt（themedList 注释口径），垫 140pt 全不叠（行情页同值）
            .padding(.bottom, 140)
        }
    }
}

struct RankRow: View {
    let index: Int
    let combo: ComboResult
    /// 行情联动（弹名对齐见 AmmoAliasStore）：marketReady=false（快照未拉到 / 离线）
    /// 整列退场；ready 且 market=nil（未映射 / 禁交易弹）同样不渲染现价行——
    /// 此处曾显「未上架」占位，按需求移除：无行情就是没有这一行，不占位
    var market: MarketItem? = nil
    var marketReady: Bool = false
    /// TTK 比例条基准（当前榜单最小正 TTK；0 = 无基准，条画满不参与比较）
    var best: Double = 0
    /// 点现价直达该弹行情详情：写 app.pendingDetailName 复用通知深链管线（见 priceChip 注释）
    @Environment(AppModel.self) private var app
    /// 序号列宽随 Dynamic Type 缩放（锚与名次 sub 档同步走 subheadline）
    @ScaledMetric(relativeTo: .subheadline) private var indexWidth: CGFloat = 24

    /// 右块第三行文案（web metaText 同口径）：「碎甲 N」只在护甲真正参与判定时出现——
    /// broke == 0（无甲口径）或 pass == 1（穿透全额，碎甲与否不影响掉血）时省略。
    /// 原先恒显，无甲口径下整榜 68 行「碎甲 0」是纯噪声（信息密度回收，§1.1 让位主数字）
    private var shotsText: String {
        combo.sim.broke > 0 && combo.sim.pass < 1
            ? "\(combo.btk) 发 · 碎甲 \(combo.sim.broke)"
            : "\(combo.btk) 发"
    }

    var body: some View {
        // 行内主块间距走 Space 阶梯（sm）：与 GunDetail 弹药行同档同节奏，跨页恒量（§2 T8）
        HStack(spacing: Theme.Space.sm) {
            // 名次对齐雷达语言（DESIGN §4.4-7）：零填充 + sub 档，前三 accent 其余 faint
            Mono(String(format: "%02d", index), step: .sub, color: index <= 3 ? Theme.accent : Theme.faint)
                .frame(minWidth: indexWidth, alignment: .leading)
            GunImage(img: combo.gun.img)
            // 左块三行式（402pt 屏实测行内可用宽 ~130-160pt）：弹药行只放「徽标 + 弹名」——
            // 旧版弹名与现价/未上架同行，最坏组合（穿N 徽标 35 + M855A1 APC+ 76 + 现价带分位 ~98）
            // 超 200pt，唯一可伸缩的弹名被压成「…」、现价截成「现价 1,…」。而弹名是「每枪最佳」
            // 模式的答案本体，被截等于整行失义。现价独占第三行后各行恒完整：弹药行最坏
            // 35+76=111pt、现价行最坏 ~98pt，均低于行内可用宽下限——任何兵种 / 筛选组合不再截断折行
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: 6) {
                    // 枪名截断承担（§7-3）：徽标族 fixedSize 不让宽，特大字号下由枪名截断兜底，不再折行顶高；
                    // 先按 0.8 缩再截（视觉复验修复）：RPM 移上首行后 402pt 屏 SCAR-H 曾被截成「SCA…」——
                    // minimumScaleFactor 让枪名单行内缩至 80% 保完整显示，不换行；缩放仅水平收缩、
                    // 行高仍按原字体度量，不顶乱行高
                    Text(combo.gun.zh).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if combo.gun.burst == true { CategoryChip(text: "三连发") }
                    if combo.gun.est == true || combo.ammo.est == true { CategoryChip(text: "估") }
                    // 射速上移到枪名行（视觉复验修复）：RPM 是枪属性，原放弹药行使四件套
                    //（弹名+穿N徽章+现价/未上架+RPM）在 402pt 屏超宽约 30pt 的根因。枪名行有富余
                    //（burst / est 枪名全 ≤5 字符，带 chip 最坏 ~150pt < 行内可用宽）；minScale 兜底极端组合
                    Text("\(Int(combo.gun.rpm)) RPM")
                        .font(Theme.monoFont(.micro))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                HStack(spacing: 6) {
                    // 徽标置前（与 web 端排行行同序）：fixedSize 恒完整，宽度压力由弹名承担
                    PenBadge(pen: combo.ammo.pen)
                    // 弹药名可中可英（「亚音速」「龙息弹」）：默认 design + 等宽数字；
                    // 弹药行只剩弹名一个可变项（现价已独占第三行），常态恒完整显示；
                    // lineLimit(1) + minScale 0.8 只在特大 Dynamic Type 下兜底，不折行
                    //（M61 折成 M6/1 的教训），也不再出现整名被压成「…」
                    Text(combo.ammo.n).font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim).lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                priceChip
            }
            // 左右块最小间距走 Space.xs：与 GunDetail 弹药行、AmmoRow / PositionRow（AmmoView.swift）同令牌，
            // 四种数据行同一最小列距（§2 T8 收编字面值）
            Spacer(minLength: Theme.Space.xs)
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                // 行内最强数字（DESIGN §4.4-2 主数字立权）：TTK 毫秒数 lead 档 bold——排行页比较的就是它。
                // 榜首点亮 accent（web .rk-row.top1 .rk-ttv 同口径）：与 GunDetail 最佳弹药行同一套
                // 「accent 数字 = 本口径最快」标记语言，68 行长榜第一眼先落在冠军数字上；
                // 搜索收窄后榜首仍是所显行中最快（ranking 先排序再按词过滤，序不变），语义不漂
                TtkValue(combo: combo, color: index == 1 ? Theme.accent : Theme.txStrong)
                // TTK 比例条（web rk-bar 同口径）：条长 = 榜首/本行 TTK，68 枪长榜扫读不等逐个读数、
                // 条长即相对快慢；高度吃在右块与左块（三行式）的高度差内，行高不变。慢行（>2.2× 榜首，
                // web slow 同口径）条降 lineHover 灰——主数字 lead bold 权重不动（§4.4-2 契约不让）
                TtkBar(
                    ratio: TtkBar.ratio(best: best, ttk: combo.ttk),
                    slow: TtkBar.isSlow(best: best, ttk: combo.ttk)
                )
                // 中文混排：默认 design + 等宽数字；补 lineLimit(1) 对齐 §7-3 单行纪律：
                // 右块此前是全行唯一无约束文本，特大字号下折成两行顶乱行高
                Text(shotsText).font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        // VoiceOver：整行合并为单一元素并成句转述（现价并入转述文本；
        // 行内现价按钮的动作经合并让位于整行导航，行情 Tab 仍可从 Tab 栏直达）
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// 现价文本（点击直达该弹行情详情）：borderless 让 List 行内的按钮自成触达区、
    /// 不与整行 NavigationLink 抢整行点击；「现价 …」中文混排走 design + 等宽数字。
    /// 独占弹药行下方的第三行（不再与弹名抢宽，弹名恒完整）：常态整行放得下
    /// 「现价 N · N%」；ViewThatFits + minScale 仅留特大 Dynamic Type 的降级兜底——
    /// 先省「· N%」分位后缀、再缩 75%，现价数字永不折行、不截断（§7-3）。
    /// 无行情（快照未拉到 / 未映射 / 禁交易弹）整行不渲染，不显占位。
    /// 为什么走 pendingDetailName 而非裸切 Tab（原实现）：裸切只把人扔到行情榜顶，看哪发弹要再搜一遍，
    /// 「点现价」没有回声（§1.5 闭环）；web .d-mp 跳 /ammo?q=弹名 带上下文。复用通知深链管线
    /// （RootView 切行情 Tab + AmmoView onAppear/onChange 消费 push 详情、查无此弹兑底搜索词），
    /// 只写 AppModel 公开属性、不动 State 文件（§0 口径）；item 取自 app.market.items，弹名恒命中
    @ViewBuilder
    private var priceChip: some View {
        if marketReady, let market {
            Button {
                app.pendingDetailName = market.name
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 3) {
                        Text("现价 \(Fmt.price(market.current))")
                        if market.rank != nil {
                            Text("· \(Fmt.rankPercent(market.rank))")
                        }
                    }
                    Text("现价 \(Fmt.price(market.current))")
                }
                .font(Theme.font(.xs))
                .monospacedDigit()
                .lineLimit(1)
                // 大额现价（12.7mm 百万级）双档均超宽：先缩 75% 再截断，避免「现价 1,…」（OCR 实测）
                .minimumScaleFactor(0.75)
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless)
        }
    }

    /// 成句转述：名次 / 枪 / 弹药 / 现价 / TTK / 击杀与碎甲发数 / 射速（TTK 与碎甲口径同视觉行：首发 / 碎甲省略规则一致）
    private var a11yLabel: String {
        var s = "第 \(index) 名 · \(combo.gun.zh) · \(combo.ammo.n)"
        if marketReady, let market { s += " · 现价 \(Fmt.price(market.current))" }
        s += " · TTK \(combo.ttkA11y) · \(shotsText) · RPM \(Int(combo.gun.rpm))"
        return s
    }
}

struct GunDetailView: View {
    let gun: Gun
    let data: TtkData
    let partId: String
    let armor: Int
    /// 行情联动读 marketItem；点现价写 pendingDetailName 走通知深链直达详情（与排行行 priceChip 同机制）
    @Environment(AppModel.self) private var app
    /// 「穿透矩阵」sheet（与排行页工具栏入口同款）：全弹药对比行的 PenBadge「穿 N」与
    /// 「通过 X%」都出自穿透 × 护甲判定表——读行时查表是高频动作，入口跟随页面上下文，
    /// 不必弹回排行页再开；armor 传当前口径，矩阵内高亮同一列锚点
    @State private var showMatrix = false
    @State private var matrixTick = 0

    var body: some View {
        let combos = TtkEngine.combos(data: data, gun: gun, partId: partId, armorLevel: armor)
        let cal = data.calibers[gun.cal]
        // 最佳行标记基准（最小有限 TTK，含一枪死 0——标记跟随榜单 bestPerGun 口径）与
        // 比例条基准（最小「正」TTK，web detail base 同守卫拆两值：0 基准会让其余弹全塌最小条）
        let bestTtk = combos.map(\.ttk).filter { $0.isFinite && $0 >= 0 }.min() ?? 0
        let barBase = combos.first(where: { $0.ttk > 0 && $0.ttk.isFinite })?.ttk ?? 0
        List {
            Section {
                HStack(spacing: Theme.Space.md) {
                    GunImage(img: gun.img, size: 80)
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        // 头部元信息两级（对齐 web 详情头带 dh-en faint / dh-meta dim）：英文名是最弱的辨识补充，
                        // 落 faint；口径行是数据语境，落 dim。原口径行着 accent 越界——accent 只做激活 / 指针 /
                        // 导航（§1.2），静态元数据不能占它，否则与下方「现价」链接、最佳弹 accent 数字三处同色，
                        // 「青色 = 可点 / 最快」的指针语义被一行不可点的文字稀释
                        Text(gun.en).font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                        // 四格走共享 StatQuadRow（DESIGN §4.4-5 / §3 C5）：窄屏 / 特大字号 4→2×2 自动降级
                        StatQuadRow(
                            StatCell(label: "肉伤", value: "\(Int(gun.dmg))"),
                            StatCell(label: "甲伤", value: "\(Int(gun.admg))"),
                            StatCell(label: "射速", value: "\(Int(gun.rpm))"),
                            StatCell(label: "弹匣", value: "\(gun.mag)")
                        )
                        // 口径标签含中文（× 亦非 ASCII）：默认 design + 等宽数字
                        if let cal { Text("\(cal.label) · \(cal.sub)").font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim) }
                    }
                }
                if let note = gun.note { Text(note).font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim) }
            }
            .listRowBackground(Theme.card)

            Section("全部弹药 · \(data.part(partId)?.label ?? "") · \(armor == 0 ? "无甲" : "\(armor) 级甲")") {
                ForEach(combos) { c in
                    let link = app.marketItem(cal: gun.cal, ammo: c.ammo.n)
                    HStack(spacing: Theme.Space.sm) {
                        PenBadge(pen: c.ammo.pen)
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            // 弹名截断承担（§7-3）：备注 / 徽标不折让，长弹名（Ultra Nosler）由名称截断兜底
                            Text(c.ammo.n).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong).lineLimit(1)
                            if let note = c.ammo.note { Text(note).font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.faint).lineLimit(2) }
                            priceChip(link)
                        }
                        // 左右块最小间距 Space.xs：与排行行同令牌（原无参 Spacer 取系统默认 ~8，两种行节奏不齐）
                        Spacer(minLength: Theme.Space.xs)
                        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                            // 行主数字（DESIGN §1.3 / §4.4-2）：与排行行同款 TtkValue——「lead 档 bold 数字 + micro 单位退档」，
                            // 单位不再以 lead 同权混排（原「412 ms」整串 lead，单位抢数字的权）。
                            // 最佳弹药行（TTK == 本口径最小）数字点亮 accent（web drow.best 同语言）：
                            // 详情页接续榜单口径，「哪发弹最快」不用回列表对答案
                            TtkValue(combo: c, color: c.ttk == bestTtk ? Theme.accent : Theme.txStrong)
                            // TTK 比例条（web d-bar 同口径）：本枪全弹药横向对比，条越长越快；
                            // 与排行行同组件同基准规则，跨页扫读语汇恒量
                            TtkBar(
                                ratio: TtkBar.ratio(best: barBase, ttk: c.ttk),
                                slow: TtkBar.isSlow(best: barBase, ttk: c.ttk)
                            )
                            // 中文混排：默认 design + 等宽数字；「超弹匣」为 danger 段
                            //（web d-jline warn 同口径）：TTK 公式假设不换弹，击杀发数超过弹匣
                            // = 实战必须中途换弹，对快枪决策是关键否决项，不能埋进灰字里
                            HStack(spacing: 0) {
                                Text("\(c.btk) 发 · 通过 \(Int(c.sim.pass * 100))% · 无甲 \(c.sim.noArmorBtk) 发")
                                    .foregroundStyle(Theme.dim)
                                if c.btk > gun.mag {
                                    Text(" · 超弹匣").foregroundStyle(Theme.danger)
                                }
                            }
                            .font(Theme.font(.xs)).monospacedDigit().lineLimit(1)
                            // 先缩 75% 再截（本页降级梯既有档：枪名 0.8 / 现价 0.75 同款）：
                            // 「超弹匣」danger 段在行尾，特大字号下是无缩放时的第一截断受害者——
                            // 它是快枪决策的关键否决项，不能先被吃掉（RankRow 同行更短、无此风险）
                            .minimumScaleFactor(0.75)
                        }
                    }
                    // VoiceOver：列表行合并朗读成句（§7-1，与排行行同款取舍）——
                    // 行内现价按钮的动作经合并让位于整行朗读，行情 Tab 仍可从 Tab 栏直达
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(ammoRowA11yLabel(c, link, isBest: c.ttk == bestTtk))
                }
            }
            .listRowBackground(Theme.card)
        }
        .themedList()
        .listStyle(.insetGrouped)
        .navigationTitle(gun.zh)
        .navigationBarTitleDisplayMode(.inline)
        // 矩阵入口与排行页同款（Label + tablecells 图标，§6.1-2 映射不变）；
        // 打开给 selection 轻触（触感纪律：绑页面局部 @State）
        .toolbar {
            Button {
                matrixTick += 1
                showMatrix = true
            } label: { Label("穿透矩阵", systemImage: "tablecells") }
        }
        .sheet(isPresented: $showMatrix) {
            PenMatrixView(armor: armor).presentationDetents([.medium, .large])
        }
        .sensoryFeedback(.selection, trigger: matrixTick)
    }

    /// 现价文本（点击直达该弹行情详情，机制与排行行 priceChip 同：写 pendingDetailName 走通知深链管线）：
    /// 本 Section 行无整行导航，按钮自成触达区；
    /// 无行情（快照未拉到 / 未映射 / 禁交易弹）整行不渲染、不显占位（与排行行同口径）。
    /// 单行纪律与降级次序与排行行同款（§7-3）：先省「· N%」后缀、再缩 75%，现价数字永不折行
    @ViewBuilder
    private func priceChip(_ link: (item: MarketItem?, snapshotReady: Bool)) -> some View {
        if link.snapshotReady, let item = link.item {
            Button {
                app.pendingDetailName = item.name
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 3) {
                        Text("现价 \(Fmt.price(item.current))")
                        if item.rank != nil {
                            Text("· \(Fmt.rankPercent(item.rank))")
                        }
                    }
                    Text("现价 \(Fmt.price(item.current))")
                }
                .font(Theme.font(.xs))
                .monospacedDigit()
                .lineLimit(1)
                // 与排行行 priceChip 同款：大额现价先缩 75% 再截断
                .minimumScaleFactor(0.75)
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless)
        }
    }

    /// 成句转述：弹名 / 备注 / 现价 / TTK / 击杀与通过率 / 无甲发数 / 最佳与超弹匣（与排行行同口径；
    /// 「最佳」「超弹匣」是视觉独占信息，视觉标记有的 a11y 必须同给）
    private func ammoRowA11yLabel(_ c: ComboResult, _ link: (item: MarketItem?, snapshotReady: Bool), isBest: Bool) -> String {
        var s = c.ammo.n
        if let note = c.ammo.note { s += " · \(note)" }
        if link.snapshotReady, let item = link.item { s += " · 现价 \(Fmt.price(item.current))" }
        s += " · TTK \(c.ttkA11y) · \(c.btk) 发 · 通过 \(Int(c.sim.pass * 100))% · 无甲 \(c.sim.noArmorBtk) 发"
        if c.btk > gun.mag { s += " · 超弹匣" }
        if isBest { s += " · 最佳" }
        return s
    }
}

/// 官方渲染图：apps/web/public/guns 以文件夹引用捆绑（guns/<id>.webp）；AA-12 无图走剪影占位。
/// 缩略降权（DESIGN §4.4-2）：36pt + line 描边透明底（原 card2 亮底 44pt）——排行页要比较的是毫秒数，不是枪图
struct GunImage: View {
    let img: String?
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let img, let url = Bundle.main.url(forResource: img, withExtension: "webp", subdirectory: "guns"),
               let ui = UIImage(contentsOfFile: url.path) {
                Image(uiImage: ui).resizable().scaledToFit()
            } else {
                Image(systemName: "scope").foregroundStyle(Theme.faint)
            }
        }
        .padding(2) // 内衬让枪图不贴描边
        .frame(width: size * 1.6, height: size)
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusTile).stroke(Theme.line, lineWidth: 1))
        .accessibilityHidden(true) // 纯图形：枪名由所在行的合并 label 转述
    }
}

/// 穿透 × 护甲判定矩阵（0% / 50% / 75% / 100%）；点击任意格可锁定「行 × 列」查值十字（web 同款）
struct PenMatrixView: View {
    @Environment(\.dismiss) private var dismiss
    /// 当前排行筛选的护甲等级（TTK 页传入）：高亮对应列。sheet 切走了页面上下文，
    /// 「我现在是几级甲口径」不该靠用户回忆——accentBg 选中面 + 表头下划线恢复查值锚点；
    /// nil = 无上下文（默认调用观感不变）
    var armor: Int? = nil
    /// 查值锁定十字（web PenMatrix.vue「锁定十字」的 iOS 对应物——hover 十字引导在触屏不存在，
    /// 点格把「行 × 列」两轴钉住、再点同格解锁）：7×8 矩阵「3 级弹打 4 级甲」的交叉查值不再
    /// 纯靠眼睛横竖对齐。与 armor 锚点互相独立、可叠加：锚点是筛选上下文（accent 实色），
    /// 锁定是临时查值焦点（lift 白面 + accentDim 指示），两级强度刻意分层
    @State private var lockPen: Int? = nil
    @State private var lockArmor: Int? = nil
    /// 锁定切换触觉 tick（§5 触感纪律：绑 sheet 局部 @State；查值切换给 selection 轻反馈）
    @State private var lockTick = 0
    /// 单元格宽高随 Dynamic Type 缩放（原固定 46×30 违例清理；特大字号下靠双向 ScrollView 滚动）
    @ScaledMetric(relativeTo: .caption2) private var cellWidth: CGFloat = 46
    @ScaledMetric(relativeTo: .caption2) private var cellHeight: CGFloat = 30

    var body: some View {
        NavigationStack {
            // 矩阵页三段式：用法提示（顶）+ 可滚矩阵（中）+ 判定规则（底）——两段说明文字
            // 钉在 sheet 宽上自然折行，只有矩阵本体进双向 ScrollView。原先说明段也在横滚轴内：
            // 横滚容器给子视图无界宽提案，Text 按理想宽单行渲染，~120 字的规则段成 ~800pt
            // 长线，402pt 屏一次只读到一半、余下全靠横滑（web MX_NOTE 本就是折行段落）
            VStack(spacing: 0) {
                // 用法提示前置（终审复验）：「点击锁定」是查值核心交互，说明原全落在网格下方——
                // 默认 .medium 半屏下网格 + 表头已占满可视高（SE 级屏更紧），手势提示全程在
                // 折叠线下，首次打开只看到一张纯数字表；前置一行 ~20pt，「无提示的新手势等于不存在」
                Text("点击任意格锁定该行 × 列对照，再点同格解锁")
                    .font(Theme.font(.xs))
                    .monospacedDigit()
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.top, Theme.Space.md)
                    .padding(.bottom, Theme.Space.sm)
                ScrollView([.horizontal, .vertical]) {
                    Grid(horizontalSpacing: Theme.Space.xs, verticalSpacing: Theme.Space.xs) {
                        GridRow {
                            // 表头与导航标题口径一致；中文默认 design + 等宽数字
                            Text("穿透 \\ 护甲").font(Theme.font(.micro)).monospacedDigit().foregroundStyle(Theme.faint).frame(minWidth: cellWidth)
                            ForEach(0...6, id: \.self) { al in
                                Text(al == 0 ? "无甲" : "\(al) 级").font(Theme.font(.micro, weight: .bold)).monospacedDigit().foregroundStyle(Theme.level(al)).frame(minWidth: cellWidth)
                                    // 当前护甲列标记：accent 2pt 下划线（表列 idiom；等级语义色文字不动）；
                                    // 锁定列加降档 accentDim 下划线（web .lk-h 同语言）——筛选上下文恒强于
                                    // 临时查值焦点，两级下划线可辨且不抢「当前口径」的锚点地位
                                    .overlay(alignment: .bottom) {
                                        if al == armor {
                                            Rectangle().fill(Theme.accent).frame(height: 2)
                                        } else if lockArmor == al {
                                            Rectangle().fill(Theme.accentDim).frame(height: 2)
                                        }
                                    }
                                    .accessibilityLabel(al == armor ? "\(al == 0 ? "无甲" : "\(al) 级")，当前筛选" : (al == 0 ? "无甲" : "\(al) 级"))
                            }
                        }
                        ForEach(0...7, id: \.self) { pen in
                            GridRow {
                                Text("穿 \(pen)").font(Theme.font(.micro, weight: .bold)).monospacedDigit().foregroundStyle(Theme.pen(pen)).frame(minWidth: cellWidth)
                                ForEach(0...6, id: \.self) { al in
                                    let r = TtkEngine.passRate(pen: pen, armor: al)
                                    Text("\(Int(r * 100))%")
                                        .font(Theme.monoFont(.micro, weight: .semibold)) // 纯 ASCII（如 50%）保留 mono
                                        // 50%/75% 用 accent 对齐 web（PenMatrix.vue m75/m50：初版琥珀已全站弃用）；
                                        // 四档通过率绿/青/青/红双端同源，warn 金只留给信号语义
                                        .foregroundStyle(r == 0 ? Theme.danger : r == 1 ? Theme.ok : Theme.accent)
                                        .frame(minWidth: cellWidth, minHeight: cellHeight)
                                        .background {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: Theme.radiusBadge).fill(Theme.card)
                                                // 当前护甲列 accentBg 选中面（令牌注释口径「激活 chip 底 / 选中面」）：
                                                // accent 只做指针不进文字色，通过率四档语义色不受影响
                                                if al == armor {
                                                    RoundedRectangle(cornerRadius: Theme.radiusBadge).fill(Theme.accentBg)
                                                }
                                                // 锁定十字面纱（web lk-row / lk-col 同源 --lift 白 6%）：行或列被锁
                                                // 即罩引导面，叠在 armor 锚点底之上、位于描边之下；四档通过率语义色
                                                // 不动——面纱不承载独占信息（格值自含），纯引导增强
                                                if lockPen == pen || lockArmor == al {
                                                    RoundedRectangle(cornerRadius: Theme.radiusBadge).fill(Theme.lift)
                                                }
                                                // 对角线（穿透 == 护甲，web diag 同语言）：50%「同级甲弹门槛」
                                                // 一眼可辨，7×7 矩阵横竖对齐不再纯靠眼睛
                                                if pen == al {
                                                    RoundedRectangle(cornerRadius: Theme.radiusBadge).stroke(Theme.accentDim, lineWidth: 1)
                                                }
                                                // 锁定交叉点描边（web .lk 同语言）：与对角线同取 accentDim——
                                                // 锁定点恰在对角线上时两条件同格同值叠加，零覆盖冲突
                                                if lockPen == pen, lockArmor == al {
                                                    RoundedRectangle(cornerRadius: Theme.radiusBadge).stroke(Theme.accentDim, lineWidth: 1)
                                                }
                                            }
                                        }
                                        // 全格命中：contentShape 把 frame 撑出的透明边缘并入可点区（命中区 = 格面
                                        // ~46×30，受矩阵密度约束不外扩垫层——锁定是引导增强非主操作，格值静态可读）
                                        .contentShape(Rectangle())
                                        .onTapGesture { toggleLock(pen: pen, col: al) }
                                        // Grid 不关联行列头：单元格自述行列语义，补 VoiceOver 缺口；当前护甲列注明筛选上下文
                                        //（锁定态不给格挂动作焦点：web 同款决策——56 个停留点反而毁掉 VO 扫读流，格值已自含）
                                        .accessibilityLabel(al == 0 ? "穿 \(pen) 对无甲，通过率 \(Int(r * 100))%\(al == armor ? "，当前筛选" : "")" : "穿 \(pen) 对 \(al) 级甲，通过率 \(Int(r * 100))%\(al == armor ? "，当前筛选" : "")")
                                }
                            }
                        }
                    }
                    // 锁定十字面纱/描边淡入淡出走 animFast 微交互档（web 面纱 transition --t-fast 同档，
                    // MOTION.md §5 档位封闭）；RM 门内建于 motion（置 nil 瞬时呈现，触感保留——触感不属动效）
                    .motion(Theme.animFast, value: lockPen)
                    .motion(Theme.animFast, value: lockArmor)
                    // 查值锁定触感（思路库触感语义分层：selection 给切换类轻交互，不给成败语义）
                    .sensoryFeedback(.selection, trigger: lockTick)
                    .padding(Theme.Space.md)
                }
                // 说明文案与 web MX_NOTE 对齐：「点击锁定」用法已前置到顶部（见上），
                // 此处只留判定规则与 7 级穿透上限说明（矩阵末行「穿 7」的来历，web 有而 iOS 缺的知识位）
                Text("判定规则：穿透低于护甲 0%，持平 50%，高 1 级 75%，高 2 级及以上 100%；无甲一律 100%。7 级穿透为全游戏上限（.338 AP / .50 BMG SLAP），对 6 级甲仍 75%。")
                    .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.bottom, Theme.Space.md)
            }
            .background(Theme.bg)
            .navigationTitle("穿透 × 护甲判定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }

    /// 锁定 / 解锁查值十字（web toggleLock 同款：再点同格解锁）。两个方向都计一次 lockTick——
    /// 查值动作的触觉回声（§1.5 闭环反馈），selection 只表「切换了」不表方向
    private func toggleLock(pen: Int, col: Int) {
        if lockPen == pen, lockArmor == col {
            lockPen = nil
            lockArmor = nil
        } else {
            lockPen = pen
            lockArmor = col
        }
        lockTick += 1
    }
}

/// TTK 筛选 chips 行的溢出测量键（右缘渐隐只在真溢出时启用；测量点见 TtkView 筛选区）
private struct ChipsContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ChipsViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// TTK 展示口径（web format.js fmtMs 的 iOS 对应物）：TTK = 0 即 BTK = 1——首发命中即倒，
/// (BTK − 1) × 60000 / RPM 恒为 0。web 显「首发」，iOS 原显「0 ms」：数字上没错，语义上像数据缺失
/// （「0 毫秒击杀」不是玩家口语），且双端同一行读数不同。ttk == 0 用严格等于（web `ms === 0` 同款）：
/// btk = 1 时 0.0 × 60000 / rpm 精确为 0，rpm ≤ 0 的数据异常落 NaN / Inf 不命中，仍走「—」占位
extension ComboResult {
    /// 首发击倒（TTK 精确为 0）
    fileprivate var isFirstShot: Bool { ttk == 0 }

    /// VoiceOver 转述用 TTK 文案：首发 / N ms / 无法估算，与视觉行 TtkValue 的分支一致
    fileprivate var ttkA11y: String {
        if isFirstShot { return "首发击倒" }
        return ttkMillis.map { "\($0) ms" } ?? "无法估算"
    }
}

/// TTK 主数字（排行行与 GunDetail 弹药行共用，同层级同档）：lead 档 bold 数字 + micro 单位退档
/// （单位不与数字同权混排，§4.4-2）。首发行显中文「首发」：含中文一律默认 design（Theme.swift 等宽
/// 规则，mono 只留给纯 ASCII），字阶取 Theme.font(.lg)——与 MonoStep.lead 同锚 body、同为行内主数字档
/// （AmmoView SignalCard「预赚 …/发」lead 中英混排的既有配方），bold 与数字分支同权；不带单位（web 同款）。
/// color 由调用方给语义（榜首 / 最佳弹 accent，其余 txStrong），两分支同色
private struct TtkValue: View {
    let combo: ComboResult
    var color: Color = Theme.txStrong

    var body: some View {
        if combo.isFirstShot {
            Text("首发")
                .font(Theme.font(.lg, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Mono(combo.ttkMillis.map(String.init) ?? "—", step: .lead, weight: .bold, color: color)
                Text("ms").font(Theme.monoFont(.micro)).foregroundStyle(Theme.faint)
            }
        }
    }
}

/// TTK 比例条（web rk-bar / d-bar 同口径）：满宽 = 基准（榜单/本枪最小 TTK），条越长越快。
/// 排行行与 GunDetail 弹药行共用同一组件与基准规则——「相对快慢」的扫读语汇跨页恒量。
/// 轨道走 Theme.bg（比行底 card 深一档，web --bg 轨同面阶关系）；纯装饰图形
/// accessibilityHidden，毫秒数已由所在行合并 label 转述
private struct TtkBar: View {
    /// 条长比例（0...1，已含 4% 下限；计算见 ratio(best:ttk:)）
    let ratio: CGFloat
    /// 慢行降级（> 2.2× 基准，web slow 同口径）：条降 lineHover 灰，不用语义色
    var slow = false
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 64

    /// 比例口径与守卫（web barScale 同源）：ttk ≤ 0（一枪死 / 数据起点）本就是最快，画满；
    /// 非有限（rpm ≤ 0 等数据异常 → ±Inf/NaN）给最小条，与「—」占位同语义；正常值 clamp [0.04, 1]
    static func ratio(best: Double, ttk: Double) -> CGFloat {
        if best > 0, ttk.isFinite, ttk > 0 {
            return CGFloat(min(1, max(0.04, best / ttk))) // Double 显式转 CGFloat（无隐式转换）
        }
        return ttk.isFinite ? 1 : 0.04
    }

    /// 慢行判定（web slow 同口径）：ttk > 2.2× 基准；非有限值不算慢（另有最小条表达）
    static func isSlow(best: Double, ttk: Double) -> Bool {
        best > 0 && ttk.isFinite && ttk > best * 2.2
    }

    var body: some View {
        Capsule()
            .fill(Theme.bg)
            .frame(width: width, height: 5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(slow ? Theme.lineHover : Theme.accent)
                    .frame(width: max(3, width * ratio))
            }
            .accessibilityHidden(true)
    }
}

/// 回顶浮动钮离顶探测（思路库「回顶浮动钮」，行情页 TopAwayProbe 同款）：探测行背景
/// GeometryReader 读自身在列表命名坐标系的 minY，离顶超过阈值置 away。onChange 带
/// initial（iOS 17）：List 行懒回收后探测随行销毁、状态保留最后值（深处 = 钮常显）；
/// 行回到布局（滚回顶 / 回顶动画）时 initial 立即按当前位汇报，杜绝「人已回顶、钮还亮着」的滞留
private struct TtkTopAwayProbe: View {
    @Binding var away: Bool

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.frame(in: .named(TtkView.listSpace)).minY, initial: true) { _, minY in
                    away = minY < -TtkView.topAwayThreshold
                }
        }
    }
}
