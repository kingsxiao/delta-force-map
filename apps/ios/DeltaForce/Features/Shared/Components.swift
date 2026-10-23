// Components.swift — 共享小部件：信号胶囊、等级角标、分位条、迷你走势、状态头、下拉筛选、
// 状态胶囊 / 四格行 / 重试错误行 / 连接状态点（DESIGN.md §3 C1–C11）
// 字阶一律走 Theme.font/monoFont（随 Dynamic Type）；含中文的胶囊用默认 design + .monospacedDigit()。
// 徽标四族统一配方（§1.4）：文字=语义色、底=同色 12%、描边=同色 40%、内边距 h8/v2；
// 圆角按语义二分——状态类（SignalChip / StatusChip）=胶囊，属性类（GradeBadge / PenBadge / CategoryChip）=方角 radiusBadge。
import Charts
import DeltaForceCore
import SwiftUI

struct SignalChip: View {
    let signal: Signal
    var anomaly = false

    var body: some View {
        let color = anomaly ? Theme.warn : Theme.signal(signal)
        // 文案含中文（「双源异常」/「买入」等）：默认 design，数字用等宽
        HStack(spacing: 3) {
            if anomaly {
                // 异常态图标走 SF Symbol（C3）：U+26A0 无变体选择符可能渲染成彩色 emoji，破坏「信号色唯一来源 Theme」纪律；
                // 尺寸跟 micro 字阶走（§6.1-3 不裸设字号），警示语义由「双源异常」文本承担
                Image(systemName: "exclamationmark.triangle")
                    .font(Theme.font(.micro, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(anomaly ? "双源异常" : signal.label)
                .font(Theme.font(.micro, weight: .bold))
                .monospacedDigit()
        }
        // 徽标一律单行：宽度吃紧时保持理想宽，挤压由同行名称截断承担（否则会被压成单字竖排）
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
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
                // 徽标一律单行：宽度吃紧时保持理想宽，挤压由同行名称截断承担（否则会被压成单字竖排）
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(Theme.levelText(grade))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                // C1：补 12% 底（原仅描边），描边统一 40%；底色 / 描边属图形，保留 level() 原色
                .background(Theme.level(grade).opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusBadge))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusBadge).stroke(Theme.level(grade).opacity(0.4), lineWidth: 1))
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
            // 徽标一律单行：宽度吃紧时保持理想宽，挤压由同行名称截断承担（否则会被压成单字竖排）
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Theme.penText(pen))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Theme.pen(pen).opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusBadge))
            // C1：补 40% 描边（原仅底）
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusBadge).stroke(Theme.pen(pen).opacity(0.4), lineWidth: 1))
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
            // 徽标一律单行：宽度吃紧时保持理想宽，挤压由同行名称截断承担（否则会被压成单字竖排）
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            // C1：card2 实底 → dim 色 10% 底 + 30% 描边（最轻的一族，比状态 / 等级徽标再降一档）；
            // 属性类徽标取方角 radiusBadge（§1.4 圆角语义二分）
            .background(Theme.dim.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.radiusBadge))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusBadge).stroke(Theme.dim.opacity(0.3), lineWidth: 1))
    }
}

/// 状态语义胶囊（C2 / §1.4）：文字=tint、底=tint 12%、描边=tint 40%、胶囊圆角、h8/v2。
/// 供手册时间窗标签（扫货 / 囤货…）与雷达态势计数（买入 N / 卖出 N…）等纯状态标签复用，
/// 与属性类方角徽标（等级 / 穿透 / 分类）区分。单行纪律与四族同款。
struct StatusChip: View {
    let text: String
    var tint: Color = Theme.dim

    var body: some View {
        // 文案多为中文混排（「买入 12」）：默认 design + 等宽数字
        Text(text)
            .font(Theme.font(.micro, weight: .bold))
            .monospacedDigit()
            // 徽标一律单行：宽度吃紧时保持理想宽，挤压由同行名称截断承担（否则会被压成单字竖排）
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
    }
}

/// 下拉筛选的一个选项（值 + 展示文案 + 可选菜单行图标）
struct FilterOption<ID: Hashable>: Identifiable {
    let id: ID
    let label: String
    var icon: String? = nil
}

/// 下拉筛选（chip 触发 + 原生 Menu 浮层）：
/// 浮层的定位 / 选中 checkmark / 背景模糊全部交给系统 Menu（与 Apple 自家 App 的筛选菜单同源），
/// 定制集中在触发器 chip 上——caption 微字 + 当前值半粗 + 下箭头，card2 底 / line 描边，
/// 偏离默认值时 caption 与描边点亮 accent（对齐 Things / Linear 的 active filter chip 心智）。
struct FilterMenu<ID: Hashable>: View {
    let caption: String
    let options: [FilterOption<ID>]
    @Binding var selection: ID
    /// 与该值相同时视为「默认」，chip 不点亮；nil = 永不点亮
    var defaultId: ID? = nil

    private var active: Bool {
        guard let defaultId else { return false }
        return selection != defaultId
    }

    var body: some View {
        Menu {
            Picker(caption, selection: $selection) {
                ForEach(options) { opt in
                    if let icon = opt.icon {
                        Label(opt.label, systemImage: icon).tag(opt.id)
                    } else {
                        Text(opt.label).tag(opt.id)
                    }
                }
            }
        } label: {
            FilterChipLabel(
                caption: caption,
                value: options.first(where: { $0.id == selection })?.label ?? "—",
                active: active
            )
        }
    }
}

/// FilterMenu 的触发器 chip（同族观感：胶囊 / card2 底 / 1px 描边，字阶随 Dynamic Type）。
/// C8：ViewThatFits 降级——正常 caption+value 单行；特大字号 / 窄屏放不下时 value 允许折 2 行，
/// 不再把关键值压成「护甲 …」截断（AX 韧性，DESIGN.md §7-6）
private struct FilterChipLabel: View {
    let caption: String
    let value: String
    let active: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(valueLineLimit: 1)
            content(valueLineLimit: 2)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.card2))
        .overlay(Capsule().strokeBorder(active ? Theme.accent.opacity(0.45) : Theme.line, lineWidth: 1))
    }

    private func content(valueLineLimit: Int) -> some View {
        HStack(spacing: 7) {
            Text(caption)
                .font(Theme.font(.micro, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.faint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false) // caption 恒单行，宽度压力全部交给 value 折行
            Text(value)
                .font(Theme.font(.sm, weight: .semibold))
                .foregroundStyle(Theme.txStrong)
                .lineLimit(valueLineLimit)
                .multilineTextAlignment(.leading)
            Image(systemName: "chevron.down")
                .font(Theme.font(.micro, weight: .semibold)) // SF Symbol 走默认 design（§6.1-3：monoFont 仅限纯 ASCII 文本）
                .foregroundStyle(active ? Theme.accent : Theme.faint)
        }
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

/// 数据源错误横幅：仅在有错误要展示时渲染（正常态整行退场、零占位）。
/// 供行情 / 雷达 / 制造页列表顶部共用；无快照的首拉失败建议交给页内
/// RetryErrorRow（带重试出口），调用方以「有快照才显示」来去重同屏双份文案。
struct FeedErrorBanner: View {
    let message: String?

    var body: some View {
        if let message {
            // danger 8% 底胶囊行（C7 配方）：断网 / 后台刷新失败时在列表顶部一眼可见
            Label(message, systemImage: "exclamationmark.triangle")
                .font(Theme.font(.xs))
                .foregroundStyle(Theme.danger)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.danger.opacity(0.08), in: Capsule())
        }
    }
}

/// 连接状态小组件（C11）：8pt 圆点 + state.label 文案，供设置页「连接状态」行使用。
/// 着色规则：`state.isLive && !stale` → ok；`error` → danger；其余 → faint。
/// LiveChannel.State 六态没有 error 态，故签名必须带 `error`/`stale` 两个带默认值参数承载这两个维度。
struct ConnectionDot: View {
    let state: LiveChannel.State
    /// feed.lastError != nil 时圆点转 danger
    var error: Bool = false
    /// feed.isDotStale(now:) 为 true 时 live 也不显 ok
    var stale: Bool = false
    /// 是否显示状态文字（如「实时推送」）。设置页「连接状态」行要文字；
    /// 页头只留圆点（状态语义转由圆点的 a11y label 承担）
    var showLabel: Bool = true

    private var tint: Color {
        if state.isLive, !stale { return Theme.ok }
        if error { return Theme.danger }
        return Theme.faint
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                // 文字隐藏时状态语义由圆点自身承担；显示文字时圆点让位（避免读两遍）
                .accessibilityLabel(state.label)
                .accessibilityHidden(showLabel)
            if showLabel {
                // 含中文状态文案：默认 design + 等宽数字
                Text(state.label)
                    .font(Theme.font(.xs, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.dim)
            }
        }
    }
}

/// 带重试的错误行（C10）：错误胶囊（C7 同款样式）+ 重试按钮；`busy` 为 true 时按钮禁用并显示内联进度，
/// 消除「点了没反应」的空转。雷达 / 行情 / 设置的首拉失败态共用；旧 FeedErrorView（原 AmmoView 内）
/// 已按 DESIGN.md §3 C10 安全序在各页换用后删除。
struct RetryErrorRow: View {
    let message: String
    let retry: () -> Void
    var busy = false

    var body: some View {
        VStack(spacing: 10) {
            Label(message, systemImage: "wifi.exclamationmark")
                .font(Theme.font(.xs))
                .foregroundStyle(Theme.danger)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.danger.opacity(0.08), in: Capsule())
            Button {
                if !busy { retry() }
            } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.mini) }
                    Text("重试").font(Theme.font(.sm, weight: .semibold))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large) // §7-8 触控目标 ≥44pt：重试是错误态唯一出口，bordered 默认 ~34pt 偏小
            .disabled(busy)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// 成功内容淡入（图片加载完成的瞬跳感收敛；时长走 durFast 令牌，Reduce Motion 下直接呈现）
private struct FadeInModifier: ViewModifier {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.easeOut(duration: Theme.durFast)) { shown = true }
                }
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
        .frame(width: size, height: size)
        .background(Theme.card2, in: RoundedRectangle(cornerRadius: Theme.radiusTile))
        .accessibilityHidden(true)
    }
}

/// 统计格：label 微字 + 等宽数值；`emphasis: .hero` 时数值升 lead 档并随宽缩至 0.8（C4「主数字立权」用），
/// 默认 `.plain` 与历史行为逐像素一致（size 14 / relativeTo .body / minimumScaleFactor 0.75）
struct StatCell: View {
    /// 数值强调档（C4）：plain=次级统计格（现状）；hero=行内主角数字（升 MonoStep.lead + 0.8 缩放兜底）
    enum Emphasis {
        case plain
        case hero
    }

    let label: String
    let value: String
    var color: Color = Theme.txStrong
    var emphasis: Emphasis = .plain

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.font(.micro)).foregroundStyle(Theme.faint)
            switch emphasis {
            case .plain:
                Mono(value, size: 14, color: color) // 随基础层 ScaledMetric 自动缩放（兼容通道，观感与历史一致）
                    .lineLimit(1)
                    .minimumScaleFactor(0.75) // 窄屏大数兜底
            case .hero:
                Mono(value, step: .lead, color: color, minScale: 0.8) // 主数字立权：lead 档 + 0.8 缩放兜底
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 统计四格行（C5）：宽度足够时一行 4 列，窄屏 / 特大字号自动折成 2×2 两行（ViewThatFits 降级）。
/// 自 ItemDetailView 私有 statQuad 提为共享（DESIGN.md §3 C5）：详情页与 GunDetail 头部共用同一韧性。
struct StatQuadRow: View {
    let a: StatCell
    let b: StatCell
    let c: StatCell
    let d: StatCell

    init(_ a: StatCell, _ b: StatCell, _ c: StatCell, _ d: StatCell) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { a; b; c; d }
            VStack(alignment: .leading, spacing: 8) {
                HStack { a; b }
                HStack { c; d }
            }
        }
    }
}
