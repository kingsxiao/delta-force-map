// TtkEngineTests.swift — 与网页端 model.js 逐发对账
// 期望值由 node 直接跑 apps/web/src/data/ttk/model.js + 同一份数据算出（见 git 记录），
// 任一值漂移即说明 Swift 移植或 shared/data/ttk.json 导出与网页端不一致。
import Foundation
import Testing
@testable import DeltaForceCore

@Suite("TTK 引擎")
struct TtkEngineTests {
    struct Expect {
        let gun: String, cal: String, ammo: String, al: Int, part: String
        let btk: Int, broke: Int, pass: Double, flesh: Double, noArmorBtk: Int, ttk: Double
    }

    static let expectations: [Expect] = [
        .init(gun: "AKM", cal: "76239", ammo: "BP", al: 4, part: "chest", btk: 4, broke: 3, pass: 0.5, flesh: 40, noArmorBtk: 3, ttk: 300),
        .init(gun: "M4A1", cal: "556", ammo: "M995", al: 6, part: "head", btk: 4, broke: 2, pass: 0, flesh: 55.1, noArmorBtk: 2, ttk: 225),
        .init(gun: "维克托", cal: "45", ammo: "RIP", al: 2, part: "belly", btk: 3, broke: 0, pass: 1, flesh: 37.44, noArmorBtk: 3, ttk: 109.9908),
        .init(gun: "RM277", cal: "68", ammo: "FMJ", al: 3, part: "belly", btk: 3, broke: 2, pass: 0.75, flesh: 41, noArmorBtk: 3, ttk: 218.1818),
        .init(gun: "AWM", cal: "338", ammo: ".338 AP", al: 6, part: "chest", btk: 2, broke: 2, pass: 0.75, flesh: 100, noArmorBtk: 1, ttk: 1714.2857),
        .init(gun: "M870", cal: "12ga", ammo: "独头 APX", al: 5, part: "chest", btk: 5, broke: 1, pass: 0, flesh: 28, noArmorBtk: 4, ttk: 3243.2432),
        .init(gun: "G18", cal: "919", ammo: "PSO", al: 3, part: "chest", btk: 10, broke: 5, pass: 0, flesh: 23, noArmorBtk: 5, ttk: 460.7509),
        .init(gun: "SVD", cal: "547", ammo: "SNB", al: 0, part: "head", btk: 1, broke: 0, pass: 1, flesh: 106.4, noArmorBtk: 1, ttk: 0),
    ]

    @Test("数据导出：68 枪 / 20 口径 / 93 弹药 / 7 兵种 / 3 部位，枪的口径都能找到")
    func dataShape() throws {
        let d = try Fixtures.ttk()
        #expect(d.guns.count == 68)
        #expect(d.calibers.count == 20)
        #expect(d.calibers.values.reduce(0) { $0 + $1.ammo.count } == 93)
        #expect(d.classes.map(\.id) == ["ar", "smg", "dmr", "snp", "lmg", "sg", "pst"])
        #expect(d.parts.map(\.id) == ["chest", "belly", "head"])
        #expect(d.armor.dur["6"] == 150)
        #expect(d.armor.headDur["6"] == 60)
        for g in d.guns { #expect(d.calibers[g.cal] != nil, Comment(rawValue: g.zh)) }
        #expect(d.guns.first { $0.zh == "RM277" }?.belly == 1.0)
        #expect(d.guns.first { $0.zh == "M16A4" }?.burst == true)
    }

    @Test("穿透 × 护甲判定矩阵")
    func passRate() {
        #expect(TtkEngine.passRate(pen: 0, armor: 0) == 1)
        #expect(TtkEngine.passRate(pen: 1, armor: 0) == 1)
        #expect(TtkEngine.passRate(pen: 3, armor: 3) == 0.5)
        #expect(TtkEngine.passRate(pen: 4, armor: 3) == 0.75)
        #expect(TtkEngine.passRate(pen: 5, armor: 3) == 1)
        #expect(TtkEngine.passRate(pen: 2, armor: 3) == 0)
        #expect(TtkEngine.passRate(pen: 7, armor: 6) == 0.75)
    }

    @Test("部位耐久覆盖规则：腹部 1-2 级甲不覆盖、头部用头盔表")
    func durability() throws {
        let d = try Fixtures.ttk()
        let chest = d.part("chest")!, belly = d.part("belly")!, head = d.part("head")!
        #expect(TtkEngine.durability(part: chest, armorLevel: 2, tables: d.armor) == 40)
        #expect(TtkEngine.durability(part: belly, armorLevel: 2, tables: d.armor) == 0)
        #expect(TtkEngine.durability(part: belly, armorLevel: 3, tables: d.armor) == 75)
        #expect(TtkEngine.durability(part: head, armorLevel: 4, tables: d.armor) == 48)
        #expect(TtkEngine.durability(part: chest, armorLevel: 0, tables: d.armor) == 0)
    }

    @Test("逐发模拟与网页端 model.js 结果一致", arguments: expectations)
    func combos(e: Expect) throws {
        let d = try Fixtures.ttk()
        let gun = try #require(d.guns.first { $0.zh == e.gun })
        let ammo = try #require(d.calibers[e.cal]?.ammo.first { $0.n == e.ammo })
        let part = try #require(d.part(e.part))
        let r = TtkEngine.combo(gun: gun, ammo: ammo, armorLevel: e.al, part: part, tables: d.armor)
        #expect(r.btk == e.btk)
        #expect(r.sim.broke == e.broke)
        #expect(r.sim.pass == e.pass)
        #expect(abs(r.sim.flesh - e.flesh) < 1e-6)
        #expect(r.sim.noArmorBtk == e.noArmorBtk)
        #expect(abs(r.ttk - e.ttk) < 1e-3)
    }

    @Test("排行：每枪最佳 = 该兵种枪数；全部组合 ≥ 每枪最佳；TTK 单调不减")
    func ranking() throws {
        let d = try Fixtures.ttk()
        let best = TtkEngine.ranking(data: d, classId: "ar", partId: "chest", armorLevel: 4, filter: .bestPerGun)
        #expect(best.count == d.guns(in: "ar").count)
        #expect(Set(best.map(\.gun.zh)).count == best.count)
        let all = TtkEngine.ranking(data: d, classId: "ar", partId: "chest", armorLevel: 4, filter: .all)
        #expect(all.count >= best.count)
        for i in 1..<all.count { #expect(all[i - 1].ttk <= all[i].ttk) }
        let pen5 = TtkEngine.ranking(data: d, classId: nil, partId: "head", armorLevel: 6, filter: .pen(5))
        #expect(pen5.allSatisfy { $0.ammo.pen == 5 })
        #expect(!pen5.isEmpty)
        let perGun = TtkEngine.combos(data: d, gun: d.guns.first { $0.zh == "AKM" }!, partId: "chest", armorLevel: 4)
        #expect(perGun.count == d.calibers["76239"]!.ammo.count)
    }
}
