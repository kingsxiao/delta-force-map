// PriceChart.swift — 7 天价格大图：P25 / P75 参考线、现价点 + 数值标注、拖动查值（对齐网页端 PriceChart.vue）
import Charts
import DeltaForceCore
import SwiftUI

struct PriceChart: View {
    let item: MarketItem

    /// 拖动查值选中的点（nil = 未拖动）；本页局部 @State，抬手即清
    @State private var selected: Pt?

    private struct Pt: Identifiable {
        let id: String
        let date: Date
        let price: Double
    }

    private var points: [Pt] {
        item.curve.compactMap { p in
            guard let d = SellEtaEngine.keyToDate(p.key) else { return nil }
            return Pt(id: p.key, date: d, price: p.price)
        }
    }

    var body: some View {
        let pts = points
        if pts.isEmpty {
            // 空序列在此视图层拦截：显示空态而非空坐标系（yDomain 无需再处理空序列）
            ContentUnavailableView("暂无行情数据", systemImage: "chart.xyaxis.line")
        } else {
            chart(pts)
        }
    }

    private func chart(_ pts: [Pt]) -> some View {
        Chart {
            ForEach(pts) { p in
                AreaMark(x: .value("时间", p.date), y: .value("价格", p.price))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", p.date), y: .value("价格", p.price))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
            if let p25 = item.p25 {
                RuleMark(y: .value("P25", p25))
                    .foregroundStyle(Theme.ok.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("P25 \(Fmt.price(p25))")
                            .font(Theme.monoFont(.micro)) // 纯 ASCII：mono design
                            .monospacedDigit()
                            .foregroundStyle(Theme.ok)
                    }
            }
            if let p75 = item.p75 {
                RuleMark(y: .value("P75", p75))
                    .foregroundStyle(Theme.danger.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("P75 \(Fmt.price(p75))")
                            .font(Theme.monoFont(.micro)) // 纯 ASCII：mono design
                            .monospacedDigit()
                            .foregroundStyle(Theme.danger)
                    }
            }
            if let cur = item.current, let last = pts.last {
                PointMark(x: .value("时间", last.date), y: .value("现价", cur))
                    .foregroundStyle(Theme.txStrong)
                    .symbolSize(40)
                    // 现价数值标注：不必再对照 Y 轴估读
                    .annotation(position: .top, alignment: .trailing) {
                        Mono(Fmt.price(cur), size: 12, weight: .bold)
                    }
            }
            if let sel = selected {
                RuleMark(x: .value("时间", sel.date))
                    .foregroundStyle(Theme.dim.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sel.date.formatted(.dateTime.month().day().hour().minute()))
                                .font(Theme.font(.micro))
                                .foregroundStyle(Theme.faint)
                            Mono(Fmt.price(sel.price), size: 12, weight: .bold)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
                    }
            }
        }
        .chartYScale(domain: yDomain(pts))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: false)
                    .foregroundStyle(Theme.faint)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel().foregroundStyle(Theme.faint)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in selected = nearestPt(x: g.location.x, proxy: proxy, geo: geo, pts: pts) }
                            .onEnded { _ in selected = nil }
                    )
            }
        }
        .frame(height: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11ySummary)
    }

    /// 拖动查值：把拖动位置 x 换算到最近的数据点
    /// （plotFrame 是 Anchor<CGRect>，须经 GeometryProxy 下标解析回几何坐标，再换图表坐标）
    private func nearestPt(x: CGFloat, proxy: ChartProxy, geo: GeometryProxy, pts: [Pt]) -> Pt? {
        guard let frameAnchor = proxy.plotFrame else { return nil }
        let frame = geo[frameAnchor]
        guard frame.width > 0 else { return nil }
        guard let date = proxy.value(atX: x - frame.minX, as: Date.self) else { return nil }
        return pts.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private func yDomain(_ pts: [Pt]) -> ClosedRange<Double> {
        var ys = pts.map(\.price)
        if let c = item.current { ys.append(c) }
        // 持平 / 单点：以值为中心 ±10%；价格 ≤0 时禁用百分比，改 ±1（防 0…0 退化域与反向区间 crash）
        guard let lo = ys.min(), let hi = ys.max(), hi > lo else {
            let v = ys.min() ?? 0
            return v > 0 ? v * 0.9 ... v * 1.1 : (v - 1) ... (v + 1)
        }
        let pad = (hi - lo) * 0.12
        return max(0, lo - pad)...(hi + pad)
    }

    /// 整图 VoiceOver 摘要（分位细节由 P25/P75 参考线与 StatCell 承担）
    private var a11ySummary: String {
        var parts: [String] = []
        if let cur = item.current { parts.append("现价 \(Fmt.price(cur))") }
        if let lo = item.weekLow { parts.append("周低 \(Fmt.price(lo))") }
        if let hi = item.weekHigh { parts.append("周高 \(Fmt.price(hi))") }
        parts.append("近 7 天价格走势图")
        return parts.joined(separator: "，")
    }
}
