// TtkView.swift — 枪械 TTK 排行：兵种 / 部位 / 护甲 / 弹药筛选，逐枪展开全弹药对比，穿透矩阵
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
    /// 「复制错误信息」的可见回执（DESIGN §1.5 闭环反馈）：复制后按钮短暂转「已复制」+ 成功触感，
    /// 2s 后还原；纯视图局部状态
    @State private var errCopied = false
    /// chips 横滚行溢出探测：内容理想宽 / 可视宽两路测量（GeometryReader → PreferenceKey），
    /// 右缘渐隐遮罩仅在真溢出时启用——iPad / 横屏四枚全显时尾枚不虚化
    @State private var chipsContentWidth: CGFloat = 0
    @State private var chipsViewportWidth: CGFloat = 0
    private var chipsOverflow: Bool { chipsContentWidth > chipsViewportWidth + 0.5 }

    /// 筛选变化后滚回榜首的锚点 id
    private static let topAnchor = "ttk-top"

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
        NavigationStack {
            Group {
                if let data = app.ttk.data {
                    content(data)
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
                    // 加载态：转圈配一句说明，冷启动不再是白屏转圈
                    VStack(spacing: Theme.Space.sm) {
                        ProgressView()
                        Text("正在载入 TTK 数据").font(Theme.font(.xs)).foregroundStyle(Theme.dim)
                    }
                }
            }
            .background(Theme.bg)
            // 错误态出现淡入（durFast 令牌；Reduce Motion 直接呈现，§7-9）
            .animation(reduceMotion ? nil : .easeOut(duration: Theme.durFast), value: app.ttk.error)
            .navigationTitle("TTK 排行")
            .toolbar {
                Button {
                    hapticTick += 1 // 打开 sheet 给轻触反馈
                    showMatrix = true
                } label: { Label("穿透矩阵", systemImage: "tablecells") }
            }
            .sheet(isPresented: $showMatrix) {
                PenMatrixView().presentationDetents([.medium, .large])
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
                        HStack(spacing: Theme.Space.sm) {
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
                    .background(
                        // 可视宽：ScrollView 边框即视口
                        GeometryReader { geo in
                            Color.clear.preference(key: ChipsViewportWidthKey.self, value: geo.size.width)
                        }
                    )
                    .onPreferenceChange(ChipsContentWidthKey.self) { chipsContentWidth = $0 }
                    .onPreferenceChange(ChipsViewportWidthKey.self) { chipsViewportWidth = $0 }
                    // 右缘渐隐遮罩（视觉复验修复：第 4 枚 chip 首屏被裁切却无「可横滚」暗示）：
                    // 尾端 20pt 白→透明 mask，内容淡出到所在行底（本行行底是 card，若按 bg 色做
                    // 渐变叠加会与行底错色成色带；mask 只取 alpha、与底色解耦）。未溢出时渐变恒白
                    // = 无观感变化；mask 不影响命中测试与 Menu 浮层
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(
                                colors: chipsOverflow ? [.white, .clear] : [.white, .white],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 20)
                        }
                    )
                    .id(Self.topAnchor)
                }
                .listRowBackground(Theme.card)

                Section("排行 · \(ranking.count) 项 · \(part?.label ?? "") · \(armor == 0 ? "无甲" : "\(armor) 级甲")") {
                    if ranking.isEmpty { emptyState(proxy) }
                    ForEach(Array(ranking.enumerated()), id: \.element.id) { idx, combo in
                        NavigationLink(value: combo.gun) {
                            let link = app.marketItem(cal: combo.gun.cal, ammo: combo.ammo.n)
                            RankRow(index: idx + 1, combo: combo, market: link.item, marketReady: link.snapshotReady)
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
            // 搜索栏常驻（DESIGN §4.4-6）：与行情页对齐，数据密集工具搜索是跨 Tab 恒量
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索枪械")
            .sensoryFeedback(.selection, trigger: hapticTick)
            // 空态出现/消失淡入（DESIGN §5 P2；Reduce Motion 直接呈现，§7-9）
            .animation(reduceMotion ? nil : .easeOut(duration: Theme.durFast), value: ranking.isEmpty)
            .onChange(of: classId) { _, _ in filterChanged(proxy) }
            .onChange(of: partId) { _, _ in filterChanged(proxy) }
            .onChange(of: armor) { _, _ in filterChanged(proxy) }
            .onChange(of: filterTag) { _, _ in filterChanged(proxy) }
            .navigationDestination(for: Gun.self) { gun in
                GunDetailView(gun: gun, data: data, partId: partId, armor: armor)
            }
        }
    }

    /// 空态按成因分文案（DESIGN §4.4-1）：搜索无果给「清空搜索」、筛选无果给「重置筛选」回默认口径，
    /// 四维度组合无结果不再让用户逐个猜（对齐行情页空态做法）
    @ViewBuilder
    private func emptyState(_ proxy: ScrollViewProxy) -> some View {
        if !query.isEmpty {
            ContentUnavailableView {
                Label("没有匹配的枪械", systemImage: "magnifyingglass")
            } description: {
                Text("换个关键词，或清空搜索看全部枪械")
            } actions: {
                Button("清空搜索") {
                    query = ""
                    // 清空=换榜：轻触反馈 + 滚回榜首，与筛选切换 / 重置筛选同款闭环（§1.5）；
                    // query 不在 onChange 名单里（输入时不许跳），出口处手动补
                    filterChanged(proxy)
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)
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
            .transition(.opacity)
        }
    }

    /// 筛选变化：滚回榜首 + 轻触反馈（长榜单深处换筛选不再迷失位置）；
    /// 动画走 durMed 令牌（DESIGN §5），Reduce Motion 下无动画直达（§7-9）
    private func filterChanged(_ proxy: ScrollViewProxy) {
        hapticTick += 1
        if reduceMotion {
            proxy.scrollTo(Self.topAnchor, anchor: .top)
        } else {
            withAnimation(.easeOut(duration: Theme.durMed)) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
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
    /// 点现价切到行情 Tab（RootView 经 environment 暴露的选中 Binding）
    @Environment(\.tabSelection) private var tabSelection
    /// 序号列宽随 Dynamic Type 缩放（锚与名次 sub 档同步走 subheadline）
    @ScaledMetric(relativeTo: .subheadline) private var indexWidth: CGFloat = 24

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
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    // 行内最强数字（DESIGN §4.4-2 主数字立权）：TTK 毫秒数 lead 档 bold——排行页比较的就是它
                    Mono("\(Int(combo.ttk.rounded()))", step: .lead, weight: .bold)
                    Text("ms").font(Theme.monoFont(.micro)).foregroundStyle(Theme.faint)
                }
                // 中文混排：默认 design + 等宽数字；补 lineLimit(1) 对齐 §7-3 单行纪律：
                // 右块此前是全行唯一无约束文本，特大字号下折成两行顶乱行高
                Text("\(combo.btk) 发 · 碎甲 \(combo.sim.broke)").font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        // VoiceOver：整行合并为单一元素并成句转述（现价并入转述文本；
        // 行内现价按钮的动作经合并让位于整行导航，行情 Tab 仍可从 Tab 栏直达）
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// 现价文本（点击切行情 Tab）：borderless 让 List 行内的按钮自成触达区、
    /// 不与整行 NavigationLink 抢整行点击；「现价 …」中文混排走 design + 等宽数字。
    /// 独占弹药行下方的第三行（不再与弹名抢宽，弹名恒完整）：常态整行放得下
    /// 「现价 N · N%」；ViewThatFits + minScale 仅留特大 Dynamic Type 的降级兜底——
    /// 先省「· N%」分位后缀、再缩 75%，现价数字永不折行、不截断（§7-3）。
    /// 无行情（快照未拉到 / 未映射 / 禁交易弹）整行不渲染，不显占位
    @ViewBuilder
    private var priceChip: some View {
        if marketReady, let market {
            Button {
                tabSelection.wrappedValue = .ammo
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

    /// 成句转述：名次 / 枪 / 弹药 / 现价 / TTK / 击杀与碎甲发数 / 射速
    private var a11yLabel: String {
        var s = "第 \(index) 名 · \(combo.gun.zh) · \(combo.ammo.n)"
        if marketReady, let market { s += " · 现价 \(Fmt.price(market.current))" }
        s += " · TTK \(Int(combo.ttk.rounded())) ms · \(combo.btk) 发碎甲 \(combo.sim.broke) · RPM \(Int(combo.gun.rpm))"
        return s
    }
}

struct GunDetailView: View {
    let gun: Gun
    let data: TtkData
    let partId: String
    let armor: Int
    @Environment(AppModel.self) private var app
    /// 点现价切到行情 Tab（RootView 经 environment 暴露的选中 Binding）
    @Environment(\.tabSelection) private var tabSelection

    var body: some View {
        let combos = TtkEngine.combos(data: data, gun: gun, partId: partId, armorLevel: armor)
        let cal = data.calibers[gun.cal]
        List {
            Section {
                HStack(spacing: Theme.Space.md) {
                    GunImage(img: gun.img, size: 80)
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(gun.en).font(Theme.font(.xs)).foregroundStyle(Theme.dim)
                        // 四格走共享 StatQuadRow（DESIGN §4.4-5 / §3 C5）：窄屏 / 特大字号 4→2×2 自动降级
                        StatQuadRow(
                            StatCell(label: "肉伤", value: "\(Int(gun.dmg))"),
                            StatCell(label: "甲伤", value: "\(Int(gun.admg))"),
                            StatCell(label: "射速", value: "\(Int(gun.rpm))"),
                            StatCell(label: "弹匣", value: "\(gun.mag)")
                        )
                        // 口径标签含中文（× 亦非 ASCII）：默认 design + 等宽数字
                        if let cal { Text("\(cal.label) · \(cal.sub)").font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.accent) }
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
                        Spacer()
                        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                            // 行主数字（DESIGN §1.3 / §4.4-2）：与排行行同款「lead 档 bold 数字 + micro 单位退档」，
                            // 单位不再以 lead 同权混排（原「412 ms」整串 lead，单位抢数字的权）
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Mono("\(Int(c.ttk.rounded()))", step: .lead, weight: .bold)
                                Text("ms").font(Theme.monoFont(.micro)).foregroundStyle(Theme.faint)
                            }
                            // 中文混排：默认 design + 等宽数字
                            Text("\(c.btk) 发 · 通过 \(Int(c.sim.pass * 100))% · 无甲 \(c.sim.noArmorBtk) 发")
                                .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
                        }
                    }
                    // VoiceOver：列表行合并朗读成句（§7-1，与排行行同款取舍）——
                    // 行内现价按钮的动作经合并让位于整行朗读，行情 Tab 仍可从 Tab 栏直达
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(ammoRowA11yLabel(c, link))
                }
            }
            .listRowBackground(Theme.card)
        }
        .themedList()
        .listStyle(.insetGrouped)
        .navigationTitle(gun.zh)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 现价文本（点击切行情 Tab）：本 Section 行无整行导航，按钮自成触达区；
    /// 无行情（快照未拉到 / 未映射 / 禁交易弹）整行不渲染、不显占位（与排行行同口径）。
    /// 单行纪律与降级次序与排行行同款（§7-3）：先省「· N%」后缀、再缩 75%，现价数字永不折行
    @ViewBuilder
    private func priceChip(_ link: (item: MarketItem?, snapshotReady: Bool)) -> some View {
        if link.snapshotReady, let item = link.item {
            Button {
                tabSelection.wrappedValue = .ammo
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

    /// 成句转述：弹名 / 备注 / 现价 / TTK / 击杀与通过率 / 无甲发数（与排行行同口径）
    private func ammoRowA11yLabel(_ c: ComboResult, _ link: (item: MarketItem?, snapshotReady: Bool)) -> String {
        var s = c.ammo.n
        if let note = c.ammo.note { s += " · \(note)" }
        if link.snapshotReady, let item = link.item { s += " · 现价 \(Fmt.price(item.current))" }
        s += " · TTK \(Int(c.ttk.rounded())) ms · \(c.btk) 发 · 通过 \(Int(c.sim.pass * 100))% · 无甲 \(c.sim.noArmorBtk) 发"
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

/// 穿透 × 护甲判定矩阵（0% / 50% / 75% / 100%）
struct PenMatrixView: View {
    @Environment(\.dismiss) private var dismiss
    /// 单元格宽高随 Dynamic Type 缩放（原固定 46×30 违例清理；特大字号下靠双向 ScrollView 滚动）
    @ScaledMetric(relativeTo: .caption2) private var cellWidth: CGFloat = 46
    @ScaledMetric(relativeTo: .caption2) private var cellHeight: CGFloat = 30

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Grid(horizontalSpacing: Theme.Space.xs, verticalSpacing: Theme.Space.xs) {
                    GridRow {
                        // 表头与导航标题口径一致；中文默认 design + 等宽数字
                        Text("穿透 \\ 护甲").font(Theme.font(.micro)).monospacedDigit().foregroundStyle(Theme.faint).frame(minWidth: cellWidth)
                        ForEach(0...6, id: \.self) { al in
                            Text(al == 0 ? "无甲" : "\(al) 级").font(Theme.font(.micro, weight: .bold)).monospacedDigit().foregroundStyle(Theme.level(al)).frame(minWidth: cellWidth)
                        }
                    }
                    ForEach(0...7, id: \.self) { pen in
                        GridRow {
                            Text("穿 \(pen)").font(Theme.font(.micro, weight: .bold)).monospacedDigit().foregroundStyle(Theme.pen(pen)).frame(minWidth: cellWidth)
                            ForEach(0...6, id: \.self) { al in
                                let r = TtkEngine.passRate(pen: pen, armor: al)
                                Text("\(Int(r * 100))%")
                                    .font(Theme.monoFont(.micro, weight: .semibold)) // 纯 ASCII（如 50%）保留 mono
                                    .foregroundStyle(r == 0 ? Theme.danger : r == 1 ? Theme.ok : Theme.warn)
                                    .frame(minWidth: cellWidth, minHeight: cellHeight)
                                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusBadge))
                                    // Grid 不关联行列头：单元格自述行列语义，补 VoiceOver 缺口
                                    .accessibilityLabel(al == 0 ? "穿 \(pen) 对无甲，通过率 \(Int(r * 100))%" : "穿 \(pen) 对 \(al) 级甲，通过率 \(Int(r * 100))%")
                            }
                        }
                    }
                }
                .padding(Theme.Space.md)
                Text("判定规则：穿透低于护甲 0%，持平 50%，高 1 级 75%，高 2 级及以上 100%；无甲一律 100%。")
                    .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim).padding(.horizontal, Theme.Space.md)
            }
            .background(Theme.bg)
            .navigationTitle("穿透 × 护甲判定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
        .preferredColorScheme(.dark)
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
