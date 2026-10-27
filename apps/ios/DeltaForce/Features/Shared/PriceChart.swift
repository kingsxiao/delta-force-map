// PriceChart.swift — 7 天价格大图：P25 / P75 参考线、现价点 + 数值标注、拖动查值（对齐网页端 PriceChart.vue）
// P1 逐点触感 / P2 气泡淡入 / P3 字阶收编 / P4 VO 逐点听值（DESIGN.md §3，iOS 17 API）
import Charts
import DeltaForceCore
import SwiftUI

struct PriceChart: View {
    let item: MarketItem

    /// 拖动查值选中的点（nil = 未拖动）；本页局部 @State，抬手即清
    @State private var selected: Pt?
    /// VO 逐点听值游标（P4）：-1 = 未开始（从最新点起步），否则为 points 下标；
    /// 只服务 accessibilityValue，不与拖动 selected 互扰
    @State private var voCursor = -1

    private struct Pt: Identifiable {
        let id: String
        let date: Date
        let price: Double
    }

    /// 时间轴 / 气泡固定北京时区：key 本身是北京墙钟数字（keyToDate 按北京解析），
    /// 按设备时区格式化会让海外设备显示出与 key 不一致的小时（日期还会偏移），
    /// 与同页 ETA 的北京日历口径（friendlyClock）也不一致——统一走 SellEta 的北京时区
    private static let bjFullStyle: Date.FormatStyle = {
        var f = Date.FormatStyle.dateTime.month().day().hour().minute()
        f.timeZone = SellEtaEngine.beijing.timeZone
        return f
    }()
    /// X 轴日标签（仅月日，同上固定北京时区）
    private static let bjDayStyle: Date.FormatStyle = {
        var f = Date.FormatStyle.dateTime.month(.defaultDigits).day()
        f.timeZone = SellEtaEngine.beijing.timeZone
        return f
    }()

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
                        Mono("P25 \(Fmt.price(p25))", step: .micro, color: Theme.ok) // P3：纯 ASCII 收编 micro 档
                    }
            }
            if let p75 = item.p75 {
                RuleMark(y: .value("P75", p75))
                    .foregroundStyle(Theme.danger.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Mono("P75 \(Fmt.price(p75))", step: .micro, color: Theme.danger) // P3：纯 ASCII 收编 micro 档
                    }
            }
            if let cur = item.current, let last = pts.last {
                PointMark(x: .value("时间", last.date), y: .value("现价", cur))
                    .foregroundStyle(Theme.txStrong)
                    .symbolSize(40)
                    // 现价数值标注：不必再对照 Y 轴估读（P3 收编 micro 档，与气泡数字同源）
                    .annotation(position: .top, alignment: .trailing) {
                        Mono(Fmt.price(cur), step: .micro, weight: .bold)
                    }
            }
            if let sel = selected {
                RuleMark(x: .value("时间", sel.date))
                    .foregroundStyle(Theme.dim.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sel.date.formatted(Self.bjFullStyle))
                                .font(Theme.font(.micro))
                                .foregroundStyle(Theme.faint)
                            Mono(Fmt.price(sel.price), step: .micro, weight: .bold) // P3：与现价标注同源同档
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusBadge))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusBadge).stroke(Theme.line, lineWidth: 1))
                    }
            }
        }
        .chartYScale(domain: yDomain(pts))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel(format: Self.bjDayStyle, centered: false)
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
        // P4：VO 逐点听值——上下滑动逐点朗读「M月d日 HH:mm，价格 X」，起点为最新点；
        // 值经 accessibilityValue 呈现（状态更新后 VoiceOver 自动播报新值），摘要 label 保留兜底
        .accessibilityHint("上下滑动逐点朗读价格")
        .accessibilityValue(voValue(pts))
        .accessibilityAdjustableAction { direction in
            let last = pts.count - 1
            guard last >= 0 else { return }
            let cur = voCursor < 0 ? last : voCursor // 未开始 → 最新点起步
            switch direction {
            case .increment: voCursor = min(last, cur + 1)
            case .decrement: voCursor = max(0, cur - 1)
            @unknown default: break
            }
        }
        // P1：拖动查值逐点触感——选点跨数据点时轻「咯哒」；condition 必须带：onEnded 把 selected 置 nil，
        // selected?.id 从非 nil 变 nil 同样是一次 trigger 变化，不带条件抬手会多一声咯哒（trigger 绑图内局部 State）
        .sensoryFeedback(.selection, trigger: selected?.id) { _, new in new != nil }
        // P2：十字线气泡淡入——选点变化时 animFast 档过渡（Charts 对 annotation 过渡支持有限，
        // 系统不产生过渡时按 DESIGN.md §3 P2 允许降级为瞬现）；RM 门内建于 .motion（置 nil 即跳过，
        // 触感不受影响——触感不属动效，DESIGN.md §7-9 口径）
        .motion(Theme.animFast, value: selected?.id)
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

    /// VO 游标当前听值（P4）：「M月d日 HH:mm，价格 X」；未开始 / 越界回落到最新点
    private func voValue(_ pts: [Pt]) -> String {
        let idx = pts.indices.contains(voCursor) ? voCursor : pts.count - 1
        guard pts.indices.contains(idx) else { return "暂无数据" }
        let p = pts[idx]
        return "\(p.date.formatted(Self.bjFullStyle))，价格 \(Fmt.price(p.price))"
    }
}
