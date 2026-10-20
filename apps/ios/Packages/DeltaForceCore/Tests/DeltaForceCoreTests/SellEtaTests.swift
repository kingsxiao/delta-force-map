// SellEtaTests.swift — sellEta.js 口径对账（日内节律 / 到达历时 / 时钟标签 / 可读化）
import Foundation
import Testing
@testable import DeltaForceCore

@Suite("预计卖出时间 SellEta")
struct SellEtaTests {
    @Test("日内节律：连续 3 小时最高窗口允许跨午夜")
    func hourlyProfileWrapsMidnight() {
        let curve = Fixtures.curve(hours: 168) { i in
            let h = i % 24
            return (h == 23 || h == 0 || h == 1) ? 200 : 100
        }
        let p = SellEtaEngine.hourlyProfile(curve)
        #expect(p?.startHour == 23)
        #expect(p?.endHour == 2)
        #expect(p?.liftPct == 1.0)
        #expect(SellEtaEngine.fmtPeak(start: 23, end: 2) == "23–次日 2 点")
        #expect(SellEtaEngine.fmtPeak(start: 19, end: 22) == "19–22 点")
        #expect(SellEtaEngine.fmtPeak(start: 21, end: 0) == "21–24 点")
        #expect(SellEtaEngine.fmtPeak(start: nil, end: 2) == nil)
        #expect(SellEtaEngine.hourlyProfile(Array(curve.prefix(23))) == nil)
    }

    @Test("历史完整上涨段：从 ≤from 首次到达 ≥to，窗口边缘截断不计")
    func reachEpisodes() {
        let prices: [Double] = [10, 12, 15, 9, 11, 16, 8]
        let curve = prices.enumerated().map { CurvePoint(key: String(format: "20261007%02d00", $0.offset), price: $0.element) }
        #expect(SellEtaEngine.reachEpisodes(curve, from: 10, to: 15) == [2, 2])
        #expect(SellEtaEngine.reachEpisodes(curve, from: 5, to: 15) == [])
        #expect(SellEtaEngine.reachEpisodes([], from: 1, to: 2) == [])
    }

    @Test("时钟标签：今日 / 明日 / M-D，分钟四舍五入到整点")
    func friendlyClock() {
        let cal = SellEtaEngine.beijing
        let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 14))!
        #expect(SellEtaEngine.friendlyClock(hit: base.addingTimeInterval(7 * 3600), base: base) == "今日 21:00")
        #expect(SellEtaEngine.friendlyClock(hit: base.addingTimeInterval(7.4 * 3600), base: base) == "今日 21:00")
        #expect(SellEtaEngine.friendlyClock(hit: base.addingTimeInterval(7.5 * 3600), base: base) == "今日 22:00")
        #expect(SellEtaEngine.friendlyClock(hit: base.addingTimeInterval(18 * 3600), base: base) == "明日 08:00")
        #expect(SellEtaEngine.friendlyClock(hit: base.addingTimeInterval(50 * 3600), base: base) == "10-15 16:00")
    }

    @Test("predict：历时中位 / 最快 / 样本数 / ETA 锚点取 max(曲线末点, now)")
    func predictSynthetic() {
        let curve = Fixtures.curve(hours: 48) { i in (i % 24) < 12 ? 100 : 130 }
        let item = Fixtures.item(current: 100, targetSell: 125, curve: curve)
        let now = SellEtaEngine.beijing.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 14))!
        let eta = SellEtaEngine.predict(item: item, now: now)
        #expect(eta != nil)
        #expect(eta?.atTarget == false)
        #expect(eta?.medianH == 12)
        #expect(eta?.fastestH == 12)
        #expect(eta?.episodes == 2)
        #expect(eta?.trend == .flat)
        #expect(eta?.etaLabel == "明日 02:00")
        #expect(eta?.peakStart == 12)
        #expect(eta?.peakEnd == 15)

        // now 早于曲线末点：锚点用曲线末点（2026-10-08 23:00 + 12h → 10-09 11:00）
        let early = SellEtaEngine.beijing.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 0))!
        #expect(SellEtaEngine.predict(item: item, now: early)?.etaLabel == "明日 11:00")

        // 现价已达目标：只给日内节律，不给历时
        let at = SellEtaEngine.predict(item: Fixtures.item(current: 130, targetSell: 125, curve: curve), now: now)
        #expect(at?.atTarget == true)
        #expect(at?.medianH == nil)
        #expect(at?.episodes == 0)
        #expect(at?.etaLabel == nil)

        // 缺现价：退化为只给日内节律
        let noInput = SellEtaEngine.predict(item: Fixtures.item(current: nil, targetSell: 125, curve: curve), now: now)
        #expect(noInput?.medianH == nil)
        #expect(noInput?.peakStart == 12)

        // 曲线不足 24 点
        #expect(SellEtaEngine.predict(item: Fixtures.item(current: 1, targetSell: 2, curve: Array(curve.prefix(20))), now: now) == nil)
    }

    @Test("predict：真实样本的 episodes 与 reachEpisodes 一致、标签格式合法")
    func predictFixture() throws {
        let snap = try Fixtures.market()
        var checked = 0
        for it in snap.items where it.curve.count >= 24 {
            guard let eta = SellEtaEngine.predict(item: it) else { continue }
            if let cur = it.current, let target = it.targetSell, cur < target {
                let eps = SellEtaEngine.reachEpisodes(it.curve, from: cur, to: target)
                #expect(eta.episodes == eps.count, Comment(rawValue: it.name))
                #expect(eta.fastestH == eps.first, Comment(rawValue: it.name))
            }
            if let label = eta.etaLabel {
                let ok = label.hasPrefix("今日 ") || label.hasPrefix("明日 ") || label.range(of: #"^\d{1,2}-\d{2} \d{2}:00$"#, options: .regularExpression) != nil
                #expect(ok, Comment(rawValue: label))
            }
            checked += 1
        }
        #expect(checked > 50)
    }

    @Test("历时可读化")
    func fmtHours() {
        #expect(SellEtaEngine.fmtHours(5) == "5 小时")
        #expect(SellEtaEngine.fmtHours(2.5) == "2.5 小时")
        #expect(SellEtaEngine.fmtHours(2.3) == "2.5 小时")
        #expect(SellEtaEngine.fmtHours(72) == "3 天")
        #expect(SellEtaEngine.fmtHours(60) == "2.5 天")
        #expect(SellEtaEngine.fmtHours(0) == "—")
        #expect(SellEtaEngine.fmtHours(nil) == "—")
    }
}
