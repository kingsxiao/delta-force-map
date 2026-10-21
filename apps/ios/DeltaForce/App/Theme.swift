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
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 12) -> some View { modifier(CardModifier(padding: padding)) }

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
    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 15

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

    var body: some View {
        Text(text)
            .font(.system(size: scaledSize, weight: weight, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(color)
    }
}
