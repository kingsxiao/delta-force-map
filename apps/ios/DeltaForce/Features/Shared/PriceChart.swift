// PriceChart.swift — 7 天价格大图：P25 / P75 参考线、现价点 + 数值标注、拖动查值 + 图上方固定读数行（对齐网页端 PriceChart.vue）
// P1 逐点触感 / P2 十字线淡入（查值气泡改为固定读数行，见 readout）/ P3 字阶收编 / P4 VO 逐点听值（DESIGN.md §3，iOS 17 API）
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
    /// 查值读数专用（终审）：月 / 日 / 时两位补零（分本就两位），同上固定北京时区。拖动逐点扫过
    /// 「10月8日 9:05」↔「10月28日 14:05」这类 1 位 ↔ 2 位数字时标签宽度恒定，图上方读数行的
    /// 主数字不再随手指水平漂移（思路库「数字列 tabular + 预留最大位宽，杜绝列宽跳动」；宽度恒定
    /// 还需配合 readout 的 .monospacedDigit()）。VO 听值仍走 bjFullStyle：补零文本会被读成
    /// 「零八月零八日」，朗读以自然口语为先、视觉以恒宽为先，两者各取所需
    private static let bjFixedStyle: Date.FormatStyle = {
        var f = Date.FormatStyle.dateTime.month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits)
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
            // 空序列在此视图层拦截：显示空态而非空坐标系（yDomain 无需再处理空序列）。
            // 空态给一条出路（思路库）：宿主详情页已挂两路 refreshable（ItemDetailView），描述行把这条路
            // 说出来——「没有」之外还告诉用户下一步，不留死胡同；无按钮是因为重试动作就是下拉手势本身
            ContentUnavailableView {
                Label("暂无行情数据", systemImage: "chart.xyaxis.line")
            } description: {
                Text("下拉刷新可重试")
            }
        } else {
            // 读数行钉在图上方、图表在下（思路库「移动端查值读数放固定位置」）：拖动的手指永远在读数下方，不遮挡数值
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                readout(pts)
                chart(pts)
            }
        }
    }

    /// 固定查值读数行：原 RuleMark annotation 气泡跟随触点，拖动时恰被手指盖住、靠两侧还会被图缘裁切；改为图上方
    /// 常驻一行。空闲态与 web .pc-readout 同口径（PriceChart.vue:161-178：常驻「现在 · 末点现价」）——
    /// 读数位永远有决策数字，不再是纯操作提示；查值中整行切「时间 · 价格」、主数字转 accent（探针语义，
    /// §1.2 accent 合法场景），空闲回落 txStrong（web .pc-readout b 同色）。操作提示退到行尾 faint 微字：
    /// 触屏没有 web 的 crosshair 光标自明查值手势，提示不能删，但不得占用数字主位。两态同构（label + 数字
    /// 同行高，拖动不推挤图表高度）；空闲现价取 item.current（与图内「现在」标注同源），缺价回落末点曲线价。
    /// 纯视觉读数：VO 用户走图表 adjustableAction 逐点听值（P4），本行 accessibilityHidden 防重复播报。
    private func readout(_ pts: [Pt]) -> some View {
        let shown = selected ?? pts.last
        let price = selected == nil ? (item.current ?? shown?.price) : shown?.price
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            if let shown {
                // 标签色随态分层对齐 web：空闲整行 faint、查值中 .on 提 dim（PriceChart.vue:227,232）。
                // 查值态走 bjFixedStyle + .monospacedDigit()：日期标签宽度恒定（见该样式注释），
                // 逐点拖动时数字原地刷新、位置不漂移；空闲态「现在」恒宽本就无需处理
                Text((selected == nil ? "现在" : shown.date.formatted(Self.bjFixedStyle)) + " ·")
                    .font(Theme.font(.micro))
                    .monospacedDigit()
                    .foregroundStyle(selected == nil ? Theme.faint : Theme.dim)
                    .lineLimit(1)
                    // 窄屏 / AX 特大字号时时间整体缩排而非截成「10月28…」：「何时」是查值语义的一半，
                    // 主数字已有 layoutPriority(1) 保宽，这里只与提示行（不显示）争剩余空间
                    .minimumScaleFactor(0.7)
                if let price {
                    // 主数字立权（layoutPriority）：宽度吃紧时先保数字理想宽，截断由行尾提示承担
                    Mono(Fmt.price(price), step: .sub, weight: .bold,
                         color: selected == nil ? Theme.txStrong : Theme.accent)
                        .layoutPriority(1)
                }
            }
            if selected == nil {
                Spacer(minLength: Theme.Space.sm)
                Text("按住拖动查值")
                    .font(Theme.font(.micro))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(Theme.animFast, value: selected == nil)
        .accessibilityHidden(true)
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
                    // 标注挂左端（对齐 web：分位标注同挂线左端 text-anchor=start，PriceChart.vue:208-209）：
                    // 现价标注在右缘（trailing），现价贴近 P75 运行（区间上四分位，卖出参考最相关的场景）
                    // 时两个标注 y 趋近，若同挂右侧必叠印；左右分置后 P25/P75 上下错开、右缘归现价独占
                    .annotation(position: .top, alignment: .leading) {
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
                // 十字线保留；读数不再贴指针（气泡已移到图上方固定读数行 readout，防手指遮挡）
                RuleMark(x: .value("时间", sel.date))
                    .foregroundStyle(Theme.dim.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                // 选中点强调圈（对齐 web 十字线的 pc-xh circle：宿主卡面填底 + accent 描边空心圆，
                // 双端同语义——MOTION.md 原则 4）：纵向虚线只回答「何时」，圈把「哪一点」钉在曲线上，
                // 拖动查值的回声在指尖下即刻成形，与图上方读数行的数字同源同点
                PointMark(x: .value("时间", sel.date), y: .value("价格", sel.price))
                    .symbol { Circle().fill(Theme.card).stroke(Theme.accent, lineWidth: 2) }
                    .symbolSize(40) // 与现价点同径：同为「点」，选中态只多一圈 accent 轮廓
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
                // Y 轴是价格刻度（纯数字）：收编等宽微档——web 端图内刻度即 mono（「与查值读数同族」），
                // 且图内 P25/P75/现价标注已 micro 等宽，刻度不同族会出现图内两套数字字体
                AxisValueLabel().font(Theme.monoFont(.micro)).foregroundStyle(Theme.faint)
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
        // P2：十字线淡入——选点变化时 animFast 档过渡（Charts 对 RuleMark 进出过渡支持有限，系统不产生过渡时按
        // DESIGN.md §3 P2 允许降级为瞬现）；查值读数的淡入由 readout 自己承担。RM 门内建于 .motion（置 nil 即跳过，
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
