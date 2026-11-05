// ModelDecodingTests.swift — 契约样本解码（shared/fixtures）
import Foundation
import Testing
@testable import DeltaForceCore

@Suite("契约样本解码")
struct ModelDecodingTests {
    @Test("market-sample.json：67 种弹药、四种信号、日期带毫秒可解析")
    func decodeMarket() throws {
        let snap = try Fixtures.market()
        #expect(snap.items.count == 67)
        #expect(snap.version.count == 12 || snap.version.count == 10)
        #expect(["moligod", "kkrb"].contains(snap.source))
        #expect(snap.fetchedAt.timeIntervalSince1970 > 1_700_000_000)
        #expect(snap.stats?.total == 67)
        // season（F13）：真实留档样本顶层带赛季日历，随 MarketSnapshot 整体解码保形
        // （name/start/end 非空；events 数量随赛季浮动不作硬断言，形状校验见 decodeSeason）
        #expect(snap.season?.name?.isEmpty == false)
        #expect(snap.season?.start?.isEmpty == false)
        #expect(snap.season?.end?.isEmpty == false)
        let signals = Set(snap.items.map(\.signal))
        #expect(signals.isSubset(of: Set(Signal.allCases)))
        // 数据不足的条目 rank 必为 nil 且 WAIT（契约 if/then）
        for it in snap.items where it.rank == nil {
            #expect(it.signal == .wait)
        }
        // 曲线按时间键升序
        for it in snap.items {
            let keys = it.curve.map(\.key)
            #expect(keys == keys.sorted())
        }
        // 信号与分位口径一致（analyze.mjs v2：BUY 五重门槛 / SELL 动量守则）
        for it in snap.items {
            guard let rank = it.rank, let pct = it.profitPct else { continue }
            let slope = it.slope48 ?? 0
            let expected: Signal
            if rank >= 0.8, !(slope > 0.05) { expected = .sell }
            else if rank <= 0.2, pct >= 0.10, it.curve.count >= 48,
                    (it.bounceOffLow ?? 0) >= 0.03, (it.lowAgeH ?? 0) >= 12, slope >= 0.02 {
                expected = .buy
            } else if rank <= 0.35 { expected = .watch }
            else { expected = .wait }
            #expect(it.signal == expected, "\(it.name) rank=\(rank)")
        }
    }

    @Test("radar-sample.json：全量榜单、雷达字段齐全、异常条目强制观望")
    func decodeRadar() throws {
        let snap = try Fixtures.radar()
        // 雷达快照契约 = 上游整表透传不 slice（radar.mjs）：items 数必须等于 stats.total（旧断言
        // 写死 == 10，fixture 扩到 11 后即翻红——契约按 total 断言，fixture 加样不再误报）
        #expect(snap.items.count == snap.stats?.total)
        #expect(snap.source == "kkrb-radar+moligod")
        #expect(snap.stats?.anomaly != nil)
        #expect(snap.season == nil) // 雷达快照无 season（仅 market.json 带）
        for it in snap.items {
            #expect(it.hiRank != nil)
            #expect(it.category != nil)
            #expect(it.rawSignal != nil)
            #expect(it.curveSource != nil)
            if it.isAnomaly { #expect(it.signal == .wait) }
        }
        let ranks = snap.items.compactMap(\.hiRank)
        #expect(ranks == ranks.sorted())
    }

    @Test("rules 11 键展示子集：新四键可解码，decodeIfPresent 兼容 7 键旧快照")
    func decodeRulesExtended() throws {
        // 全 11 键形态（analyze.mjs RULES_VIEW_KEYS 当前全集；BUY_MKT_SLOPE_MIN null = 关闭）
        let full = #"{"BUY_RANK_MAX":0.2,"BUY_MIN_NET_PCT":0.1,"WATCH_RANK_MAX":0.35,"SELL_RANK_MIN":0.8,"BUY_MIN_POINTS":48,"BUY_BOUNCE_OFF_LOW":0.03,"BUY_LOW_AGE_H":12,"BUY_SLOPE_MIN":0.02,"BUY_MKT_SLOPE_MIN":null,"MAX_HOLD_H":168,"TARGET_WINDOW_H":72}"#
        let r = try JSONDecoder().decode(MarketRules.self, from: Data(full.utf8))
        #expect(r.buyRankMax == 0.2)
        #expect(r.buyMinPoints == 48)
        #expect(r.buyBounceOffLow == 0.03)
        #expect(r.buyLowAgeH == 12)
        #expect(r.buySlopeMin == 0.02)
        #expect(r.buyMktSlopeMin == nil) // null = 关闭，解码为 nil
        // 旧 7 键形态（本仓 fixtures/market-sample.json 即旧形态）：新四键缺字段退 nil 不炸
        let old = try JSONDecoder().decode(MarketRules.self, from: Data(#"{"BUY_RANK_MAX":0.2,"BUY_MKT_SLOPE_MIN":null}"#.utf8))
        #expect(old.buyMinPoints == nil)
        #expect(old.buyBounceOffLow == nil)
        #expect(old.buyLowAgeH == nil)
        #expect(old.buySlopeMin == nil)
        // 非 rules 形状（null / 缺整个对象）退全 nil 兜底
        #expect(try JSONDecoder().decode(MarketRules.self, from: Data("null".utf8)) == MarketRules())
    }

    @Test("season 赛季日历解码：全字段可空宽松保形，缺字段不炸")
    func decodeSeason() throws {
        // 真实留档样本形状（market-sample.json 顶层 season：name/start/end/fetchedAt/events，
        // fetchedAt 客户端不消费、解码端忽略）
        let json = #"{"name":"S11赛季","start":"2026-09-04T02:00:00+08:00","end":"2026-11-05T01:59:59+08:00","fetchedAt":"2026-10-27T09:01:27.361Z","events":[{"name":"群星 赛季","start":"2026-09-04T02:00:00+08:00","end":"2026-11-05T01:59:59+08:00","type":"ingame"}]}"#
        let s = try JSONDecoder().decode(Season.self, from: Data(json.utf8))
        #expect(s.name == "S11赛季")
        #expect(s.events?.count == 1)
        #expect(s.events?.first?.type == "ingame")
        // 旧快照 / 上游失败缺字段：整字段缺省 → 快照解码不炸（MarketSnapshot.season 为可选）
        let snap = try JSONDecoder.deltaForce().decode(MarketSnapshot.self, from: Data(#"{"version":"202610271300","fetchedAt":"2026-10-27T05:00:00.000Z","generatedAt":"2026-10-27T05:00:01.000Z","source":"moligod","items":[]}"#.utf8))
        #expect(snap.season == nil)
        #expect(snap.rules == nil)
    }

    @Test("曲线点 [key, price] 自定义编解码往返")
    func curvePointRoundTrip() throws {
        let json = #"[["202610071100",288.5],["2026100712",290]]"#
        let pts = try JSONDecoder().decode([CurvePoint].self, from: Data(json.utf8))
        #expect(pts.count == 2)
        #expect(pts[0].key == "202610071100")
        #expect(pts[0].price == 288.5)
        let back = try JSONEncoder().encode(pts)
        let again = try JSONDecoder().decode([CurvePoint].self, from: back)
        #expect(again == pts)
    }

    @Test("SSE 事件负载 → LiveEvent")
    func liveEventParse() {
        let hello = LiveEvent.parse(SSEEvent(name: "hello", data: #"{"version":"202610201121","source":"moligod","generatedAt":"2026-10-20T03:23:17.111Z"}"#))
        #expect(hello == .hello(LivePing(version: "202610201121", source: "moligod", generatedAt: "2026-10-20T03:23:17.111Z")))
        let radar = LiveEvent.parse(SSEEvent(name: "radar", data: #"{"version":"202610200800","total":10,"anomaly":0,"buy":1,"sell":2}"#))
        if case .radar(let p) = radar {
            #expect(p.version == "202610200800")
            #expect(p.total == 10)
        } else {
            Issue.record("应为 radar 事件")
        }
        let broken = LiveEvent.parse(SSEEvent(name: "market", data: "not json"))
        #expect(broken == .market(LivePing(version: nil)))
        #expect(LiveEvent.parse(SSEEvent(name: "x", data: "y")) == .other(name: "x", data: "y"))
    }
}
