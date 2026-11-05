// MarketMeta.swift — shared/js/marketMeta.js 的同构移植（页面元信息纯函数）
// 版本双格式 / 时效阈值按 source 分档 / 更新粒度文案 / 图标缩略 / 年龄可读化。
// 改口径先改 shared/js 与 shared/API.md，再同步这里（单测用同一组样本对账）。
import Foundation

public enum MarketMeta {
    /// 数据版本号 → 展示串：12 位 "YYYY-MM-DD HH:mm"，10 位 "YYYY-MM-DD HH:00"
    public static func formatVersionLabel(_ v: String?) -> String {
        guard let v, !v.isEmpty else { return "—" }
        let s = Array(v)
        guard s.count >= 10 else { return v }
        let ymd = "\(String(s[0..<4]))-\(String(s[4..<6]))-\(String(s[6..<8]))"
        let hh = String(s[8..<10])
        if s.count >= 12 {
            return "\(ymd) \(hh):\(String(s[10..<12]))"
        }
        return "\(ymd) \(hh):00"
    }

    public struct Staleness: Sendable, Hashable {
        /// 超过即把 live 点变灰
        public let staleDotMin: Double
        /// 超过即出过期提示
        public let staleTipMin: Double
    }

    /// 时效阈值（分钟）：moligod 分钟级 10/30（moligod-craft 特勤处制造同档）；kkrb 小时级兜底 60/360；
    /// kkrb-radar+moligod 雷达双源 90/240（与 web 雷达页口径对齐）
    public static func staleness(source: String?) -> Staleness {
        switch source {
        case "moligod", "moligod-craft": Staleness(staleDotMin: 10, staleTipMin: 30)
        case "kkrb-radar+moligod": Staleness(staleDotMin: 90, staleTipMin: 240)
        default: Staleness(staleDotMin: 60, staleTipMin: 360)
        }
    }

    public static func sourceLabel(_ source: String?) -> String {
        switch source {
        case "moligod", "moligod-craft": "分钟级"
        case "kkrb": "小时级"
        case "kkrb-radar+moligod": "双源交叉"
        default: "未知粒度"
        }
    }

    public static func methodDataLine(_ source: String?) -> String {
        source == "moligod"
            ? "交易行口径，分钟级更新；趋势为近 7 天每小时价格。"
            : "交易行口径，约每小时更新一次；趋势为近 7 天每小时均价。"
    }

    /// 官方弹药图标 → CDN 缩略图（腾讯云 imageMogr2 按宽缩放；已带查询串的 URL 原样返回）。
    /// iOS 在 shared/js 口径上加一道协议归一：http:// 一律升 https://（Info.plist 已删 ATS 明文例外，
    /// pic 来自上游透传，若回传 http 会被 ATS 静默拦截，web 端 <img> 无此约束形成双端分叉）。
    /// https 输入的输出与 marketMeta.js 逐字一致（对账样本不变）。
    public static func picThumb(_ pic: String?, width: Int = 96) -> URL? {
        guard let pic, !pic.isEmpty else { return nil }
        let https = pic.hasPrefix("http://") ? "https://" + pic.dropFirst("http://".count) : pic
        if https.contains("?") { return URL(string: https) }
        return URL(string: "\(https)?imageMogr2/thumbnail/\(width)x")
    }

    /// 数据年龄可读化：<60min 用分钟、<24h 用小时、更长用天
    public static func fmtAge(minutes ageMin: Double?) -> String {
        guard let ageMin, ageMin.isFinite else { return "—" }
        if ageMin < 60 { return "\(Int(max(1, jsRound(ageMin)))) 分钟" }
        if ageMin < 1440 { return "\(Int(jsRound(ageMin / 60))) 小时" }
        return "\(Int(jsRound(ageMin / 1440))) 天"
    }

    /// 过期提示文案：分钟级源如实注明「静态快照」
    public static func staleTipText(source: String?, ageMin: Double?) -> String {
        let age = fmtAge(minutes: ageMin)
        if source == "moligod" {
            return "数据已 \(age) 未更新（当前为历史快照），价格可能已变化，可下拉刷新重试"
        }
        return "数据已 \(age) 未更新，价格可能已变化，可下拉刷新重试"
    }

    /// 数据年龄（分钟），锚点 fetchedAt（心跳会刷新它）
    public static func ageMinutes(fetchedAt: Date, now: Date = .now) -> Double {
        max(0, now.timeIntervalSince(fetchedAt) / 60)
    }

    // MARK: - 赛季阶段（shared/js/marketMeta.js seasonPhase 同构移植；契约 API.md §1 三端同构）

    /// 赛季阶段四档（与 JS phase 值一一对应）
    public enum SeasonPhaseKind: String, Sendable, Hashable {
        /// 开更出货窗（赛季开始 ≤3 天）
        case fresh
        /// 囤货窗（距赛季结束 3~7 天，即 T−7~T−3）
        case hoard
        /// 赛季末（距结束 ≤3 天 / 已到点）
        case late
        /// 常规期（含未开始）
        case mid
    }

    /// 赛季阶段调性（web Playbook .pb-season tone 四档；UI 侧 buy=ok / sell=danger / warn=warn / dim=dim）
    public enum SeasonTone: String, Sendable, Hashable {
        case buy, sell, warn, dim
    }

    /// seasonPhase 判定结果（label 与 JS 逐字同步——三端同构口径，改文案先改 shared/js 再同步这里）
    public struct SeasonPhase: Sendable, Hashable {
        public let phase: SeasonPhaseKind
        public let label: String
        public let tone: SeasonTone
        /// 距赛季结束天数（可负 = 已到点）
        public let daysLeft: Double
        /// 距赛季开始天数
        public let daysFromStart: Double

        /// 倒计时整数天：>0 向下取整、≤0 nil（对齐 web Playbook seasonInfo.days 的
        /// `p.daysLeft > 0 ? Math.floor(p.daysLeft) : null`；nil 时横幅改显「赛季已到点」）
        public var days: Int? { daysLeft > 0 ? Int(daysLeft.rounded(.down)) : nil }

        public init(phase: SeasonPhaseKind, label: String, tone: SeasonTone, daysLeft: Double, daysFromStart: Double) {
            self.phase = phase
            self.label = label
            self.tone = tone
            self.daysLeft = daysLeft
            self.daysFromStart = daysFromStart
        }
    }

    /// 赛季阶段判定（Playbook「版本与赛季窗口」实时行的数据源，纯函数）：赛季窗口套利的
    /// 口径来自 Playbook 03 静态经验——更新前 3~7 天囤货、开更后 3 天内出货、赛季末物价波动。
    /// 与 shared/js/marketMeta.js seasonPhase 逐分支同构：
    ///   fresh  开更出货窗（daysFromStart ≤3，tone=sell）
    ///   late   赛季末（daysLeft ≤0 已到点 / ≤3，tone=warn）
    ///   hoard  囤货窗（daysLeft ≤7，tone=buy）
    ///   mid    常规期（含未开始 daysFromStart <0，tone=dim，仅给倒计时）
    /// 无有效赛季 / 起止倒挂 / 起止解析失败 → nil（JS 返回 null 同口径）
    public static func seasonPhase(_ season: Season?, now: Date = .now) -> SeasonPhase? {
        guard let start = parseISO8601(season?.start), let end = parseISO8601(season?.end), start < end else { return nil }
        let day = 86_400.0
        let nowT = now.timeIntervalSince1970
        let daysLeft = (end.timeIntervalSince1970 - nowT) / day
        let daysFromStart = (nowT - start.timeIntervalSince1970) / day
        func out(_ phase: SeasonPhaseKind, _ label: String, _ tone: SeasonTone) -> SeasonPhase {
            SeasonPhase(phase: phase, label: label, tone: tone, daysLeft: daysLeft, daysFromStart: daysFromStart)
        }
        if daysFromStart < 0 { return out(.mid, "赛季未开始", .dim) }
        if daysFromStart <= 3 { return out(.fresh, "开更出货窗（新赛季 +3 天内，补弹需求高峰）", .sell) }
        if daysLeft <= 0 { return out(.late, "赛季已到点（待新赛季数据刷新）", .warn) }
        if daysLeft <= 3 { return out(.late, "赛季末（T−3 内，物价波动大）", .warn) }
        if daysLeft <= 7 { return out(.hoard, "囤货窗（T−7~T−3：新赛季前囤热门口径）", .buy) }
        return out(.mid, "常规期", .dim)
    }

    /// JS Date.parse 同构的 ISO-8601 解析：契约 start/end 带时区偏移（如 +08:00），
    /// 也兼容毫秒 / Z 后缀。解析失败（JS 得 NaN）→ nil。
    /// 用值类型 FormatStyle 而非共享 DateFormatter 实例：Swift Testing 默认并行跑用例
    public static func parseISO8601(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        if let d = try? Date.ISO8601FormatStyle().parse(s) { return d }
        return nil
    }

    /// JS `Math.round` 语义：.5 向正无穷取整（Swift `rounded()` 是远离零，负数会差 1）
    @inline(__always)
    static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }
}

/// 数值格式化（server/ammo/analyze.mjs fmtPrice / fmtPct 同口径，通知文案与页面共用）
public enum Fmt {
    /// 价格：四舍五入到整数 + 千分位（哈夫币/发）
    public static func price(_ n: Double?) -> String {
        guard let n, n.isFinite else { return "—" }
        let v = Int(MarketMeta.jsRound(n))
        return grouped(v)
    }

    /// 带符号金额（利润可为负）：+12,345 / -1,024。符号规则与 pct 对齐——正数补 +、
    /// 负数的 - 由 price 自带（不 abs 拼接：四舍五入到 0 的负值显「0」而非「-0」）
    public static func signedPrice(_ n: Double?) -> String {
        guard let n, n.isFinite else { return "—" }
        return (n >= 0 ? "+" : "") + price(n)
    }

    /// 收益率：+27.6% / -13.4%
    public static func pct(_ n: Double?) -> String {
        guard let n, n.isFinite else { return "—" }
        let sign = n >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", n * 100))%"
    }

    /// 带符号整数百分比（成本回报等 roi 口径）：+27% / -13%（四舍五入取整，符号规则同 pct）
    public static func signedPctInt(_ n: Double?) -> String {
        guard let n, n.isFinite else { return "—" }
        return (n >= 0 ? "+" : "") + "\(Int((n * 100).rounded()))%"
    }

    /// 分位：0.714 → "71%"
    public static func rankPercent(_ r: Double?) -> String {
        guard let r, r.isFinite else { return "—" }
        return "\(Int(MarketMeta.jsRound(r * 100)))%"
    }

    /// 千分位整数（与 toLocaleString('zh-CN') 的整数输出一致）
    public static func grouped(_ v: Int) -> String {
        let neg = v < 0
        let digits = Array(String(v.magnitude))
        var out: [Character] = []
        for (i, ch) in digits.enumerated() {
            let remaining = digits.count - i
            if i > 0, remaining % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (neg ? "-" : "") + String(out)
    }
}
