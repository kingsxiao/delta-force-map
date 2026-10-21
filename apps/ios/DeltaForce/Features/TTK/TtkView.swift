// TtkView.swift — 枪械 TTK 排行：兵种 / 部位 / 护甲 / 弹药筛选，逐枪展开全弹药对比，穿透矩阵
import DeltaForceCore
import SwiftUI

struct TtkView: View {
    @Environment(AppModel.self) private var app
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
                    ContentUnavailableView("TTK 数据不可用", systemImage: "scope", description: Text(err))
                } else {
                    // 加载态：转圈配一句说明，冷启动不再是白屏转圈
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("正在载入 TTK 数据").font(Theme.font(.xs)).foregroundStyle(Theme.dim)
                    }
                }
            }
            .background(Theme.bg)
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
                    VStack(alignment: .leading, spacing: 10) {
                        // 下拉筛选统一换 FilterMenu 胶囊 chip：caption + 当前值一体呈现，
                        // 偏离默认值时描边点亮 accent；浮层为原生 Menu，选中项系统 checkmark + 根 tint
                        FilterMenu(
                            caption: "兵种",
                            options: data.classes.map { FilterOption(id: $0.id, label: $0.label) },
                            selection: $classId,
                            defaultId: "ar"
                        )
                        Picker("部位", selection: $partId) {
                            ForEach(data.parts) { Text($0.label).tag($0.id) }
                        }
                        .pickerStyle(.segmented)
                        HStack(spacing: 8) {
                            FilterMenu(caption: "护甲", options: armorOptions, selection: $armor, defaultId: 4)
                            FilterMenu(caption: "弹药", options: ammoOptions, selection: $filterTag, defaultId: "best")
                            Spacer(minLength: 0)
                        }
                    }
                    .id(Self.topAnchor)
                }
                .listRowBackground(Theme.card)

                Section("排行 · \(ranking.count) 项 · \(part?.label ?? "") · \(armor == 0 ? "无甲" : "\(armor) 级甲")") {
                    if ranking.isEmpty {
                        // 空态行（做法对齐 AmmoView）：不再只剩「排行 · 0 项」标题
                        Text("当前筛选无匹配弹药").font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                    }
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
            .searchable(text: $query, prompt: "搜索枪械")
            .sensoryFeedback(.selection, trigger: hapticTick)
            .onChange(of: classId) { _, _ in filterChanged(proxy) }
            .onChange(of: partId) { _, _ in filterChanged(proxy) }
            .onChange(of: armor) { _, _ in filterChanged(proxy) }
            .onChange(of: filterTag) { _, _ in filterChanged(proxy) }
            .navigationDestination(for: Gun.self) { gun in
                GunDetailView(gun: gun, data: data, partId: partId, armor: armor)
            }
        }
    }

    /// 筛选变化：滚回榜首 + 轻触反馈（长榜单深处换筛选不再迷失位置）
    private func filterChanged(_ proxy: ScrollViewProxy) {
        hapticTick += 1
        withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
    }
}

struct RankRow: View {
    let index: Int
    let combo: ComboResult
    /// 序号列宽随 Dynamic Type 缩放（原固定 24pt 违例清理）
    @ScaledMetric(relativeTo: .footnote) private var indexWidth: CGFloat = 24

    var body: some View {
        HStack(spacing: 10) {
            Mono(String(format: "%02d", index), size: 12, color: index <= 3 ? Theme.accent : Theme.faint, relativeTo: .footnote)
                .frame(minWidth: indexWidth, alignment: .leading)
            GunImage(img: combo.gun.img, size: 44)
            VStack(alignment: .leading, spacing: 3) {
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
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Mono("\(Int(combo.ttk.rounded()))", size: 16, weight: .bold, relativeTo: .callout)
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
                HStack(spacing: 12) {
                    GunImage(img: gun.img, size: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(gun.en).font(Theme.font(.xs)).foregroundStyle(Theme.dim)
                        HStack(spacing: 10) {
                            StatCell(label: "肉伤", value: "\(Int(gun.dmg))")
                            StatCell(label: "甲伤", value: "\(Int(gun.admg))")
                            StatCell(label: "射速", value: "\(Int(gun.rpm))")
                            StatCell(label: "弹匣", value: "\(gun.mag)")
                        }
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
                    HStack(spacing: 8) {
                        PenBadge(pen: c.ammo.pen)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.ammo.n).font(Theme.font(.md, weight: .semibold)).foregroundStyle(Theme.txStrong)
                            if let note = c.ammo.note { Text(note).font(Theme.font(.xs)).foregroundStyle(Theme.faint).lineLimit(2) }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Mono("\(Int(c.ttk.rounded())) ms", size: 14, relativeTo: .subheadline)
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

/// 官方渲染图：apps/web/public/guns 以文件夹引用捆绑（guns/<id>.webp）；AA-12 无图走剪影占位
struct GunImage: View {
    let img: String?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let img, let url = Bundle.main.url(forResource: img, withExtension: "webp", subdirectory: "guns"),
               let ui = UIImage(contentsOfFile: url.path) {
                Image(uiImage: ui).resizable().scaledToFit()
            } else {
                Image(systemName: "scope").foregroundStyle(Theme.faint)
            }
        }
        .frame(width: size * 1.6, height: size)
        .background(Theme.card2, in: RoundedRectangle(cornerRadius: 8))
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
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
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
                                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                                    // Grid 不关联行列头：单元格自述行列语义，补 VoiceOver 缺口
                                    .accessibilityLabel(al == 0 ? "穿 \(pen) 对无甲，通过率 \(Int(r * 100))%" : "穿 \(pen) 对 \(al) 级甲，通过率 \(Int(r * 100))%")
                            }
                        }
                    }
                }
                .padding(12)
                Text("国服社区实测口径：穿透低于护甲 0%，持平 50%，高 1 级 75%，高 2 级及以上 100%；无甲一律 100%。")
                    .font(Theme.font(.xs)).foregroundStyle(Theme.dim).padding(.horizontal, 12)
            }
            .background(Theme.bg)
            .navigationTitle("穿透 × 护甲判定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }
}
