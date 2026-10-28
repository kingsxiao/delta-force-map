// Theme.swift — 设计令牌（对齐 apps/web/src/assets/styles/base.css：深色战术指挥台，
// 蓝黑中性阶 + 唯一冷钢青主色；护甲/穿透等级色 1白 2绿 3蓝 4紫 5金 6红）
import DeltaForceCore
import SwiftUI
import UIKit // 仅供 UIColor 动态提供器接 accessibilityContrast（下方文字令牌），不引入任何 UIKit 视图

enum Theme {
    static let bg = Color(hex: 0x0D1013)
    static let bg2 = Color(hex: 0x11151A)
    static let card = Color(hex: 0x171D24)
    static let card2 = Color(hex: 0x1E252E)
    static let line = Color(hex: 0x29313B)

    // MARK: - 文字令牌（AX 高对比自适应）
    /// 四枚文字色经 UIColor 动态提供器接 UITraitCollection.accessibilityContrast：系统开启「增强对比度」
    /// 时各自提亮约一档（txStrong→纯白、tx→原 txStrong、dim / faint 各升两阶灰），标准态十六进制值与历史
    /// 逐字节一致。为什么走 UIColor 而非 @Environment(\.colorSchemeContrast)：文字令牌全站数百处调用，
    /// 环境值方案要逐处改；动态色由 SwiftUI 渲染期按当前 trait 解析（机制同系统色 .secondaryLabel），
    /// 零调用点改动全站生效。面阶 / 强调色 / 等级色不参与提亮——只提文字对比、不动层次语言
    /// （levelText / penText 已各自做过对比度特例）；半透明徽标底的对应处理见 Components.swift badgeCoat。
    static let txStrong = contrastText(0xF0F4F7, boosted: 0xFFFFFF)
    static let tx = contrastText(0xD9DEE3, boosted: 0xF0F4F7)
    static let dim = contrastText(0x9AA4AD, boosted: 0xC3CCD4)
    static let faint = contrastText(0x848E97, boosted: 0xA9B3BC)
    static let accent = Color(hex: 0x2DD4BF)

    /// 标准态 / 增强对比态双值文字色（UIColor 为 NS_SWIFT_SENDABLE 且非 MainActor，静态上下文构造安全）
    private static func contrastText(_ normal: UInt32, boosted: UInt32) -> Color {
        let normalColor = UIColor(Color(hex: normal))
        let boostedColor = UIColor(Color(hex: boosted))
        return Color(uiColor: UIColor { trait in
            trait.accessibilityContrast == .high ? boostedColor : normalColor
        })
    }

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
    /// 状态切换时长（骨架→内容 / 空错态进场 / 提示条进出）：对齐 web --t-panel（MOTION.md §2.1）
    static let durSwap: TimeInterval = 0.25

    /// 动画预设（MOTION.md §2.2）：缓动唯一家族 .easeOut（上行注释口径），档位封闭——
    /// 新动效只能取 §5 对照表内档位（0.15 / 0.22 / 0.25 / 循环类各语义位专属），新场景先定档再写码
    static let animFast = Animation.easeOut(duration: durFast) // 0.15 微交互（chip / 按压 / 图表十字线）
    static let animMed = Animation.easeOut(duration: durMed)   // 0.22 数字滚动 / 回顶 / 卡片按压后的回复
    static let animSwap = Animation.easeOut(duration: durSwap) // 0.25 状态切换（骨架→内容 / 空错态进场）

    /// 骨架底色（对齐 web --sk-base = card2：面阶最浅的一档，低对比占位，MOTION.md §4）；
    /// 扫光高光不新增令牌，复用 lift（白 6% = MOTION.md §6-9 扫光幅度上限）
    static let skBase = card2

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
        self
            .scrollContentBackground(.hidden)
            // 悬浮 Tab 栏让位（DESIGN.md §6.2 悬浮玻璃形态）：iOS 26 悬浮胶囊不产生
            // 安全区 inset，列表滚到底时末段（「口径」页脚等）会停在玻璃层之下被压住。
            // 统一垫高底部安全区，让末段完整悬于胶囊（含选中凸钮，顶距屏底实测 ≈121pt）
            // 之上再停。取值 186+24：121pt 凸钮 + 24pt(Space.xl) 留白 + ≈65pt 补偿——
            // 四页口径 footer 长短不一且长列表（TTK 200+ 行）scrollTo 落点有 ±10pt 级
            // 懒布局噪声，按最差页实测校准保证全部让位。选 safeAreaPadding 而非
            // contentMargins：实测（600pt 探针对拍）scrollTo 落点不包含末尾 contentMargin，
            // 巡检钩子 -wfScrollEnd 拍不出让位效果；safeAreaPadding 参与滚动落点计算且
            // 落点随 padding 1:1 移动（260pt 探针复验），滚动中内容仍可滚入胶囊后方
            // （穿透保留）。本样式全部调用点都在 TabView 层级内（5 个 Tab 根列表 +
            // push 详情页），sheet 内列表不走本样式、不受影响。
            .safeAreaPadding(.bottom, 186 + Theme.Space.xl)
            .background(Theme.bg)
    }
}

// MARK: - 动效挂载（MOTION.md §2.2 / §6-5）

/// 动效统一挂载修饰符：RM（accessibilityReduceMotion）下动画置 nil——降级即瞬时 / 仅淡入，
/// 禁止留更慢版本（MOTION.md 原则 5）。**@Environment 必须是修饰符结构体的存储属性**：
/// View 扩展函数体内的局部 @Environment 不进 SwiftUI 环境注入管线，可编译但渲染期恒读
/// 默认值（MOTION.md §2.2 NSHostingView 探针实测），照抄该写法会让 RM 降级静默全失效。
struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Reduce Motion 判定辅助（MOTION.md §6-5「RM 全覆盖」红线）：按 value 变化挂动画预设，
    /// RM 下自动置 nil。全站 .animation 一律经它挂载（等价于强制「带 value:」形态），例如：
    /// `chip.motion(Theme.animFast, value: isOn)`
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
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
