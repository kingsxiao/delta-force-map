// MarketMetaTests.swift — marketMeta.js / analyze.mjs 格式化口径对账
import Foundation
import Testing
@testable import DeltaForceCore

@Suite("MarketMeta / Fmt 口径")
struct MarketMetaTests {
    @Test("版本双格式展示")
    func versionLabel() {
        #expect(MarketMeta.formatVersionLabel("202610141318") == "2026-10-14 13:18")
        #expect(MarketMeta.formatVersionLabel("2026101413") == "2026-10-14 13:00")
        #expect(MarketMeta.formatVersionLabel(nil) == "—")
        #expect(MarketMeta.formatVersionLabel("") == "—")
    }

    @Test("时效阈值按 source 分档")
    func staleness() {
        #expect(MarketMeta.staleness(source: "moligod") == .init(staleDotMin: 10, staleTipMin: 30))
        #expect(MarketMeta.staleness(source: "kkrb") == .init(staleDotMin: 60, staleTipMin: 360))
        #expect(MarketMeta.staleness(source: nil).staleTipMin == 360)
    }

    @Test("年龄可读化：分钟 / 小时 / 天，不输出原始分钟数")
    func age() {
        #expect(MarketMeta.fmtAge(minutes: 0.2) == "1 分钟")
        #expect(MarketMeta.fmtAge(minutes: 12.4) == "12 分钟")
        #expect(MarketMeta.fmtAge(minutes: 90) == "2 小时")
        #expect(MarketMeta.fmtAge(minutes: 4320) == "3 天")
        #expect(MarketMeta.fmtAge(minutes: nil) == "—")
        #expect(MarketMeta.staleTipText(source: "moligod", ageMin: 4320).contains("静态快照"))
        #expect(!MarketMeta.staleTipText(source: "kkrb", ageMin: 60).contains("静态快照"))
    }

    @Test("图标缩略：imageMogr2 拼接，已带查询串原样返回")
    func thumb() {
        #expect(MarketMeta.picThumb("https://x/a.png")?.absoluteString == "https://x/a.png?imageMogr2/thumbnail/96x")
        #expect(MarketMeta.picThumb("https://x/a.png?w=1", width: 200)?.absoluteString == "https://x/a.png?w=1")
        #expect(MarketMeta.picThumb(nil) == nil)
        #expect(MarketMeta.picThumb("") == nil)
    }

    @Test("价格 / 收益率格式与 analyze.mjs 一致（含 JS Math.round 负数 .5 语义）")
    func fmt() {
        #expect(Fmt.price(1234567.4) == "1,234,567")
        #expect(Fmt.price(273) == "273")
        #expect(Fmt.price(-36.5) == "-36")
        #expect(Fmt.price(2.5) == "3")
        #expect(Fmt.price(nil) == "—")
        #expect(Fmt.pct(0.276) == "+27.6%")
        #expect(Fmt.pct(-0.13443) == "-13.4%")
        #expect(Fmt.pct(0) == "+0.0%")
        #expect(Fmt.rankPercent(0.7142857) == "71%")
        #expect(Fmt.grouped(999) == "999")
        #expect(Fmt.grouped(1000) == "1,000")
        #expect(Fmt.grouped(-1234567) == "-1,234,567")
    }

    @Test("来源文案")
    func sourceLabel() {
        #expect(MarketMeta.sourceLabel("moligod").contains("分钟级"))
        #expect(MarketMeta.sourceLabel("kkrb").contains("兜底"))
        #expect(MarketMeta.sourceLabel("kkrb-radar+moligod").contains("双源"))
        #expect(MarketMeta.sourceLabel("?") == "未知来源")
    }
}
