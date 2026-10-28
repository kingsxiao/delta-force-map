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

    // MARK: - 全市场日内节律 marketClock（与 shared/js/sellEta.js 同输入同输出对拍）
    // 下列期望值全部由 node 对 shared/js/sellEta.js 的 marketClock 实跑产出
    //（见各断言旁注释），Swift 端按相同浮点运算顺序实现，逐位相等。

    @Test("marketClock：逐弹归一——同形不同价（×40）等权、判读 / 窗口 / 数据时刻")
    func marketClockNormalize() {
        // 两弹同为「0-11 点 100 / 12-23 点 130」形状，第二弹价格 ×40；
        // 归一后贡献完全相同的比值 → 聚合不被高价弹垄断
        let shape = Fixtures.curve(hours: 48) { i in (i % 24) < 12 ? 100 : 130 }
        let scaled = Fixtures.curve(hours: 48) { i in (i % 24) < 12 ? 4000 : 5200 }
        let clock = SellEtaEngine.marketClock([
            Fixtures.item(name: "低价弹", current: nil, targetSell: nil, curve: shape),
            Fixtures.item(name: "高价弹", current: nil, targetSell: nil, curve: scaled),
        ])
        #expect(clock?.counted == 2)
        // 末点 2026-10-08 23:00 → 数据时刻 23 点，处高位 tertile → 出货
        #expect(clock?.dataHour == 23)
        #expect(clock?.verdict == .sell)
        // 高位窗口 12–15（node 同输入实跑：peak 12-15 / lift 0.29999999999999993）
        #expect(clock?.peakStart == 12)
        #expect(clock?.peakEnd == 15)
        #expect(clock?.liftPct == 0.29999999999999993)
        #expect(clock?.levels[0] == 0.8695652173913043)   // = 100 / 115
        #expect(clock?.levels[12] == 1.1304347826086956)  // = 130 / 115
        #expect(clock?.levels[23] == 1.1304347826086956)
        // 判读文案（对齐倒卖手册 WINDOWS 用语）
        #expect(MarketClock.Verdict.buy.label == "扫货")
        #expect(MarketClock.Verdict.wait.label == "观望")
        #expect(MarketClock.Verdict.sell.label == "出货")
    }

    @Test("marketClock：数据时刻取最新末点 key 前缀——跨弹取更晚、双格式通用、不看设备时区")
    func marketClockDataHourTimezone() {
        // 弹 A 末点 2026-10-08 23:00、弹 B 末点 2026-10-14 01:00 → 取 01:00。
        // 若用 Date + 访问者时区（网页端 keyToDate 旧口径）解析，海外设备会把
        // 「次日 01:00」算成当地前一天的时刻；marketClock 只做 key 数值前缀比较
        // （API 不收 calendar），任何设备时区下结果一致——海外不错位
        let a = Fixtures.curve(hours: 48) { _ in 100 }
        let b = Fixtures.curve(hours: 26, start: (y: 2026, m: 10, d: 13)) { _ in 500 }
        #expect(a[a.count - 1].key == "202610082300")
        #expect(b[b.count - 1].key == "202610140100")
        let clock = SellEtaEngine.marketClock([
            Fixtures.item(name: "A", current: nil, targetSell: nil, curve: a),
            Fixtures.item(name: "B", current: nil, targetSell: nil, curve: b),
        ])
        #expect(clock?.counted == 2)
        #expect(clock?.dataHour == 1)

        // kkrb 10 位小时档 key 同样可用：末点 2026101401 → 数据时刻 1 点
        let c10 = (0..<24).map { CurvePoint(key: String(format: "20261013%02d", $0), price: 100) }
            + [CurvePoint(key: "2026101401", price: 100)]
        let clock10 = SellEtaEngine.marketClock([
            Fixtures.item(name: "A", current: nil, targetSell: nil, curve: a),
            Fixtures.item(name: "C", current: nil, targetSell: nil, curve: c10),
        ])
        #expect(clock10?.dataHour == 1)
    }

    @Test("marketClock：全天平坦 → 判读观望、lift 为 0、首窗口 0–3")
    func marketClockFlat() {
        let clock = SellEtaEngine.marketClock([
            Fixtures.item(name: "平价弹", current: nil, targetSell: nil, curve: Fixtures.curve(hours: 48) { _ in 777 }),
        ])
        #expect(clock?.counted == 1)
        #expect(clock?.dataHour == 23)
        #expect(clock?.verdict == .wait)
        #expect(clock?.liftPct == 0)
        #expect(clock?.peakStart == 0)
        #expect(clock?.peakEnd == 3)
        #expect(clock?.levels[0] == 1)
    }

    @Test("marketClock：末点处低位 tertile → 判扫货")
    func marketClockBuy() {
        // 26 点曲线（2026-10-13 00:00 起）：0-5 点 90、其余 120，末点 10-14 01:00
        let curve = Fixtures.curve(hours: 26, start: (y: 2026, m: 10, d: 13)) { i in (i % 24) <= 5 ? 90 : 120 }
        let clock = SellEtaEngine.marketClock([
            Fixtures.item(name: "晨低弹", current: nil, targetSell: nil, curve: curve),
        ])
        #expect(clock?.counted == 1)
        #expect(clock?.dataHour == 1)
        #expect(clock?.verdict == .buy)
        // node 同输入实跑：peak 6-9 / lift 0.33333333333333326 / levels[0]=0.8125 / levels[6]=1.0833333333333333
        #expect(clock?.peakStart == 6)
        #expect(clock?.peakEnd == 9)
        #expect(clock?.liftPct == 0.33333333333333326)
        #expect(clock?.levels[0] == 0.8125)
        #expect(clock?.levels[6] == 1.0833333333333333)
    }

    @Test("marketClock：曲线不足 24 点跳过；全不足 / 空数组返回 nil")
    func marketClockEdges() {
        let short = Fixtures.curve(hours: 20) { _ in 100 }
        #expect(SellEtaEngine.marketClock([Fixtures.item(name: "短曲线", current: nil, targetSell: nil, curve: short)]) == nil)
        #expect(SellEtaEngine.marketClock([]) == nil)
        // 有效 + 无效混合：只聚有效的
        let good = Fixtures.curve(hours: 48) { i in (i % 24) < 12 ? 100 : 130 }
        let mixed = SellEtaEngine.marketClock([
            Fixtures.item(name: "好弹", current: nil, targetSell: nil, curve: good),
            Fixtures.item(name: "短曲线", current: nil, targetSell: nil, curve: short),
        ])
        #expect(mixed?.counted == 1)
    }

    @Test("marketClock：真实样本与网页端同输入同输出（node 预期值逐位对拍）")
    func marketClockFixtureParity() throws {
        let snap = try Fixtures.market()
        let clock = SellEtaEngine.marketClock(snap.items)
        // node -e "marketClock(require('shared/fixtures/market-sample.json').items)" 实跑：
        // counted 67 / dataHour 15 / peak 19-22 / liftPct 0.0587886084204669 / verdict "sell"
        // （fixture 为会随数据刷新变化的真实样本——刷新后需用同命令重跑并同步下方常量）
        #expect(clock?.counted == 67)
        #expect(clock?.dataHour == 15)
        #expect(clock?.peakStart == 19)
        #expect(clock?.peakEnd == 22)
        #expect(clock?.liftPct == 0.0587886084204669)
        #expect(clock?.verdict == .sell)
        // 24 小时相对水位逐位相等（node JSON.stringify 全精度输出，Double 字面量同值往返）
        let expected: [Double?] = [
            0.9835494484226824, 0.9885857399321794, 0.9842065134516936, 0.9885857399321794,
            0.9842065134516936, 0.9799416484318016, 0.97004691447131, 0.9632695292291774,
            0.9702623847221089, 0.9747643762072965, 0.9799416484318016, 0.9791169451073986,
            0.9907702247450275, 0.9943592595535077, 1.0070798387975166, 1.0071667462971812,
            1.0056108708071492, 0.9958187810516996, 0.9952861952861953, 1.013550135501355,
            1.0249852974603393, 1.0211609801975023, 1.0096294001800528, 0.9986746821887889,
        ]
        #expect(clock?.levels.count == 24)
        #expect(clock?.levels == expected)
    }
}
