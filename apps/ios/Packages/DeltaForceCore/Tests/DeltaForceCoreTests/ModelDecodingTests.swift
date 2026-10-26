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

    @Test("radar-sample.json：Top10、雷达字段齐全、异常条目强制观望")
    func decodeRadar() throws {
        let snap = try Fixtures.radar()
        #expect(snap.items.count == 10)
        #expect(snap.source == "kkrb-radar+moligod")
        #expect(snap.stats?.anomaly != nil)
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
