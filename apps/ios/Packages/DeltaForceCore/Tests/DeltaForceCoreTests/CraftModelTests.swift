// CraftModelTests.swift — 特勤处制造快照解码与最佳口径单测（fixtures/craft-sample.json）
import Foundation
import Testing
@testable import DeltaForceCore

@Suite("特勤处制造快照")
struct CraftModelTests {
    @Test("fixture 解码：顶层字段 / places 展示序 / stats 一致性")
    func decodeFixture() throws {
        let snap = try Fixtures.craft()
        #expect(snap.source == "moligod-craft")
        #expect(snap.version.count == 12)
        #expect(!snap.items.isEmpty)
        #expect(snap.places.count == 4)
        #expect(snap.places.map(\.id) == ["workbench", "armory", "tech", "pharmacy"])
        #expect(snap.places[0].label == "工作台")
        #expect(snap.stats.total == snap.items.count)
        #expect(snap.stats.complete == snap.items.filter(\.isComplete).count)
        #expect(snap.stats.profitable == snap.items.filter { $0.isComplete && ($0.profit ?? 0) > 0 }.count)
    }

    @Test("配方字段：利润公式 / 时利派生 / 缺价降级")
    func itemFields() throws {
        let snap = try Fixtures.craft()
        // 找一条价格完整的配方对账利润公式
        guard let it = snap.items.first(where: { $0.isComplete && $0.revenue != nil && $0.fee != nil && $0.cost != nil && $0.profit != nil }) else {
            Issue.record("fixture 应含价格完整配方"); return
        }
        let lhs = (it.revenue ?? 0) - (it.fee ?? 0) - (it.cost ?? 0)
        #expect(abs(lhs - (it.profit ?? 0)) < 5, "利润 = 收入 − 手续费 − 成本")
        if let ph = it.periodHours, ph > 0, let p = it.profit {
            #expect(abs(p / ph - (it.profitPerHour ?? .nan)) < 1e-6, "时利 = 利润 / 耗时")
        }
        // 缺价配方：missingPriceCount > 0 → isComplete false
        if let miss = snap.items.first(where: { $0.missingPriceCount > 0 }) {
            #expect(!miss.isComplete)
        }
    }

    @Test("最佳口径：价格完整中时利最大；place 过滤生效")
    func bestPicks() throws {
        let snap = try Fixtures.craft()
        let best = try #require(snap.best())
        let complete = snap.items.filter { $0.isComplete && $0.profitPerHour != nil }
        let maxHourly = complete.map(\.profitPerHour!).max()!
        #expect(abs((best.profitPerHour ?? 0) - maxHourly) < 1e-9)
        // 台内最佳不越界
        for p in snap.places {
            if let b = snap.best(place: p.id) {
                #expect(b.place == p.id)
                let inPlace = snap.items.filter { $0.place == p.id && $0.isComplete && $0.profitPerHour != nil }
                if let m = inPlace.map(\.profitPerHour!).max() {
                    #expect(abs((b.profitPerHour ?? 0) - m) < 1e-9)
                }
            }
        }
        #expect(snap.best(place: "no-such-place") == nil)
    }

    @Test("LivePing 解码 craft 事件负载（含 complete / profitable）")
    func livePingCraft() throws {
        let json = #"{"version":"202610231200","total":230,"complete":212,"profitable":153}"#
        let ping = try JSONDecoder.deltaForce().decode(LivePing.self, from: Data(json.utf8))
        #expect(ping.version == "202610231200")
        #expect(ping.total == 230 && ping.complete == 212 && ping.profitable == 153)
        // craft 事件映射
        let ev = LiveEvent.parse(SSEEvent(name: "craft", data: json))
        if case .craft(let p) = ev {
            #expect(p.version == "202610231200")
        } else {
            Issue.record("craft 事件应映射为 .craft")
        }
    }

    @Test("MarketMeta：moligod-craft 按分钟级档（10/30）")
    func craftStaleness() {
        let s = MarketMeta.staleness(source: "moligod-craft")
        #expect(s.staleDotMin == 10 && s.staleTipMin == 30)
        #expect(MarketMeta.sourceLabel("moligod-craft") == "分钟级")
    }
}
