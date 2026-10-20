// NotifyPolicyTests.swift — notify-policy.mjs judgeSignals 去抖语义对账
import Foundation
import Testing
@testable import DeltaForceCore

@Suite("通知去抖 NotifyPolicy")
struct NotifyPolicyTests {
    private func mk(_ name: String, _ signal: Signal, _ current: Double) -> MarketItem {
        MarketItem(name: name, current: current, curve: [], rank: 0.2, signal: signal)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("首次出现立即通知；同信号连续轮不重复")
    func firstAppearance() {
        var state = NotifyState()
        let r1 = NotifyEngine.judge(state: &state, items: [mk("A", .buy, 100), mk("B", .wait, 50)], now: t0)
        #expect(r1.buys.map(\.name) == ["A"])
        #expect(r1.sells.isEmpty)
        #expect(state.items["A"]?.runNotified == true)
        #expect(state.items["B"]?.runNotified == true) // WAIT 也「首次出现」记为已通知（JS 语义），只是不进 buys/sells
        let r2 = NotifyEngine.judge(state: &state, items: [mk("A", .buy, 100)], now: t0.addingTimeInterval(60))
        #expect(r2.isEmpty)
        #expect(state.items["A"]?.streak == 2)
    }

    @Test("信号切换需连续两轮确认")
    func switchNeedsStreak() {
        var state = NotifyState()
        _ = NotifyEngine.judge(state: &state, items: [mk("A", .buy, 100)], now: t0)
        let r2 = NotifyEngine.judge(state: &state, items: [mk("A", .sell, 140)], now: t0.addingTimeInterval(60))
        #expect(r2.isEmpty) // 切换当轮不报
        #expect(state.items["A"]?.streak == 1)
        #expect(state.items["A"]?.runNotified == false)
        let r3 = NotifyEngine.judge(state: &state, items: [mk("A", .sell, 141)], now: t0.addingTimeInterval(120))
        #expect(r3.sells.map(\.name) == ["A"]) // 确认轮
        #expect(state.items["A"]?.runNotified == true)
        let r4 = NotifyEngine.judge(state: &state, items: [mk("A", .sell, 141)], now: t0.addingTimeInterval(180))
        #expect(r4.isEmpty)
    }

    @Test("同信号 6 小时冷却到期重报")
    func cooldown() {
        var state = NotifyState()
        _ = NotifyEngine.judge(state: &state, items: [mk("A", .buy, 100)], now: t0)
        let before = NotifyEngine.judge(state: &state, items: [mk("A", .buy, 100)], now: t0.addingTimeInterval(6 * 3600 - 1))
        #expect(before.isEmpty)
        let after = NotifyEngine.judge(state: &state, items: [mk("A", .buy, 100)], now: t0.addingTimeInterval(6 * 3600))
        #expect(after.buys.map(\.name) == ["A"])
    }

    @Test("BUY 冷却期内较上次通知价累计再跌 5% 重报，参考价只在触发时刷新")
    func redrop() {
        var state = NotifyState()
        _ = NotifyEngine.judge(state: &state, items: [mk("A", .buy, 100)], now: t0)
        let r2 = NotifyEngine.judge(state: &state, items: [mk("A", .buy, 96)], now: t0.addingTimeInterval(60))
        #expect(r2.isEmpty)
        #expect(state.items["A"]?.refPrice == 100) // 渐进阴跌：参考价不随观察价漂移
        let r3 = NotifyEngine.judge(state: &state, items: [mk("A", .buy, 94)], now: t0.addingTimeInterval(120))
        #expect(r3.buys.map(\.name) == ["A"]) // 累计 -6% 触发
        #expect(state.items["A"]?.refPrice == 94)
        let r4 = NotifyEngine.judge(state: &state, items: [mk("A", .buy, 90)], now: t0.addingTimeInterval(180))
        #expect(r4.isEmpty) // 相对 94 只跌 4.3%
    }

    @Test("消失的物品从 state 中移除；--no-notify 式静默也逐轮推进（state 全量重写）")
    func stateRewrite() {
        var state = NotifyState()
        _ = NotifyEngine.judge(state: &state, items: [mk("A", .buy, 100), mk("B", .sell, 10)], now: t0)
        _ = NotifyEngine.judge(state: &state, items: [mk("A", .buy, 100)], now: t0.addingTimeInterval(60))
        #expect(state.items["B"] == nil)
        #expect(state.items.count == 1)
    }

    @Test("通知文案与 notify-policy 同格式")
    func lines() throws {
        let snap = try Fixtures.market()
        if let buy = snap.items.first(where: { $0.signal == .buy }) {
            let line = NotifyEngine.buyLine(buy)
            #expect(line.hasPrefix(buy.name))
            #expect(line.contains("买入≤"))
            #expect(line.contains("挂卖"))
            #expect(line.contains("预赚"))
            #expect(line.contains("7天高点到手"))
        }
        if let sell = snap.items.first(where: { $0.signal == .sell }) {
            let line = NotifyEngine.sellLine(sell)
            #expect(line.contains("处7天"))
            #expect(line.hasSuffix("建议挂卖"))
        }
        // state 可 JSON 持久化往返
        var state = NotifyState()
        _ = NotifyEngine.judge(state: &state, items: snap.items, now: t0)
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(NotifyState.self, from: data)
        #expect(back == state)
    }
}
