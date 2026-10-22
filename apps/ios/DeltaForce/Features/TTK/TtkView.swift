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
                        } label: {
                            Label("复制错误信息", systemImage: "doc.on.doc")
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
                    }
                    .id(Self.topAnchor)
                }
                .listRowBackground(Theme.card)

                Section("排行 · \(ranking.count) 项 · \(part?.label ?? "") · \(armor == 0 ? "无甲" : "\(armor) 级甲")") {
                    if ranking.isEmpty { emptyState }
                    ForEach(Array(ranking.enumerated()), id: \.element.id) { idx, combo in
                        NavigationLink(value: combo.gun) {
                            RankRow(index: idx + 1, combo: combo)
                        }
                    }
                }
                .listRowBackground(Theme.card)

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        // 「口径」为中文标题：默认 design（不用 mono）
                        Text("口径").font(Theme.font(.xs, weight: .bold)).foregroundStyle(Theme.accent)
                        Text("100 血单血池；部位倍率 胸 1.0 / 腹 0.9 / 头 1.9（个别枪胸腹同伤）；逐发模拟「碎甲 — 掉血」：护甲未碎时伤害按穿透 × 护甲判定通过率（0 / 50% / 75% / 100%）折算，碎甲发按剩余耐久比例混合；TTK = (BTK − 1) × 60000 / RPM，首发命中即刻出膛不计时间。三连发武器按面板均值匀速近似。")
                            .font(Theme.font(.xs)).foregroundStyle(Theme.dim)
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
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView {
                Label("没有匹配的枪械", systemImage: "magnifyingglass")
            } description: {
                Text("换个关键词，或清空搜索看全部枪械")
            } actions: {
                Button("清空搜索") { query = "" }
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
    /// 序号列宽随 Dynamic Type 缩放（锚与名次 sub 档同步走 subheadline）
    @ScaledMetric(relativeTo: .subheadline) private var indexWidth: CGFloat = 24

    var body: some View {
        HStack(spacing: 10) {
            // 名次对齐雷达语言（DESIGN §4.4-7）：零填充 + sub 档，前三 accent 其余 faint
            Mono(String(format: "%02d", index), step: .sub, color: index <= 3 ? Theme.accent : Theme.faint)
                .frame(minWidth: indexWidth, alignment: .leading)
            GunImage(img: combo.gun.img)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: 6) {
                    Text(combo.gun.zh).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong)
                    if combo.gun.burst == true { CategoryChip(text: "三连发") }
                    if combo.gun.est == true || combo.ammo.est == true { CategoryChip(text: "估") }
                }
                HStack(spacing: 6) {
                    // 弹药名可中可英（「亚音速」「龙息弹」）：默认 design + 等宽数字
                    Text(combo.ammo.n).font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
                    PenBadge(pen: combo.ammo.pen)
                    Text("\(Int(combo.gun.rpm)) RPM").font(Theme.monoFont(.micro)).foregroundStyle(Theme.faint)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    // 行内最强数字（DESIGN §4.4-2 主数字立权）：TTK 毫秒数 lead 档 bold——排行页比较的就是它
                    Mono("\(Int(combo.ttk.rounded()))", step: .lead, weight: .bold)
                    Text("ms").font(Theme.monoFont(.micro)).foregroundStyle(Theme.faint)
                }
                // 中文混排：默认 design + 等宽数字
                Text("\(combo.btk) 发 · 碎甲 \(combo.sim.broke)").font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
            }
        }
        .padding(.vertical, 2)
        // VoiceOver：整行合并为单一元素并成句转述
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// 成句转述：名次 / 枪 / 弹药 / TTK / 击杀与碎甲发数 / 射速
    private var a11yLabel: String {
        "第 \(index) 名 · \(combo.gun.zh) · \(combo.ammo.n) · TTK \(Int(combo.ttk.rounded())) ms · \(combo.btk) 发碎甲 \(combo.sim.broke) · RPM \(Int(combo.gun.rpm))"
    }
}

struct GunDetailView: View {
    let gun: Gun
    let data: TtkData
    let partId: String
    let armor: Int

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
                if let note = gun.note { Text(note).font(Theme.font(.xs)).foregroundStyle(Theme.dim) }
                if let conflict = gun.conflict { Text("数据分歧：\(conflict)").font(Theme.font(.xs)).foregroundStyle(Theme.warn) }
            }
            .listRowBackground(Theme.card)

            Section("全部弹药 · \(data.part(partId)?.label ?? "") · \(armor == 0 ? "无甲" : "\(armor) 级甲")") {
                ForEach(combos) { c in
                    HStack(spacing: Theme.Space.sm) {
                        PenBadge(pen: c.ammo.pen)
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text(c.ammo.n).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong)
                            if let note = c.ammo.note { Text(note).font(Theme.font(.xs)).foregroundStyle(Theme.faint).lineLimit(2) }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                            // 行主数字走 lead 档（DESIGN §1.3「同层级同档」）：弹药对比行比的就是 TTK
                            Mono("\(Int(c.ttk.rounded())) ms", step: .lead)
                            // 中文混排：默认 design + 等宽数字
                            Text("\(c.btk) 发 · 通过 \(Int(c.sim.pass * 100))% · 无甲 \(c.sim.noArmorBtk) 发")
                                .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            .listRowBackground(Theme.card)
        }
        .themedList()
        .listStyle(.insetGrouped)
        .navigationTitle(gun.zh)
        .navigationBarTitleDisplayMode(.inline)
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
                Text("国服社区实测口径：穿透低于护甲 0%，持平 50%，高 1 级 75%，高 2 级及以上 100%；无甲一律 100%。")
                    .font(Theme.font(.xs)).foregroundStyle(Theme.dim).padding(.horizontal, Theme.Space.md)
            }
            .background(Theme.bg)
            .navigationTitle("穿透 × 护甲判定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }
}
