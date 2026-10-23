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

    private var profitColor: Color {
        if let p = item.profit { return p >= 0 ? Theme.ok : Theme.danger }
        return Theme.dim
    }

    var body: some View {
        List {
            // 头部：图标 / 名称 / 徽标 / 主角数字（时利 hero）
            Section {
                HStack(spacing: Theme.Space.md) {
                    ItemThumb(pic: item.output.pic, size: 52)
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        HStack(spacing: 6) {
                            Text(item.output.name)
                                .font(Theme.font(.lg, weight: .semibold))
                                .foregroundStyle(Theme.txStrong)
                                .lineLimit(2)
                            if item.output.count > 1 {
                                Text("×\(item.output.count)")
                                    .font(Theme.monoFont(.xs, weight: .semibold))
                                    .foregroundStyle(Theme.dim)
                            }
                        }
                        HStack(spacing: 6) {
                            CategoryChip(text: placeLabel)
                            GradeBadge(grade: item.output.grade)
                            if let lv = item.requiredLevel {
                                StatusChip(text: "Lv.\(lv) 解锁", tint: Theme.dim)
                            }
                        }
                    }
                }
                .padding(.vertical, Theme.Space.xs)
                if let p = item.profitPerHour {
                    // 主角数字（§1.1）：详情页唯一 hero
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Mono(p >= 0 ? "+\(Fmt.price(p))" : Fmt.price(p), step: .hero, color: profitColor)
                        Text("每小时 · \(item.periodLabel ?? "—")")
                            .font(Theme.font(.xs))
                            .foregroundStyle(Theme.faint)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("每小时利润 \(Fmt.price(p))，制造耗时 \(item.periodLabel ?? "未知")")
                } else {
                    Label("材料或产出缺价（\(item.missingPriceCount) 项），利润无法估算", systemImage: "exclamationmark.triangle")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.warn)
                }
            }
            .listRowBackground(Theme.card)

            // 利润拆解（缺价时整节退场）
            if item.hasEstimate {
                Section("利润拆解") {
                    StatQuadRow(
                        StatCell(label: "产出收入", value: Fmt.price(item.revenue), color: Theme.txStrong),
                        StatCell(label: "手续费", value: feeText, color: Theme.dim),
                        StatCell(label: "材料成本", value: Fmt.price(item.cost), color: Theme.dim),
                        StatCell(label: "净利润", value: Fmt.price(item.profit), color: profitColor, emphasis: .hero)
                    )
                    .padding(.vertical, Theme.Space.xs)
                    // 公式行：与网页端展开区同文案；正文含实义金额，走等宽数字（同 MethodNote 口径）
                    Text("利润 = 收入 \(Fmt.price(item.revenue)) − 手续费 \(Fmt.price(item.fee)) − 材料 \(Fmt.price(item.cost))；收入 = 产出单价 \(Fmt.price(item.output.price)) × \(item.output.count)。")
                        .font(Theme.font(.xs))
                        .monospacedDigit()
                        .foregroundStyle(Theme.faint)
                }
                .listRowBackground(Theme.card)
            }

            // 材料清单
            Section("材料 · \(item.materials.count) 项") {
                ForEach(item.materials) { m in
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

            // 参照区间
            Section("参照") {
                StatQuadRow(
                    StatCell(label: "今日最高", value: Fmt.price(item.todayMaxProfit), color: Theme.warn),
                    StatCell(label: "7 日最高", value: Fmt.price(item.sevenDayMaxProfit), color: Theme.warn),
                    StatCell(label: "成本回报", value: roiText, color: roiColor),
                    StatCell(label: "产出单价", value: Fmt.price(item.output.price), color: Theme.txStrong)
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
        .navigationTitle(item.output.name)
        .navigationBarTitleDisplayMode(.inline)
        // 详情可下拉刷新（§4.2-4 同款）：只调用既有 refresh，与列表页手势心智一致
        .refreshable {
            await app.craft.refresh()
            if app.craft.lastError != nil { refreshErrTick += 1 } else { refreshOkTick += 1 }
        }
        .sensoryFeedback(.success, trigger: refreshOkTick)
        .sensoryFeedback(.error, trigger: refreshErrTick)
    }

    private var feeText: String {
        guard let fee = item.fee else { return "—" }
        var s = Fmt.price(fee)
        if let rate = item.feeRate { s += "（\(Int((rate * 100).rounded()))%）" }
        return s
    }
    private var roiText: String {
        guard let roi = item.roi else { return "—" }
        return roi >= 0 ? "+\(Int((roi * 100).rounded()))%" : "\(Int((roi * 100).rounded()))%"
    }
    private var roiColor: Color {
        if let roi = item.roi { return roi >= 0 ? Theme.ok : Theme.danger }
        return Theme.dim
    }
}
