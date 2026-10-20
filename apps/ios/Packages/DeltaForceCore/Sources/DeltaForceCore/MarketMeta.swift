// MarketMeta.swift — shared/js/marketMeta.js 的同构移植（页面元信息纯函数）
// 版本双格式 / 时效阈值按 source 分档 / 来源文案 / 图标缩略 / 年龄可读化。
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

    /// 时效阈值（分钟）：moligod 分钟级 10/30；kkrb 小时级兜底 60/360
    public static func staleness(source: String?) -> Staleness {
        source == "moligod"
            ? Staleness(staleDotMin: 10, staleTipMin: 30)
            : Staleness(staleDotMin: 60, staleTipMin: 360)
    }

    public static func sourceLabel(_ source: String?) -> String {
        switch source {
        case "moligod": "三角洲攻略站 moligod（分钟级）"
        case "kkrb": "KK三角洲一图流 kkrb.net（约每小时，兜底）"
        case "kkrb-radar+moligod": "kkrb 涨幅榜 + moligod 曲线（双源交叉）"
        default: "未知来源"
        }
    }

    public static func methodDataLine(_ source: String?) -> String {
        source == "moligod"
            ? "三角洲攻略站 moligod.com 交易行口径，分钟级更新；趋势为近 7 天每小时价格。"
            : "KK三角洲一图流（kkrb.net）交易行口径，约每小时更新一次；趋势为近 7 天每小时均价。"
    }

    /// 官方弹药图标 → CDN 缩略图（腾讯云 imageMogr2 按宽缩放；已带查询串的 URL 原样返回）
    public static func picThumb(_ pic: String?, width: Int = 96) -> URL? {
        guard let pic, !pic.isEmpty else { return nil }
        if pic.contains("?") { return URL(string: pic) }
        return URL(string: "\(pic)?imageMogr2/thumbnail/\(width)x")
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
            return "数据已 \(age) 未更新（静态快照，未运行 live 服务时不会自动更新），价格可能已变化，可下拉刷新重试"
        }
        return "数据已 \(age) 未更新，价格可能已变化，可下拉刷新重试"
    }

    /// 数据年龄（分钟），锚点 fetchedAt（心跳会刷新它）
    public static func ageMinutes(fetchedAt: Date, now: Date = .now) -> Double {
        max(0, now.timeIntervalSince(fetchedAt) / 60)
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

    /// 收益率：+27.6% / -13.4%
    public static func pct(_ n: Double?) -> String {
        guard let n, n.isFinite else { return "—" }
        let sign = n >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", n * 100))%"
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
