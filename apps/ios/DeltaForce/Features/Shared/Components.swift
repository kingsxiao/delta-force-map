// Components.swift — 行情 / 雷达共用的小部件：信号胶囊、等级角标、分位条、迷你走势、状态头
// 字阶一律走 Theme.font/monoFont（随 Dynamic Type）；含中文的胶囊用默认 design + .monospacedDigit()。
import Charts
import DeltaForceCore
import SwiftUI

struct SignalChip: View {
    let signal: Signal
    var anomaly = false

    var body: some View {
        let color = anomaly ? Theme.warn : Theme.signal(signal)
        // 文案含中文（「⚠ 双源异常」/「买入」等）：默认 design，数字用等宽
        Text(anomaly ? "⚠ 双源异常" : signal.label)
            .font(Theme.font(.micro, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
    }
}

struct GradeBadge: View {
    let grade: Int?
    var body: some View {
        if let grade {
            // 「N级」中文混排：默认 design + 等宽数字；文字色用 levelText（0/nil 降 faint 保对比度）
            Text("\(grade)级")
                .font(Theme.font(.micro, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.levelText(grade))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.level(grade).opacity(0.5), lineWidth: 1))
        }
    }
}

struct PenBadge: View {
    let pen: Int
    var body: some View {
        // 「穿N」中文混排：默认 design + 等宽数字；底色属图形，保留 pen()
        Text("穿\(pen)")
            .font(Theme.font(.micro, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Theme.penText(pen))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Theme.pen(pen).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct CategoryChip: View {
    let text: String
    var body: some View {
        // 同一组件既喂 radar 链路的纯 ASCII（props/acc/protect）也喂 TTK 排行的中文（「三连发」「估」）：
        // 按内容分流——纯 ASCII 用 mono design，含中文用默认 design，一律等宽数字
        Text(text)
            .font(
                text.allSatisfy(\.isASCII)
                    ? Theme.monoFont(.micro, weight: .semibold)
                    : Theme.font(.micro, weight: .semibold)
            )
            .monospacedDigit()
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Theme.card2, in: Capsule())
    }
}

/// 7 天分位条：当前价在 [周低, 周高] 的位置，P25 / P75 刻度。
/// VoiceOver 合并为单一元素并成句转述（分位信息不靠视觉独占）。
struct RankBar: View {
    let item: MarketItem

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.card2).frame(height: 6)
                if let p25 = pos(item.p25), let p75 = pos(item.p75) {
                    Capsule()
                        .fill(Theme.accent.opacity(0.25))
                        .frame(width: max(2, (p75 - p25) * w), height: 6)
                        .offset(x: p25 * w)
                }
                if let cur = pos(item.current) {
                    Circle()
                        .fill(Theme.signal(item.signal))
                        .frame(width: 10, height: 10)
                        .offset(x: cur * w - 5)
                }
            }
            .frame(height: 10)
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
    }

    private func pos(_ v: Double?) -> CGFloat? {
        guard let v, let lo = item.weekLow, let hi = item.weekHigh, hi > lo else { return nil }
        return CGFloat(min(1, max(0, (v - lo) / (hi - lo))))
    }

    /// 成句转述：现价 / 周低—周高分位 / P25–P75 参考区间
    private var a11yLabel: String {
        var parts: [String] = []
        if let cur = item.current { parts.append("现价 \(Fmt.price(cur))") }
        if let cur = item.current, let lo = item.weekLow, let hi = item.weekHigh, hi > lo {
            let pct = Int(((cur - lo) / (hi - lo) * 100).rounded())
            parts.append("处于 7 天周低 \(Fmt.price(lo)) 到周高 \(Fmt.price(hi)) 约 \(pct)% 分位")
        }
        if let p25 = item.p25, let p75 = item.p75 {
            parts.append("P25 到 P75 参考区间 \(Fmt.price(p25)) 到 \(Fmt.price(p75))")
        }
        return parts.joined(separator: "，")
    }
}

/// 迷你走势线（无坐标轴），颜色随信号。纯图形：不独立聚焦，名称由所在行合并 label 转述。
struct Sparkline: View {
    let curve: [CurvePoint]
    var color: Color = Theme.accent

    var body: some View {
        let pts = Array(curve.suffix(84)) // 近 3.5 天足够看形态
        Chart(Array(pts.enumerated()), id: \.offset) { i, p in
            LineMark(x: .value("i", i), y: .value("价", p.price))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(color)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain(pts))
        .accessibilityHidden(true)
    }

    private func yDomain(_ pts: [CurvePoint]) -> ClosedRange<Double> {
        let ys = pts.map(\.price)
        // 空序列（0 点，新上架）：无 LineMark 可渲染、不可见、无害，常量区间豁免
        guard let lo = ys.min() else { return 0...1 }
        guard let hi = ys.max(), hi > lo else {
            // 持平 / 单点：以值为中心 ±10%；v ≤ 0 禁用百分比，改 ±1（防 0…0 退化域与反向区间 crash）
            return lo > 0 ? lo * 0.9 ... lo * 1.1 : (lo - 1) ... (lo + 1)
        }
        let pad = (hi - lo) * 0.1
        return (lo - pad)...(hi + pad)
    }
}

/// 列表头：来源 / 版本 / 年龄 / 通道状态 / 过期提示（TimelineView 让年龄每 30s 自更）
struct FeedHeader: View {
    let feed: FeedModel
    let channel: LiveChannel
    var subtitle: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(dotColor(now: ctx.date))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true) // 状态语义由 statusText 文本承担
                    // 含中文（「演示模式 · 内置样本」）：默认 design + 等宽数字
                    Text(statusText)
                        .font(Theme.font(.xs, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    if feed.isLoading { ProgressView().controlSize(.mini) }
                    Mono(MarketMeta.formatVersionLabel(feed.snapshot?.version), size: 12, weight: .medium, color: Theme.dim)
                }
                if let snap = feed.snapshot {
                    Text("\(MarketMeta.sourceLabel(snap.source)) · 数据 \(MarketMeta.fmtAge(minutes: feed.ageMinutes(now: ctx.date))) 前")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.faint)
                }
                if let subtitle {
                    Text(subtitle).font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                }
                if let err = feed.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.danger)
                }
                if !feed.isDemo, feed.isStale(now: ctx.date), let snap = feed.snapshot {
                    Text(MarketMeta.staleTipText(source: snap.source, ageMin: feed.ageMinutes(now: ctx.date)))
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.warn)
                }
            }
        }
    }

    private var statusText: String {
        if feed.isDemo { return "演示模式 · 内置样本" }
        return channel.state.label
    }

    private func dotColor(now: Date) -> Color {
        if feed.isDemo { return Theme.info }
        if channel.state.isLive, !feed.isDotStale(now: now) { return Theme.ok }
        if feed.lastError != nil { return Theme.danger }
        return Theme.faint
    }
}

/// 成功内容淡入（图片加载完成的瞬跳感收敛）
private struct FadeInModifier: ViewModifier {
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.2)) { shown = true }
            }
    }
}

private extension View {
    func fadeIn() -> some View { modifier(FadeInModifier()) }
}

/// 弹药官方图标（CDN 缩略）：loading 转圈 / 失败可辨识 / 成功淡入；
/// 纯图形 accessibilityHidden——名称由所在行的合并 label 转述。
struct ItemThumb: View {
    let pic: String?
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: MarketMeta.picThumb(pic, width: Int(size * 3))) { phase in
            switch phase {
            case .empty:
                ProgressView().controlSize(.mini)
            case .success(let img):
                img.resizable().scaledToFit().fadeIn()
            case .failure:
                // 失败态：箱子 + 感叹号角标，与「尚未加载」的转圈区分
                ZStack {
                    Image(systemName: "shippingbox").foregroundStyle(Theme.faint)
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(Theme.font(.micro))
                        .foregroundStyle(Theme.danger)
                        .offset(x: 6, y: -6)
                }
            default:
                Image(systemName: "shippingbox").foregroundStyle(Theme.faint)
            }
        }
        .frame(width: size, height: size)        .background(Theme.card2, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

struct StatCell: View {
    let label: String
    let value: String
    var color: Color = Theme.txStrong

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.font(.micro)).foregroundStyle(Theme.faint)
            Mono(value, size: 14, color: color) // 随基础层 ScaledMetric 自动缩放
                .lineLimit(1)
                .minimumScaleFactor(0.75) // 窄屏大数兜底
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
