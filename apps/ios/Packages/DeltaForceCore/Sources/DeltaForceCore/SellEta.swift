// SellEta.swift — shared/js/sellEta.js 的同构移植（预计卖出时间，纯函数）
// 两种口径，只吃条目自带的 7 天小时级 curve：
//   A. 历史到达历时：从 ≤现价 的低位档首次涨到 ≥挂卖价（P75）的完整上涨段，
//      取中位 / 最快历时（小时）
//   B. 日内节律：7 天同小时均价的连续 3 小时最高窗口（允许跨午夜）
// 时间键为北京时间墙钟（moligod / kkrb 口径一致），因此日历固定 Asia/Shanghai，
// 不随设备时区漂移；ETA 锚点取 max(曲线末点, now)。历史统计不代表未来——展示层必须带这句。
import Foundation

public struct HourlyProfile: Sendable, Hashable {
    public let startHour: Int
    /// 开区间（如 19–22）
    public let endHour: Int
    /// 高位窗口均值相对全天最低小时均值的涨幅；最低为 0 时 nil
    public let liftPct: Double?
}

public enum PriceTrend: String, Sendable, Hashable {
    case up, down, flat
}

public struct SellEta: Sendable, Hashable {
    /// 现价已达挂卖价：只给日内高位建议，不给历时
    public let atTarget: Bool
    public let medianH: Double?
    public let fastestH: Int?
    public let episodes: Int
    public let peakStart: Int?
    public let peakEnd: Int?
    public let liftPct: Double?
    public let trend: PriceTrend
    /// 「今日 21:00」/「明日 08:00」/「10-16 09:00」
    public let etaLabel: String?
}

public enum SellEtaEngine {
    /// 数据墙钟：北京时间
    public static let beijing: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        cal.locale = Locale(identifier: "zh_CN")
        return cal
    }()

    /// 时间键 → 小时（0-23）；'202610131400' 与 '2026101314' 通用
    static func hourOfKey(_ key: String) -> Int? {
        let s = Array(key)
        guard s.count >= 10, let h = Int(String(s[8..<10])), (0...23).contains(h) else { return nil }
        return h
    }

    /// 时间键 → Date（按北京墙钟解析）
    public static func keyToDate(_ key: String, calendar: Calendar = beijing) -> Date? {
        let s = Array(key)
        guard s.count >= 10,
              let y = Int(String(s[0..<4])), let mo = Int(String(s[4..<6])), let d = Int(String(s[6..<8])),
              let h = Int(String(s[8..<10]))
        else { return nil }
        let mi = s.count >= 12 ? (Int(String(s[10..<12])) ?? 0) : 0
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))
    }

    /// 日内节律：7 天同小时均价 → 连续 3 小时最高的窗口（允许跨午夜回绕）
    public static func hourlyProfile(_ curve: [CurvePoint]) -> HourlyProfile? {
        guard curve.count >= 24 else { return nil }
        var sum = [Double](repeating: 0, count: 24)
        var cnt = [Int](repeating: 0, count: 24)
        for pt in curve {
            if let h = hourOfKey(pt.key), pt.price.isFinite {
                sum[h] += pt.price
                cnt[h] += 1
            }
        }
        let avg: [Double?] = (0..<24).map { cnt[$0] > 0 ? sum[$0] / Double(cnt[$0]) : nil }
        var startHour = -1
        var best = -Double.infinity
        for h in 0..<24 {
            let vals = [0, 1, 2].map { avg[(h + $0) % 24] }
            if vals.contains(where: { $0 == nil }) { continue }
            let m = vals.compactMap { $0 }.reduce(0, +) / 3
            if m > best {
                best = m
                startHour = h
            }
        }
        guard startHour >= 0 else { return nil }
        let valid = avg.compactMap { $0 }
        let low = valid.min() ?? 0
        return HourlyProfile(
            startHour: startHour,
            endHour: (startHour + 3) % 24,
            liftPct: low > 0 ? (best - low) / low : nil
        )
    }

    /// 历史完整上涨段：价格从 ≤from 出发、首次到达 ≥to 的历时（曲线步数≈小时），升序
    public static func reachEpisodes(_ curve: [CurvePoint], from: Double, to: Double) -> [Int] {
        var eps: [Int] = []
        var i = 0
        let n = curve.count
        while i < n {
            if curve[i].price <= from {
                var j = i
                while j < n, curve[j].price < to { j += 1 }
                if j < n, j > i { eps.append(j - i) }
                i = max(j, i + 1)
            } else {
                i += 1
            }
        }
        return eps.sorted()
    }

    static func median(_ sorted: [Int]) -> Double {
        let n = sorted.count
        let mid = n >> 1
        return n % 2 == 1 ? Double(sorted[mid]) : Double(sorted[mid - 1] + sorted[mid]) / 2
    }

    /// 时刻 → 友好标签：同日「今日 HH:00」、次日「明日 HH:00」、更远「M-D HH:00」（分钟四舍五入到整点）
    static func friendlyClock(hit: Date, base: Date, calendar: Calendar = beijing) -> String {
        let t = Date(timeIntervalSince1970: (hit.timeIntervalSince1970 / 3600).rounded(.toNearestOrAwayFromZero) * 3600)
        let hour = calendar.component(.hour, from: t)
        let hm = String(format: "%02d:00", hour)
        let dayDiff = calendar.dateComponents([.day], from: calendar.startOfDay(for: base), to: calendar.startOfDay(for: t)).day ?? 0
        if dayDiff == 0 { return "今日 \(hm)" }
        if dayDiff == 1 { return "明日 \(hm)" }
        let month = calendar.component(.month, from: t)
        let day = calendar.component(.day, from: t)
        return "\(month)-\(String(format: "%02d", day)) \(hm)"
    }

    /// 预计卖出时间。曲线不足 24 点返回 nil；现价 / 目标价缺失时退化为只给日内节律（medianH=nil）
    public static func predict(item: MarketItem, now: Date = .now, calendar: Calendar = beijing) -> SellEta? {
        let curve = item.curve
        guard curve.count >= 24 else { return nil }
        let hasInputs: Bool
        if let c = item.current, let t = item.targetSell, c.isFinite, t.isFinite, t > 0 {
            hasInputs = true
        } else {
            hasInputs = false
        }
        let profile = hourlyProfile(curve)
        let atTarget = hasInputs ? (item.current! >= item.targetSell!) : false
        let eps = (atTarget || !hasInputs) ? [] : reachEpisodes(curve, from: item.current!, to: item.targetSell!)
        let med: Double? = eps.isEmpty ? nil : median(eps)

        let tail = curve.suffix(6).map(\.price)
        let drift = tail.count >= 2 ? tail[tail.count - 1] - tail[0] : 0

        var etaLabel: String?
        if let med, let anchorRaw = keyToDate(curve[curve.count - 1].key, calendar: calendar) {
            let anchor = now > anchorRaw ? now : anchorRaw
            etaLabel = friendlyClock(hit: anchor.addingTimeInterval(med * 3600), base: anchor, calendar: calendar)
        }

        return SellEta(
            atTarget: atTarget,
            medianH: med,
            fastestH: eps.first,
            episodes: eps.count,
            peakStart: profile?.startHour,
            peakEnd: profile?.endHour,
            liftPct: profile?.liftPct,
            trend: drift > 0 ? .up : drift < 0 ? .down : .flat,
            etaLabel: etaLabel
        )
    }

    /// 历时可读化：5 → 「5 小时」、2.5 → 「2.5 小时」、72 → 「3 天」
    public static func fmtHours(_ h: Double?) -> String {
        guard let h, h.isFinite, h > 0 else { return "—" }
        let r = (h * 2).rounded(.toNearestOrAwayFromZero) / 2
        if r < 48 {
            return r == r.rounded(.down) ? "\(Int(r)) 小时" : "\(String(format: "%.1f", r)) 小时"
        }
        var days = String(format: "%.1f", r / 24)
        if days.hasSuffix(".0") { days.removeLast(2) }
        return "\(days) 天"
    }

    /// 日内时段可读化：19/22 → 「19–22 点」；跨午夜 23/2 → 「23–次日 2 点」
    public static func fmtPeak(start: Int?, end: Int?) -> String? {
        guard let start, let end else { return nil }
        let e = end == 0 ? 24 : end
        return e <= start ? "\(start)–次日 \(end) 点" : "\(start)–\(e) 点"
    }
}
