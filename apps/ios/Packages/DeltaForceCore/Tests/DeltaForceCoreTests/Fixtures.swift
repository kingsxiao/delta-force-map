// Fixtures.swift — 从仓库 shared/ 读取固定样本（单测与网页端 / 后端吃同一份契约样本）
import Foundation
@testable import DeltaForceCore

enum Fixtures {
    /// 自本文件向上找到含 shared/API.md 的仓库根
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appending(path: "shared/API.md").path) {
                return url
            }
        }
        fatalError("找不到仓库根（shared/API.md）")
    }()

    static func data(_ relative: String) throws -> Data {
        try Data(contentsOf: repoRoot.appending(path: relative))
    }

    static func market() throws -> MarketSnapshot {
        try JSONDecoder.deltaForce().decode(MarketSnapshot.self, from: data("shared/fixtures/market-sample.json"))
    }

    static func radar() throws -> MarketSnapshot {
        try JSONDecoder.deltaForce().decode(MarketSnapshot.self, from: data("shared/fixtures/radar-sample.json"))
    }

    static func ttk() throws -> TtkData {
        try TtkData.load(from: data("shared/data/ttk.json"))
    }

    /// 合成曲线：从 2026-10-07 00:00 起逐小时，价格由闭包给出
    static func curve(hours: Int, start: (y: Int, m: Int, d: Int) = (2026, 10, 7), price: (Int) -> Double) -> [CurvePoint] {
        var out: [CurvePoint] = []
        let cal = SellEtaEngine.beijing
        var date = cal.date(from: DateComponents(year: start.y, month: start.m, day: start.d, hour: 0))!
        for i in 0..<hours {
            let c = cal.dateComponents([.year, .month, .day, .hour], from: date)
            let key = String(format: "%04d%02d%02d%02d00", c.year!, c.month!, c.day!, c.hour!)
            out.append(CurvePoint(key: key, price: price(i)))
            date = cal.date(byAdding: .hour, value: 1, to: date)!
        }
        return out
    }

    static func item(name: String = "测试弹", current: Double?, targetSell: Double?, curve: [CurvePoint], signal: Signal = .wait, rank: Double? = 0.5) -> MarketItem {
        MarketItem(name: name, current: current, curve: curve, rank: rank, targetSell: targetSell, signal: signal)
    }
}
