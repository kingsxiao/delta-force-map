// CraftDetailView.swift — 制造配方详情：利润拆解 + 材料清单 + 参照区间
import DeltaForceCore
import SwiftUI

struct CraftDetailView: View {
    @Environment(AppModel.self) private var app
    let item: CraftItem
    let placeLabel: String

    // 本页局部触觉 tick（刷新成败二分；trigger 只绑本页 State，对齐 ItemDetailView）
    @State private var refreshOkTick = 0
    @State private var refreshErrTick = 0

    /// 数据解冻（§4.2-1，对齐 ItemDetailView.resolved）：按 id 现查制造快照，
    /// SSE craft 事件 / 轮询替换 snapshot 后页面数字自动跟随；查无（配方下架 /
    /// 快照未到）回落 push 时刻的冻结值
    private var resolved: CraftItem {
        app.craft.snapshot?.items.first { $0.id == item.id } ?? item
    }

    private var profitColor: Color {
        if let p = resolved.profit { return p >= 0 ? Theme.ok : Theme.danger }
        return Theme.dim
    }

    var body: some View {
        let it = resolved
        List {
            // 头部：图标 / 名称 / 徽标 / 主角数字（时利 hero）
            Section {
                HStack(spacing: Theme.Space.md) {
                    ItemThumb(pic: it.output.pic, size: 52)
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        HStack(spacing: 6) {
                            Text(it.output.name)
                                .font(Theme.font(.lg, weight: .semibold))
                                .foregroundStyle(Theme.txStrong)
                                .lineLimit(2)
                            if it.output.count > 1 {
                                Text("×\(it.output.count)")
                                    .font(Theme.monoFont(.xs, weight: .semibold))
                                    .foregroundStyle(Theme.dim)
                            }
                        }
                        HStack(spacing: 6) {
                            CategoryChip(text: placeLabel)
                            GradeBadge(grade: it.output.grade)
                            if let lv = it.requiredLevel {
                                StatusChip(text: "Lv.\(lv) 解锁", tint: Theme.dim)
                            }
                        }
                    }
                }
                .padding(.vertical, Theme.Space.xs)
                // 缺价配方的服务端字段是 0 而非 null（契约 §1.3 降级展示）：
                // 时利 hero 以 hasEstimate 为门槛，否则走缺价警示而非「+0」绿色
                if it.hasEstimate, let p = it.profitPerHour {
                    // 主角数字（§1.1）：详情页唯一 hero
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Mono(p >= 0 ? "+\(Fmt.price(p))" : Fmt.price(p), step: .hero, color: profitColor)
                        Text("每小时 · \(it.periodLabel ?? "—")")
                            .font(Theme.font(.xs))
                            .foregroundStyle(Theme.faint)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("每小时利润 \(Fmt.price(p))，制造耗时 \(it.periodLabel ?? "未知")")
                } else if !it.isComplete {
                    Label("材料或产出缺价（\(it.missingPriceCount) 项），利润无法估算", systemImage: "exclamationmark.triangle")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.warn)
                } else {
                    Label("制造耗时数据缺失，时利无法估算", systemImage: "exclamationmark.triangle")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.warn)
                }
            }
            .listRowBackground(Theme.card)

            // 利润拆解（缺价时整节退场）
            if it.hasEstimate {
                Section("利润拆解") {
                    StatQuadRow(
                        StatCell(label: "产出收入", value: Fmt.price(it.revenue), color: Theme.txStrong),
                        // 费率并入标签而非拼进数值：全角括号后缀曾把本格值撑宽 ~20pt，
                        // 与「材料成本」的列距被挤到其余两列的 1/3（§1.3 同层级同档，四格值宽须同量级）
                    StatCell(label: feeLabel, value: Fmt.price(it.fee), color: Theme.dim),
                        StatCell(label: "材料成本", value: Fmt.price(it.cost), color: Theme.dim),
                        StatCell(label: "净利润", value: Fmt.price(it.profit), color: profitColor, emphasis: .hero)
                    )
                    .padding(.vertical, Theme.Space.xs)
                    // 公式行：与网页端展开区同文案；正文含实义金额，走等宽数字（同 MethodNote 口径）。
                    // 「；」后强制换行：自然折行时「＝」可能恰好落在第二行行首（SwiftUI 不做中文避头尾），分段后行首恒为「收入」
                    Text("利润 = 收入 \(Fmt.price(it.revenue)) − 手续费 \(Fmt.price(it.fee)) − 材料 \(Fmt.price(it.cost))；\n收入 = 产出单价 \(Fmt.price(it.output.price)) × \(it.output.count)。")
                        .font(Theme.font(.xs))
                        .monospacedDigit()
                        .foregroundStyle(Theme.faint)
                }
                .listRowBackground(Theme.card)
            }

            // 材料清单
            Section("材料 · \(it.materials.count) 项") {
                ForEach(it.materials) { m in
                    HStack(spacing: Theme.Space.sm) {
                        ItemThumb(pic: m.pic, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(m.name).font(Theme.font(.sm, weight: .semibold)).foregroundStyle(Theme.txStrong)
                                Text("×\(m.count)").font(Theme.monoFont(.xs)).foregroundStyle(Theme.dim)
                            }
                            if m.price != nil {
                                Text("单价 \(Fmt.price(m.price))").font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                            }
                        }
                        Spacer(minLength: 4)
                        if let cost = m.cost {
                            Mono(Fmt.price(cost), step: .sub, color: Theme.txStrong)
                        } else {
                            Text("无价").font(Theme.font(.xs)).foregroundStyle(Theme.warn)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(m.name) 数量 \(m.count)\(m.cost != nil ? "，合计 \(Fmt.price(m.cost))" : "，缺价")")
                }
            }
            .listRowBackground(Theme.card)

            // 参照区间（缺价项的 ROI / 产出单价同样以 hasEstimate 门槛降级为「—」）
            Section("参照") {
                StatQuadRow(
                    StatCell(label: "今日最高", value: Fmt.price(it.todayMaxProfit), color: Theme.warn),
                    StatCell(label: "7 日最高", value: Fmt.price(it.sevenDayMaxProfit), color: Theme.warn),
                    StatCell(label: "成本回报", value: roiText, color: roiColor),
                    StatCell(label: "产出单价", value: it.hasEstimate ? Fmt.price(it.output.price) : "—", color: Theme.txStrong)
                )
                .padding(.vertical, Theme.Space.xs)
                Text("今日 / 7 日最高利润为历史乐观参照，不构成承诺；制造期间价格波动、挂单深度与实际成交均会造成偏差。")
                    .font(Theme.font(.xs))
                    .foregroundStyle(Theme.faint)
            }
            .listRowBackground(Theme.card)
        }
        .themedList()
        .listStyle(.insetGrouped)
        // 导航标题用产物名（对齐 ItemDetailView）：长列表滚到中段时导航栏仍指示当前配方
        .navigationTitle(it.output.name)
        .navigationBarTitleDisplayMode(.inline)
        // 详情可下拉刷新（§4.2-4 同款）：只调用既有 refresh，与列表页手势心智一致
        .refreshable {
            await app.craft.refresh()
            if app.craft.lastError != nil { refreshErrTick += 1 } else { refreshOkTick += 1 }
        }
        .sensoryFeedback(.success, trigger: refreshOkTick)
        .sensoryFeedback(.error, trigger: refreshErrTick)
    }

    /// 手续费格标签：费率以「手续费·13%」形式放进 micro 标签（值列只留金额；nil fee 由 Fmt.price 兜底「—」）
    private var feeLabel: String {
        guard let rate = resolved.feeRate else { return "手续费" }
        return "手续费·\(Int((rate * 100).rounded()))%"
    }
    private var roiText: String {
        guard resolved.hasEstimate, let roi = resolved.roi else { return "—" }
        return roi >= 0 ? "+\(Int((roi * 100).rounded()))%" : "\(Int((roi * 100).rounded()))%"
    }
    private var roiColor: Color {
        if resolved.hasEstimate, let roi = resolved.roi { return roi >= 0 ? Theme.ok : Theme.danger }
        return Theme.dim
    }
}
