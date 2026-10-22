// Theme.swift — 设计令牌（对齐 apps/web/src/assets/styles/base.css：深色战术指挥台，
// 蓝黑中性阶 + 唯一冷钢青主色；护甲/穿透等级色 1白 2绿 3蓝 4紫 5金 6红）
import DeltaForceCore
import SwiftUI

enum Theme {
    static let bg = Color(hex: 0x0D1013)
    static let bg2 = Color(hex: 0x11151A)
    static let card = Color(hex: 0x171D24)
    static let card2 = Color(hex: 0x1E252E)
    static let line = Color(hex: 0x29313B)
    static let txStrong = Color(hex: 0xF0F4F7)
    static let tx = Color(hex: 0xD9DEE3)
    static let dim = Color(hex: 0x9AA4AD)
    static let faint = Color(hex: 0x848E97)
    static let accent = Color(hex: 0x2DD4BF)

    // MARK: - 强调色衍生（base.css:41-44 同纪律：仅供描边 / hover 面 / 强调底，禁止作文字色）
    /// 强调色 38%：描边提亮（accent 实色过重时的降档替代）
    static let accentDim = accent.opacity(0.38)
    /// 强调色 62%：hover 面 / 次级强调图形
    static let accentSoft = accent.opacity(0.62)
    /// 强调色 9%：强调底（激活 chip 底 / 选中面），文字一律不用它
    static let accentBg = accent.opacity(0.09)

    // MARK: - 线与面（base.css:26-27 / 71-73）
    /// 弱分隔线：Divider overlay 等比 line 更轻的分隔场景
    static let line2 = Color(hex: 0x1F262E)
    /// 可点卡片描边（hover 态的按压映射，CardModifier hoverable / 自定义 ButtonStyle 用）
    static let lineHover = Color(hex: 0x39434F)
    /// 卡片顶缘微高光（白 4%，base.css 三层卡片手法的第三层，见 CardModifier）
    static let edgeLight = Color.white.opacity(0.04)
    /// 按压面（白 6%，对齐 base.css --lift，自定义 ButtonStyle 按压态用）
    static let lift = Color.white.opacity(0.06)

    // MARK: - 间距 / 圆角 / 动效阶梯（base.css:95-121 对应物）
    /// 间距阶梯：行内垂直 xs(4)、徽标行横向 6、卡内 sm(8)、区块间 md(12)——收编 2/3/4 混用
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// 圆角三档：徽标 6 / 瓦片（缩略图等）8 / 卡片 12——收编散落字面量
    static let radiusBadge: CGFloat = 6
    static let radiusTile: CGFloat = 8
    static let radiusCard: CGFloat = 12

    /// 动效时长（微交互 ≤ 0.22s，对齐 base.css --t-fast/-slow）；缓动惯例一律 `.easeOut(duration:)`
    static let durFast: TimeInterval = 0.15
    static let durMed: TimeInterval = 0.22

    /// 等级色 0…6（0 = 无甲灰）
    static let levels: [Color] = [
        Color(hex: 0x79828B), Color(hex: 0xBFC7CF), Color(hex: 0x85B578), Color(hex: 0x619FCE),
        Color(hex: 0x9D82CF), Color(hex: 0xE3B25E), Color(hex: 0xD96A59),
    ]
    static let ok = levels[2]
    static let warn = levels[5]
    static let danger = levels[6]
    static let info = levels[3]

    static func level(_ n: Int?) -> Color {
        guard let n, (0..<levels.count).contains(n) else { return levels[0] }
        return levels[n]
    }

    /// 文字用等级色：无甲（n == 0 / nil）降为 faint（#848E97，on card 实测 5.09:1 达 WCAG AA）。
    /// levels[0]（#79828B，on card 4.35:1 低于 AA）仅保留给描边 / 图形。
    static func levelText(_ n: Int?) -> Color {
        guard let n, n > 0 else { return faint }
        return level(n)
    }

    /// 文字用穿透等级色：穿 0（无穿透）同样降为 faint，理由同 levelText。
    /// 穿 6 文字单独提亮：levels[6] #D96A59 叠 12% 底（混色约 #2E262A）实测 4.30:1，
    /// 低于 AA 小字 4.5:1；#E07A68 同底约 5.0:1。仅文字色，底色 / 图形仍用 pen() 原色。
    static func penText(_ p: Int) -> Color {
        if p <= 0 { return faint }
        if p == 6 { return Color(hex: 0xE07A68) }
        return pen(p)
    }

    static func signal(_ s: Signal) -> Color {
        switch s {
        case .buy: ok
        case .sell: danger
        case .watch: warn
        case .wait: faint
        }
    }

    /// 穿透等级 0-7 色（7 级复用红并加亮）
    static func pen(_ p: Int) -> Color {
        p >= 7 ? Color(hex: 0xF08C7A) : level(p)
    }

    /// 字阶令牌：把 base.css 的 --fs-* 阶梯收敛到 iOS 文本样式，全部随 Dynamic Type 缩放。
    /// 全站禁止裸 .font(.system(size:))，一律经 font(_:weight:) / monoFont(_:weight:) 或系统文本样式。
    enum FontStep: CaseIterable {
        /// --fs-micro/2xs（10-11px）：字段名 / 表头 / 编号 / 单位等白名单标签 → caption2
        case micro
        /// --fs-xs（12px）：辅助说明 / 最小实义数据字号（价格 / 分位 / 耗时下限）→ footnote
        case xs
        /// --fs-sm（13px）：表格正文 / 次级正文 → footnote
        case sm
        /// --fs-md（14px）：正文基准 → subheadline
        case md
        /// --fs-lg（16px）：lede / 卡片标题 → body
        case lg
        /// --fs-xl（20px）：小节标题 → title3
        case xl
        /// --fs-2xl（26px）：页面标题下限 → title2
        case xxl

        var textStyle: Font.TextStyle {
            switch self {
            case .micro: .caption2
            case .xs, .sm: .footnote
            case .md: .subheadline
            case .lg: .body
            case .xl: .title3
            case .xxl: .title2
            }
        }
    }

    /// 默认设计字体：含中文的文本一律用它（等宽规则：默认 design，数字等宽由调用处 .monospacedDigit() 负责）
    static func font(_ step: FontStep, weight: Font.Weight = .regular) -> Font {
        Font.system(step.textStyle, design: .default, weight: weight)
    }

    /// 等宽字体：仅限纯 ASCII（数字 / 单位 / 编号 / 英文码，如 01 BUY、ms、RPM、50%）
    static func monoFont(_ step: FontStep, weight: Font.Weight = .regular) -> Font {
        Font.system(step.textStyle, design: .monospaced, weight: weight)
    }

    /// 等宽数字四档（DESIGN.md §1.3「战术等宽节拍」）：档位跟随数字在页内的**层级**而非数字本身——
    /// hero 只给页面唯一主角数字，每个列表行的主数字一律 lead、行内次级数字一律 sub、微字 micro。
    /// 「同层级同档」跨页恒量；字号经 ScaledMetric 随 Dynamic Type 自动缩放（各档锚定匹配量级的文本样式）。
    enum MonoStep: CaseIterable {
        /// 页面唯一主角（详情现价 / TTK 毫秒数）：22 bold
        case hero
        /// 列表行主数字（行情行收益率 / 雷达行现价）：16 semibold
        case lead
        /// 行内次级数字（行情行现价 / 分位 / 偏差）：14 semibold
        case sub
        /// 微字数字（图标注 / 气泡 / 角标）：12 medium
        case micro

        var size: CGFloat {
            switch self {
            case .hero: 22
            case .lead: 16
            case .sub: 14
            case .micro: 12
            }
        }

        var weight: Font.Weight {
            switch self {
            case .hero: .bold
            case .lead: .semibold
            case .sub: .semibold
            case .micro: .medium
            }
        }

        /// ScaledMetric 参照：档位越大锚越高的文本样式，缩放曲线与档位量级匹配
        var relativeTo: Font.TextStyle {
            switch self {
            case .hero: .title3
            case .lead: .body
            case .sub: .subheadline
            case .micro: .footnote
            }
        }

        /// 兼容映射（旧 size → 新档位）：22→hero，15/16→lead，13/14→sub，≤12→micro
        init(nearest raw: CGFloat) {
            switch raw {
            case 18...: self = .hero
            case 15..<18: self = .lead
            case 13..<15: self = .sub
            default: self = .micro
            }
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 12
    /// 可点卡片（DESIGN.md §2 T11）：true 时描边换 lineHover，暗示「这是入口」；按压面 Theme.lift 由自定义 ButtonStyle 叠加
    var hoverable: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            // 顶缘微高光（base.css:72-73 三层卡片手法的第三层）：白 4% 只留顶部 1pt，随卡片圆角裁剪
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .fill(Theme.edgeLight)
                    .mask(alignment: .top) { Rectangle().frame(height: 1) }
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).stroke(hoverable ? Theme.lineHover : Theme.line, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 12, hoverable: Bool = false) -> some View {
        modifier(CardModifier(padding: padding, hoverable: hoverable))
    }

    /// 列表统一底色（去掉系统分组背景）
    func themedList() -> some View {
        self.scrollContentBackground(.hidden).background(Theme.bg)
    }
}

/// 等宽数字文本（价格 / 百分比）：字号经 ScaledMetric 随 Dynamic Type 缩放，
/// 全站行情数字不改调用点即随系统字号设置缩放。
struct Mono: View {
    let text: String
    var weight: Font.Weight = .semibold
    var color: Color = Theme.txStrong
    /// 非 nil 时套 minimumScaleFactor + lineLimit(1)（详情现价等溢出高危位，DESIGN.md §2 T3）
    var minScale: CGFloat? = nil
    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 15

    /// 兼容通道（旧代码专用，新代码禁用——一律走 `init(_:step:)`）：
    /// 渲染行为与历史版本逐字节一致，供未迁移调用点零改动编译。
    /// - Parameter size: 基准字号（默认 15），实际渲染按 Dynamic Type 以 relativeTo 为参照缩放
    init(
        _ text: String,
        size: CGFloat = 15,
        weight: Font.Weight = .semibold,
        color: Color = Theme.txStrong,
        relativeTo: Font.TextStyle = .body
    ) {
        self.text = text
        self.weight = weight
        self.color = color
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
    }

    /// 新档位通道（DESIGN.md §2 T1/T2）：实义数字一律走 MonoStep 四档，档位跟层级走。
    /// - Parameters:
    ///   - step: 字阶档位（提供 size/weight/relativeTo 默认，见 `Theme.MonoStep`）
    ///   - weight: 覆盖档位默认字重（nil = 用档位默认）
    ///   - color: 文字色（只用 txStrong/tx/dim/faint/accent/信号语义色）
    ///   - relativeTo: 覆盖档位默认的 Dynamic Type 参照（nil = 用档位默认）
    ///   - minScale: 非 nil 时随宽缩至该比例且不折行（详情现价等溢出高危位）
    init(
        _ text: String,
        step: Theme.MonoStep,
        weight: Font.Weight? = nil,
        color: Color = Theme.txStrong,
        relativeTo: Font.TextStyle? = nil,
        minScale: CGFloat? = nil
    ) {
        self.text = text
        self.weight = weight ?? step.weight
        self.color = color
        self.minScale = minScale
        _scaledSize = ScaledMetric(wrappedValue: step.size, relativeTo: relativeTo ?? step.relativeTo)
    }

    @ViewBuilder
    var body: some View {
        let base = Text(text)
            .font(.system(size: scaledSize, weight: weight, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(color)
        if let minScale {
            base.lineLimit(1).minimumScaleFactor(minScale)
        } else {
            base
        }
    }
}
