// Components.swift — 共享小部件：信号胶囊、等级角标、分位条、迷你走势、状态头、下拉筛选、
// 状态胶囊 / 四格行 / 重试错误行 / 连接状态点（DESIGN.md §3 C1–C11）；
// 共享动效层：骨架屏四件套 / .contentSwap / .swapTransition / .numericChange / MiniSpin /
// PressableButtonStyle（MOTION.md §2.2）；
// 回顶浮动钮三件套：scrollToTop 帮助函数 / BackTopButton / ListTopAwayProbe
// （行情与 TTK 两页逐字重复的私有实现收口，雷达 / 制造的筛选回顶同走帮助函数）
// 字阶一律走 Theme.font/monoFont（随 Dynamic Type）；含中文的胶囊用默认 design + .monospacedDigit()。
// 徽标四族统一配方（§1.4）：文字=语义色、底=同色 12%、描边=同色 40%、内边距 h8/v2；配方执行体为 badgeCoat
// （系统「增强对比度」下自动去半透明底、提描边）。
// 圆角按语义二分——状态类（SignalChip / StatusChip）=胶囊，属性类（GradeBadge / PenBadge / CategoryChip）=方角 radiusBadge。
import Charts
import DeltaForceCore
import SwiftUI

/// 徽标统一涂层（§1.4 配方的执行体 + AX 高对比分支）：标准态 = tint×fill 底（默认 12%）+ tint×stroke 描边
/// （默认 40%），渲染与原 background+overlay 两行逐字节一致；系统「增强对比度」开启时去半透明底、描边提亮到
/// stroke+0.4（思路库「高对比令牌·徽标去半透明底」）。为什么去底：半透明涂层的实际底色是 tint 与卡面的混色，
/// 文字令牌提亮后混色对比随底面漂移、不可控；去底让语义色文字直贴卡片面（对比只取决于文字色），描边提亮保轮廓。
/// @Environment 必须是修饰符结构体的存储属性（Theme.swift MotionModifier 注释实测口径），故不做 View 扩展体内局部读取。
struct BadgeCoatModifier<S: Shape>: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let tint: Color
    let shape: S
    let fill: Double
    let stroke: Double

    func body(content: Content) -> some View {
        let increased = contrast == .increased
        content
            .background(increased ? Color.clear : tint.opacity(fill), in: shape)
            .overlay { shape.stroke(tint.opacity(increased ? min(1, stroke + 0.4) : stroke), lineWidth: 1) }
    }
}

extension View {
    /// 徽标涂层挂载：状态类 `.badgeCoat(color, in: Capsule())`、属性类 `.badgeCoat(color, in: RoundedRectangle(cornerRadius: Theme.radiusBadge))`；
    /// CategoryChip 传 fill 0.10 / stroke 0.3（最轻一族）。tint 只收 Theme 语义色 / 等级色（图形用原色，文字色另走 levelText/penText）
    func badgeCoat(_ tint: Color, in shape: some Shape, fill: Double = 0.12, stroke: Double = 0.4) -> some View {
        modifier(BadgeCoatModifier(tint: tint, shape: shape, fill: fill, stroke: stroke))
    }
}

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
        .badgeCoat(color, in: Capsule()) // 状态类=胶囊；高对比去底见 BadgeCoatModifier
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
                // C1：12% 底 + 40% 描边（原仅描边）；底色 / 描边属图形，保留 level() 原色；属性类=方角 radiusBadge
                .badgeCoat(Theme.level(grade), in: RoundedRectangle(cornerRadius: Theme.radiusBadge))
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
            // C1：12% 底 + 40% 描边（原仅底）；属性类=方角 radiusBadge
            .badgeCoat(Theme.pen(pen), in: RoundedRectangle(cornerRadius: Theme.radiusBadge))
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
            .badgeCoat(Theme.dim, in: RoundedRectangle(cornerRadius: Theme.radiusBadge), fill: 0.10, stroke: 0.3)
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
            .badgeCoat(tint, in: Capsule()) // 状态类=胶囊
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
        // 激活三件套与 web .chip.on 同口径（AmmoMarketView.vue:1435 / CraftView.vue:750 /
        // MarketRadarView.vue:586：accent 文字 + accent-dim 描边 + accent-bg 底）——原先描边用
        // accent.opacity(0.45) 裸值、底不换装，与制造台 chip（CraftView 已用 accentBg）并置时是
        // 第三种激活长相；描边 / 底一律走令牌（T4：accentDim / accentBg 仅供描边与强调底）。
        // 选中三态（caption / 箭头字色 + 描边 + 底）animFast 渐变、无位移（MOTION.md §3-B chip
        // 选中档）；RM 门内建于 .motion
        .background(Capsule().fill(active ? Theme.accentBg : Theme.card2))
        .overlay(Capsule().strokeBorder(active ? Theme.accentDim : Theme.line, lineWidth: 1))
        .motion(Theme.animFast, value: active)
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
        Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                // 面积填充（对齐 web .spark-fill，Sparkline.vue polygon + opacity .1）：56×26 的
                // 小尺寸下单靠 1.5pt 线条方向感偏弱，线下 10% 同色填充把「价位相对区间的高低」
                // 铺成面，涨 / 跌形态一眼可辨；填充随线色（= 调用方信号语境色），是线的轻回声而非第二语义
                AreaMark(x: .value("i", i), y: .value("价", p.price))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color.opacity(0.1))
                LineMark(x: .value("i", i), y: .value("价", p.price))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(color)
            }
            // 末点圆（对齐 web spark-dot）：走势的「现在」锚点——列表行不摆 RankBar（它只在信号卡/详情），
            // 曲线终点即现价落位，以调用方传入的信号语境色收口，「现在在哪」扫读一眼可辨；
            // 单点曲线也由「空白」变一个可见点。纯图形，随整图 accessibilityHidden
            if let last = pts.last {
                PointMark(x: .value("i", pts.count - 1), y: .value("价", last.price))
                    .foregroundStyle(color)
                    .symbolSize(20) // Ø≈5pt：比 PriceChart 现价点（40）低一档——迷你图不抢行内主数字
            }
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
                    withAnimation(Theme.animFast) { shown = true }
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
                // 加载中静态占位瓦片（一致性评审收口）：透明让底部 card2（= Theme.skBase）透出即可——
                // 全仓 10+ 处调用各挂一个转圈小环是动效叠加噪声（MOTION.md §6-9「扫光只有一条、
                // 不叠加」/ 原则 3；web craft 同场景即静态 --sk-base 底）；成功态 fadeIn 保留
                Color.clear
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
                // 次级统计格与 hero 档同走 MonoStep 通道（§2 T2 迁移约定：新代码禁用 size 兼容通道，
                // 共享层自身先吃完狗粮）：sub=14 semibold，观感与历史一致；minScale 通道内建 lineLimit+缩放
                Mono(value, step: .sub, color: color, minScale: 0.75) // 窄屏大数兜底
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

// MARK: - 共享动效层（MOTION.md §2.2：骨架屏四件套 + 切换/数字/按压/刷新指示）

/// 扫光内核（SkeletonBlock 的 overlay 层，MOTION.md §2.2）：单条慢速低幅扫光——
/// 周期 1.6s linear 无回弹（≥1.2s 达 §6-9 下限）、高光 Theme.lift（白 6% = 幅度上限）、
/// **只动 offset（transform，§6-1）**；RM（accessibilityReduceMotion）下不启动 = 静态骨架块（原则 5）。
private struct SkeletonShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 扫光相位：-1（块左外）→ 1（块右外），乘自身宽度即位移量
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                // 扫光条宽取宿主 40%：透明 → lift → 透明；GeometryReader 读宿主实际宽
                // （骨架条宽度不一，固定扫宽会破「慢速低幅」节奏）
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Theme.lift, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(8, geo.size.width * 0.4))
                        .offset(x: phase * geo.size.width)
                }
                .allowsHitTesting(false)
            )
            .clipped()
            .onAppear {
                guard !reduceMotion else { return } // RM：静态块（骨架纪律 §6-9）
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

/// 骨架基块（MOTION.md §2.2）：圆角矩形填 Theme.skBase（= card2 面阶最浅，低对比占位、
/// 无文字无描边语义）+ 单条扫光；纯占位图形 accessibilityHidden（MOTION.md §4）。
struct SkeletonBlock: View {
    let width: CGFloat
    let height: CGFloat
    var radius: CGFloat = Theme.radiusTile

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.skBase)
            .frame(width: width, height: height)
            .modifier(SkeletonShimmer())
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 文字条占位（对齐 web .sk-line）：默认 90×12、radius 2；宽由场景给定。
struct SkeletonLine: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12

    var body: some View {
        SkeletonBlock(width: width ?? 90, height: height, radius: 2)
    }
}

/// 弹性宽文字条（名称列占位）：宽度由布局分配（贴近真实行的自适应名称列，iPhone 上 ≈ 行宽 44%，
/// 即 MOTION.md §2.2 SkeletonRow 的「名称条 44%」在无百分比布局系统里的对应物）。
private struct FlexSkeletonLine: View {
    var height: CGFloat = 13

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Theme.skBase)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(SkeletonShimmer())
            .accessibilityHidden(true)
    }
}

/// 骨架列表行（MOTION.md §2.2）：对齐 AmmoRow 行结构——缩略图位 40×40、名称条（弹性）+ 徽章行条、
/// 右列 lead/sub 两档数字条、56 宽分位条位（Sparkline 槽）；行高 ≈ 真实行 ±10%。
/// 作 List 行使用：无分隔线 / 透明底 / 行内边距对齐信号卡行口径（AmmoView 信号卡 Section 同款）。
/// 纯装饰占位整行 accessibilityHidden——加载语义由页面状态与骨架后的真实内容承担。
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 10) {
            SkeletonBlock(width: 40, height: 40) // ItemThumb 位
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                FlexSkeletonLine(height: 14) // 名称条（md 档行高位）
                SkeletonLine(width: 48, height: 10) // 徽章行（micro 档）
            }
            Spacer(minLength: Theme.Space.xs)
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                SkeletonLine(width: 64, height: 14) // 右列主数字（lead 档高位）
                SkeletonLine(width: 46, height: 11) // 右列次级数字（sub 档高位）
            }
            SkeletonBlock(width: 56, height: 8, radius: 4) // 分位条位（Sparkline 56 宽槽）
        }
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .listRowBackground(Color.clear)
        .accessibilityHidden(true)
    }
}

/// 信号卡骨架槽（SkeletonList cards=true 的卡位，对齐 SignalCard 结构）：头行（缩略图位 + 名称条 +
/// 徽章位）、三格、主数字行、分位条；卡宽 250 与真实信号卡同宽，卡壳走 .card() 同款三层。
private struct SkeletonCardSlot: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                SkeletonBlock(width: 30, height: 30) // ItemThumb 位（信号卡 30）
                FlexSkeletonLine(height: 13) // 弹名条
                SkeletonLine(width: 36, height: 12) // 等级徽章位
            }
            HStack(spacing: 10) { // 三格（买入 ≤ / 挂卖 / 到手）
                SkeletonLine(width: 56, height: 12)
                SkeletonLine(width: 56, height: 12)
                SkeletonLine(width: 56, height: 12)
            }
            HStack(spacing: 6) { // 主数字行（预赚 /发 + 收益率）
                SkeletonLine(width: 92, height: 16)
                SkeletonLine(width: 44, height: 16)
            }
            SkeletonBlock(width: 218, height: 10, radius: 5) // RankBar 位（卡宽 250 − 内边距 24 − 余量）
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .card()
        .accessibilityHidden(true)
    }
}

/// 骨架列表（MOTION.md §2.2 / §4.2）：放进页面 List 数据 Section 的空态分支——Group 是透明容器，
/// 在 List 里每个子视图各自成行（卡位一行 + rows 条 SkeletonRow）。行数固定（8/10，§4.2 共性红线：
/// 不随屏幕无限堆），刷新（refreshable）**绝不回骨架**。骨架期间数据 Section 头请隐藏计数
/// （如 `Section("行情")`），避免「全部 · 0 种」与假行同屏矛盾（MOTION.md §4.2 List 整合细节）。
struct SkeletonList: View {
    var rows: Int = 8
    /// true 时顶部先出一行 2.5 张信号卡位（对应买入信号横滑区；雷达 / 制造传 false）
    var cards: Bool = true

    var body: some View {
        Group {
            if cards { cardSlotRow }
            ForEach(0..<max(0, rows), id: \.self) { _ in
                SkeletonRow()
            }
        }
    }

    /// 一行 2.5 张卡位：3 张固定宽卡槽、末张被行缘裁半，与真实信号卡横滑区同构
    /// （ScrollView + 出血 + 同款行内边距，对齐 AmmoView 信号卡 Section 的容器手法）
    private var cardSlotRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonCardSlot()
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .listRowBackground(Color.clear)
        .accessibilityHidden(true)
    }
}

/// 四态机（MOTION.md §4.2 状态机，**单一定义**——一致性评审收口：原先 AmmoView / RadarView /
/// CraftView 三份逐字重复的私有 TableState，正是判据漂移（如未来某页误看 isLoading）的温床）：
/// 骨架→内容 / 空错态互切的统一判据，也是 `.contentSwap` 的切换键。判据只看 snapshot / lastError，
/// **不看 isLoading**——FeedModel.isLoading 初值 false、configure() 首拉才置 true，这段 idle 窗口
/// 真实存在，一律骨架比空白 / 闪错安全；错误优先；有快照但筛选 / 搜索无命中 = 空态；
/// 刷新（refreshable）期间 snapshot 不回 nil，永不回骨架。
enum FeedTableState: Equatable {
    case error(String)
    case skeleton
    case empty
    case rows

    /// 判据唯一实现：hasSnapshot 传 `feed.snapshot != nil`；lastError 仅在无快照时升级为错误态
    /// （有快照的后台刷新失败走各页 FeedErrorBanner，不归本状态机）；isEmpty 传当前筛选下的行数是否为 0
    init(hasSnapshot: Bool, lastError: String?, isEmpty: Bool) {
        if !hasSnapshot {
            if let lastError { self = .error(lastError) }
            else { self = .skeleton }
        } else {
            self = isEmpty ? .empty : .rows
        }
    }
}

/// 「加载→内容」进场过渡（MOTION.md §3-H：内容进场带 6px 上移；web .swap 的 enter/leave
/// 不对称口径）：进场 = 淡入 + 6pt 上移、离场 = 只淡出（防布局跳动）；RM 降级为仅淡入。
private struct SwapTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(
            reduceMotion
                ? AnyTransition.opacity
                : AnyTransition.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity
                )
        )
    }
}

/// 数字滚动修饰符（MOTION.md §3-E / DESIGN.md §5「详情现价」）：封装 contentTransition(.numericText())
/// + animMed 档；RM 下 .identity + 无动画（跳过滚动，DESIGN.md §7-9）。只用于单点关键数字
/// （详情 hero 现价 / 预赚）——表格多行 60s 静默刷新禁用（原则 3：整表滚动 = 噪声）。
/// 本泛型通道只服务非数值键（无方向滚动）；数值键一律命中下方 Double / Double? 重载（方向感知）。
private struct NumericChangeModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .identity : .numericText())
            .motion(Theme.animMed, value: value)
    }
}

/// 方向感知数字滚动（思路库「数字滚动带方向」，iOS 17 `numericText(value:)`）：涨→数位上滚、跌→数位下滚，
/// 滚动方向与涨跌语义色互为印证；无参 `.numericText()` 只按位差滚、方向与涨跌无关。SwiftUICore 接口只声明
/// `numericText(value: Double)`，故仅 Double 一种底层，Int 等其它数值由调用处转 Double。RM 口径同上。
private struct DirectionalNumericChangeModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Double

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .identity : .numericText(value: value))
            .motion(Theme.animMed, value: value)
    }
}

extension View {
    /// 状态切换动画挂载（MOTION.md §2.2/§4.2 四态机）：骨架→内容 / 空错态互切时挂**一次**到
    /// 分支容器上（RM 门经 Theme.motion 内建，动画置 nil 即仅淡入/瞬时）。配套用法：
    /// 各态分支挂 `.transition(.opacity)`（内容态可换 `.swapTransition()` 带轻上移）。
    /// 例：`}.contentSwap(app.market.snapshot == nil)`
    func contentSwap<V: Equatable>(_ value: V) -> some View {
        motion(Theme.animSwap, value: value)
    }

    /// 内容分支进场过渡：淡入 + 6pt 轻上移、离场只淡出（RM 下仅淡入）；
    /// 骨架分支用 `.transition(.opacity)` 即可——骨架只淡出不位移（防布局跳动）
    func swapTransition() -> some View {
        modifier(SwapTransitionModifier())
    }

    /// 数字变化滚动（封装 contentTransition(.numericText())，MOTION.md §3-E）：
    /// `Mono(price, step: .hero).numericChange(value: price)`
    func numericChange<V: Equatable>(value: V) -> some View {
        modifier(NumericChangeModifier(value: value))
    }

    /// 方向感知重载（Double）：涨上滚 / 跌下滚。现有 Double 调用点（制造详情时利）零改动自动命中本重载
    /// （具体类型优先于泛型），观感只多出方向、时长 / RM 门不变
    func numericChange(value: Double) -> some View {
        modifier(DirectionalNumericChangeModifier(value: value))
    }

    /// 方向感知重载（Double?）：详情现价 / 制造行时利等可选价直接传入。nil（缺价显「—」）按 0 参与方向判定——
    /// 缺价→有价一律上滚；不用 NaN 占位（numericText 对非有限值行为未定义）
    func numericChange(value: Double?) -> some View {
        modifier(DirectionalNumericChangeModifier(value: value ?? 0))
    }
}

/// 轻量内联刷新指示（对齐 web .mini-spin，MOTION.md §3-F / §5「进度指示」行）：有数据刷新时
/// 嵌进按钮 / chip 的系统小圆环——**绝不整页遮罩、绝不回骨架**（§4 双端共性红线）。
/// 进度语义的循环动画在 RM 下保留（MOTION.md 原则 5 唯一例外，等同系统 ProgressView）。
struct MiniSpin: View {
    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .accessibilityLabel("刷新中")
    }
}

/// 统一可按压 ButtonStyle（MOTION.md §3-D「iOS 按压态」/ DESIGN.md §8-6 hover↔按压映射）：
/// 按压叠 lift 面（白 6%）、animFast 档淡入淡出；RM 下动画置 nil（**色面态仍生效**——
/// 按压反馈不因 RM 消失）。可点卡片描边提亮由卡片自身 `.card(hoverable: true)` 承担。
struct PressableButtonStyle: ButtonStyle {
    /// 按压面随内容圆角：大卡 radiusCard（默认）、小控件可传 Theme.radiusBadge / Capsule 圆角值
    var radius: CGFloat = Theme.radiusCard

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.lift)
                    .opacity(configuration.isPressed ? 1 : 0)
            )
            // RM 门经 Theme.motion（置 nil 即瞬时切换色面态）
            .motion(Theme.animFast, value: configuration.isPressed)
    }
}

// MARK: - 回顶浮动钮三件套（思路库「回顶浮动钮」；此前行情 / TTK 两页各持一份逐字相同的
// backTopButton 与同构离顶 Probe，雷达 / 制造的筛选回顶又各自内联 RM 分支——四份实现全靠
// 注释互称「同款」维系，收口至此单点维护，行为逐字不变）

/// 回顶滚动统一实现（四页 scrollToTop 的 RM 分支收口）：滚动走 animMed 预设
/// （MOTION.md §3-B 回顶档），Reduce Motion 下改无动画直达（§7-9，触感保留）。
/// 帮助函数不在视图体内、读不到 @Environment，reduceMotion 由调用方传入
/// （页面自持 @Environment(\.accessibilityReduceMotion)，与原页面内实现同源同值）
func scrollToTop(_ proxy: ScrollViewProxy, anchor: String, reduceMotion: Bool) {
    if reduceMotion {
        proxy.scrollTo(anchor, anchor: .top)
    } else {
        withAnimation(Theme.animMed) {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }
}

/// 回顶浮动钮：长表离顶后右下浮现。触控 44pt（§7-8）；card2 面 + lineHover 描边走面阶分层，
/// 轻投影补「悬浮于滚动内容之上」的最后一级分离（滚动内容与 card2 同亮度，纯面阶分不开，
/// §8「靠面阶」口径不适用于悬浮件）；点击走共享 scrollToTop（animMed 滚回榜首）。
/// web 端 BackTop 的 iOS 对应物。visible=false 整钮退场——进出场 transition 挂在钮上，
/// 动画事务由调用处 `.motion(Theme.animFast, value:)` 驱动（原两页挂法不变）
struct BackTopButton: View {
    let proxy: ScrollViewProxy
    /// scrollTo 目标锚点 id（各页 topAnchor）
    var anchor: String
    /// 显隐（离顶探测 ListTopAwayProbe 的 away 绑定值）
    var visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if visible {
            Button {
                scrollToTop(proxy, anchor: anchor, reduceMotion: reduceMotion)
            } label: {
                Image(systemName: "chevron.up")
                    .font(Theme.font(.md, weight: .semibold)) // 图标字号跟字阶走（§6.1-3）
                    .foregroundStyle(Theme.tx)
                    .frame(width: 44, height: 44)
                    .background(Theme.card2, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.lineHover, lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            }
            .buttonStyle(PressableButtonStyle(radius: 22))
            .accessibilityLabel("回到顶部")
            // 淡入 + 8pt 上移进出场：对齐 web BackTop 的 .totop（只动 opacity/transform，§6-1）
            .transition(.opacity.combined(with: .offset(y: 8)))
            .padding(.trailing, Theme.Space.lg)
            // 让位悬浮 Tab 胶囊：凸钮顶距屏底实测 ≈121pt（themedList 注释口径），垫 140pt 全不叠
            .padding(.bottom, 140)
        }
    }
}

/// 回顶浮动钮离顶探测：挂在锚点行背景，GeometryReader 读自身在列表命名坐标系的 minY，
/// 离顶超过阈值置 away。onChange 带 initial（iOS 17）：List 行懒回收后探测随行销毁、
/// 状态保留最后值（深处 = 钮常显）；行回到布局（滚回顶 / 回顶动画）时 initial 立即按当前位
/// 汇报，杜绝「人已回顶、钮还亮着」的滞留
struct ListTopAwayProbe: View {
    /// 列表命名坐标系名（调用处 .coordinateSpace(name:) 挂在 List 上的同一名字）
    let space: String
    /// 离顶阈值：探测行 minY 低于 -threshold（≈ 滚过表头 / 筛选区 + 数行）才置 away，浅滚不动声色
    var threshold: CGFloat = 300
    @Binding var away: Bool

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.frame(in: .named(space)).minY, initial: true) { _, minY in
                    away = minY < -threshold
                }
        }
    }
}
