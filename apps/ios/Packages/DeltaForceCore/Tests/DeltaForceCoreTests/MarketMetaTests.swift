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
        #expect(MarketMeta.staleTipText(source: "moligod", ageMin: 4320).contains("历史快照"))
        #expect(!MarketMeta.staleTipText(source: "kkrb", ageMin: 60).contains("历史快照"))
    }

    @Test("图标缩略：imageMogr2 拼接，已带查询串原样返回；http 升 https 防 ATS 拦截")
    func thumb() {
        #expect(MarketMeta.picThumb("https://x/a.png")?.absoluteString == "https://x/a.png?imageMogr2/thumbnail/96x")
        #expect(MarketMeta.picThumb("https://x/a.png?w=1", width: 200)?.absoluteString == "https://x/a.png?w=1")
        #expect(MarketMeta.picThumb("http://playerhub.df.qq.com/a.png")?.absoluteString == "https://playerhub.df.qq.com/a.png?imageMogr2/thumbnail/96x")
        #expect(MarketMeta.picThumb("http://playerhub.df.qq.com/a.png?w=1")?.absoluteString == "https://playerhub.df.qq.com/a.png?w=1")
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
        // 带符号金额 / 整数百分比（符号规则与 pct 对齐：正数补 +、负数自带 -；
        // 四舍五入到 0 的负值不显「-0」）
        #expect(Fmt.signedPrice(12345.6789) == "+12,346")
        #expect(Fmt.signedPrice(-1024.2) == "-1,024")
        #expect(Fmt.signedPrice(-0.4) == "0")
        #expect(Fmt.signedPrice(nil) == "—")
        #expect(Fmt.signedPctInt(0.276) == "+28%")
        #expect(Fmt.signedPctInt(-0.134) == "-13%")
        #expect(Fmt.signedPctInt(nil) == "—")
        #expect(Fmt.rankPercent(0.7142857) == "71%")
        #expect(Fmt.grouped(999) == "999")
        #expect(Fmt.grouped(1000) == "1,000")
        #expect(Fmt.grouped(-1234567) == "-1,234,567")
    }

    @Test("更新粒度文案")
    func sourceLabel() {
        #expect(MarketMeta.sourceLabel("moligod").contains("分钟级"))
        #expect(MarketMeta.sourceLabel("kkrb").contains("小时级"))
        #expect(MarketMeta.sourceLabel("kkrb-radar+moligod").contains("双源"))
        #expect(MarketMeta.sourceLabel("?") == "未知粒度")
    }

    /// 与 shared/js/marketMeta.js seasonPhase 对拍（server/ammo/selftest.mjs 同一组赛季与夹点）：
    /// S = start 2026-09-04T02:00:00+08:00 / end 2026-11-05T01:59:59+08:00
    private func season() -> Season {
        Season(name: "S11赛季", start: "2026-09-04T02:00:00+08:00", end: "2026-11-05T01:59:59+08:00")
    }

    private func instant(_ s: String) -> Date {
        guard let d = MarketMeta.parseISO8601(s) else { fatalError("测试时刻解析失败：\(s)") }
        return d
    }

    @Test("赛季阶段判定：与 JS seasonPhase 三夹点逐一对拍（fresh / hoard / late / mid + 无效赛季）")
    func seasonPhase() {
        // 开更 ≤3 天 = 出货窗（daysFromStart 0.92）
        let fresh = MarketMeta.seasonPhase(season(), now: instant("2026-09-05T00:00:00+08:00"))
        #expect(fresh?.phase == .fresh)
        #expect(fresh?.tone == .sell)
        #expect(fresh?.label == "开更出货窗（新赛季 +3 天内，补弹需求高峰）")
        // 剩 8.4 天 = 常规期
        let mid = MarketMeta.seasonPhase(season(), now: instant("2026-10-27T16:00:00+08:00"))
        #expect(mid?.phase == .mid)
        #expect(mid?.tone == .dim)
        #expect(mid?.label == "常规期")
        #expect(mid?.days == 8) // Math.floor(8.417)
        // 剩 6.1 天 = 囤货窗
        let hoard1 = MarketMeta.seasonPhase(season(), now: instant("2026-10-30T00:00:00+08:00"))
        #expect(hoard1?.phase == .hoard)
        #expect(hoard1?.tone == .buy)
        #expect(hoard1?.label == "囤货窗（T−7~T−3：新赛季前囤热门口径）")
        #expect(hoard1?.days == 6)
        // 剩 3.08 天 = 囤货窗上界（T−7~T−3 含刚过 3 天）
        let hoard2 = MarketMeta.seasonPhase(season(), now: instant("2026-11-02T00:00:00+08:00"))
        #expect(hoard2?.phase == .hoard)
        #expect(hoard2?.days == 3)
        // 剩 2.08 天 = 赛季末
        let late = MarketMeta.seasonPhase(season(), now: instant("2026-11-03T00:00:00+08:00"))
        #expect(late?.phase == .late)
        #expect(late?.tone == .warn)
        #expect(late?.label == "赛季末（T−3 内，物价波动大）")
        #expect(late?.days == 2)
        // 已到点：days 退 nil（倒计时位改「赛季已到点」，web 同款）
        let over = MarketMeta.seasonPhase(season(), now: instant("2026-11-05T02:00:00+08:00"))
        #expect(over?.phase == .late)
        #expect(over?.label == "赛季已到点（待新赛季数据刷新）")
        #expect(over?.days == nil)
        // 未开始 → mid（dim，仅给倒计时）
        let before = MarketMeta.seasonPhase(season(), now: instant("2026-09-01T00:00:00+08:00"))
        #expect(before?.phase == .mid)
        #expect(before?.label == "赛季未开始")
        #expect(before?.days == 65) // Math.floor(65.08)：09-01 → 11-05 01:59:59
        // 无效赛季：nil / 空对象 / 起止倒挂 → nil（JS null 同口径）
        #expect(MarketMeta.seasonPhase(nil, now: instant("2026-10-30T00:00:00+08:00")) == nil)
        #expect(MarketMeta.seasonPhase(Season(name: "x", start: "bad", end: "bad"), now: instant("2026-10-30T00:00:00+08:00")) == nil)
        #expect(MarketMeta.seasonPhase(Season(name: "x", start: "2026-11-05T01:59:59+08:00", end: "2026-09-04T02:00:00+08:00"), now: instant("2026-10-30T00:00:00+08:00")) == nil)
    }
}
