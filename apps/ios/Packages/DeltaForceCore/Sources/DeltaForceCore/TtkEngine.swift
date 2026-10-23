// TtkEngine.swift — TTK 计算模型（apps/web/src/data/ttk/model.js 的同构移植）+ 数据加载
// 数据来自 shared/data/ttk.json（npm run export:ios 从网页端 JS 模块确定性导出，单一事实来源）。
// 计算口径一字不差：
//   · passRate：弹药穿透等级 × 护甲等级 → 伤害通过率（0 / 50% / 75% / 100%）
//   · simulate：逐发模拟「碎甲 — 掉血」，返回击杀发数与碎甲用弹数
//   · ttk = (BTK − 1) × 60000 / RPM（首发命中即刻出膛，不计入时间）
import Foundation

public struct GunClass: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
}

public struct Gun: Codable, Sendable, Hashable, Identifiable {
    public var id: String { zh }
    public let zh: String
    public let en: String
    public let cls: String
    /// 肉伤面板
    public let dmg: Double
    /// 甲伤面板
    public let admg: Double
    public let rpm: Double
    public let cal: String
    public let mag: Int
    /// 三连发武器：面板射速为含 burst 间隔的均值
    public let burst: Bool?
    /// 腹部倍率覆盖（RM277 / MK4 胸腹同伤）
    public let belly: Double?
    public let est: Bool?
    public let note: String?
    /// 官方渲染图 objectID（apps/web/public/guns/<img>.webp，iOS 以文件夹引用捆绑）
    public let img: String?
}

public struct Ammo: Codable, Sendable, Hashable, Identifiable {
    public var id: String { n }
    public let n: String
    public let pen: Int
    /// 肉伤系数（默认 1）
    public let flesh: Double?
    /// 甲伤系数（默认 1）
    public let amult: Double?
    public let est: Bool?
    public let note: String?
}

public struct Caliber: Codable, Sendable, Hashable {
    public let label: String
    public let sub: String
    public let base: Double
    public let armor: Double
    public let est: Bool?
    public let note: String?
    public let ammo: [Ammo]
}

public struct ArmorMeta: Codable, Sendable, Hashable {
    public let lv: Int
    public let name: String
    public let short: String?
}

public struct ArmorTables: Codable, Sendable, Hashable {
    /// 护甲满耐久，键 "1"…"6"
    public let dur: [String: Double]
    /// 头盔满耐久，键 "1"…"6"
    public let headDur: [String: Double]
    public let meta: [ArmorMeta]
}

public struct BodyPart: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let mult: Double
    /// armor / armorLv3Plus / helmet（export-ios-data.mjs 把 PARTS.dur 函数枚举化）
    public let coverRule: String
    public let hint: String?
}

public struct TtkData: Codable, Sendable, Hashable {
    public let generatedFrom: String?
    public let classes: [GunClass]
    public let guns: [Gun]
    public let calibers: [String: Caliber]
    public let armor: ArmorTables
    public let parts: [BodyPart]

    public static func load(from data: Data) throws -> TtkData {
        try JSONDecoder().decode(TtkData.self, from: data)
    }

    public func part(_ id: String) -> BodyPart? { parts.first { $0.id == id } }
    public func caliber(for gun: Gun) -> Caliber? { calibers[gun.cal] }
    public func guns(in classId: String?) -> [Gun] {
        guard let classId else { return guns }
        return guns.filter { $0.cls == classId }
    }
}

public struct SimResult: Sendable, Hashable {
    public let btk: Int
    public let broke: Int
    public let pass: Double
    public let flesh: Double
    public let noArmorBtk: Int
}

public struct ComboResult: Sendable, Hashable, Identifiable {
    public var id: String { "\(gun.zh)|\(ammo.n)" }
    public let gun: Gun
    public let ammo: Ammo
    public let sim: SimResult
    public let ttk: Double

    public var btk: Int { sim.btk }
}

public enum AmmoFilter: Sendable, Hashable {
    case bestPerGun
    case all
    case pen(Int)
}

public enum TtkEngine {
    /// 穿透 × 护甲 → 通过率
    public static func passRate(pen: Int, armor al: Int) -> Double {
        if al <= 0 { return 1 }
        let d = pen - al
        if d < 0 { return 0 }
        if d == 0 { return 0.5 }
        if d == 1 { return 0.75 }
        return 1
    }

    /// 部位在 al 级甲下的有效耐久（腹部 1-2 级甲不覆盖按无甲计；头部用头盔表）
    public static func durability(part: BodyPart, armorLevel al: Int, tables: ArmorTables) -> Double {
        switch part.coverRule {
        case "armor": return al > 0 ? (tables.dur[String(al)] ?? 0) : 0
        case "armorLv3Plus": return al >= 3 ? (tables.dur[String(al)] ?? 0) : 0
        case "helmet": return al > 0 ? (tables.headDur[String(al)] ?? 0) : 0
        default: return 0
        }
    }

    /// 逐发模拟：返回击杀所需发数与碎甲用弹数
    public static func simulate(gun: Gun, ammo: Ammo, armorLevel al: Int, part: BodyPart, tables: ArmorTables) -> SimResult {
        var mult = part.mult
        if let belly = gun.belly, part.id == "belly" { mult = belly }
        let fleshFull = gun.dmg * (ammo.flesh ?? 1) * mult
        let dur = durability(part: part, armorLevel: al, tables: tables)
        let admg = gun.admg * (ammo.amult ?? 1)
        let pass = dur > 0 ? passRate(pen: ammo.pen, armor: al) : 1
        var hp = 100.0
        var left = dur
        var n = 0
        var broke = 0
        let guardMax = 300
        while hp > 1e-9, n < guardMax {
            n += 1
            let d: Double
            if left > 0 {
                let k = min(1, left / admg)
                d = fleshFull * (k * pass + (1 - k))
                left -= admg
                broke += 1
            } else {
                d = fleshFull
            }
            hp -= d
        }
        return SimResult(
            btk: n,
            broke: broke,
            pass: pass,
            flesh: fleshFull,
            noArmorBtk: max(1, Int((100 / fleshFull).rounded(.up)))
        )
    }

    public static func ttk(btk: Int, rpm: Double) -> Double {
        Double(btk - 1) * 60000 / rpm
    }

    public static func combo(gun: Gun, ammo: Ammo, armorLevel al: Int, part: BodyPart, tables: ArmorTables) -> ComboResult {
        let sim = simulate(gun: gun, ammo: ammo, armorLevel: al, part: part, tables: tables)
        return ComboResult(gun: gun, ammo: ammo, sim: sim, ttk: ttk(btk: sim.btk, rpm: gun.rpm))
    }

    /// 排行：按 TTK 升序（同 TTK 按 BTK、碎甲发数、枪名稳定排序）
    public static func ranking(
        data: TtkData, classId: String?, partId: String, armorLevel: Int, filter: AmmoFilter
    ) -> [ComboResult] {
        guard let part = data.part(partId) else { return [] }
        var out: [ComboResult] = []
        for gun in data.guns(in: classId) {
            guard let cal = data.calibers[gun.cal] else { continue }
            let ammos: [Ammo]
            switch filter {
            case .pen(let p): ammos = cal.ammo.filter { $0.pen == p }
            default: ammos = cal.ammo
            }
            let combos = ammos.map { combo(gun: gun, ammo: $0, armorLevel: armorLevel, part: part, tables: data.armor) }
            if case .bestPerGun = filter {
                if let best = combos.min(by: order) { out.append(best) }
            } else {
                out.append(contentsOf: combos)
            }
        }
        return out.sorted(by: order)
    }

    /// 单枪全部弹药对比（详情展开用）
    public static func combos(data: TtkData, gun: Gun, partId: String, armorLevel: Int) -> [ComboResult] {
        guard let part = data.part(partId), let cal = data.calibers[gun.cal] else { return [] }
        return cal.ammo
            .map { combo(gun: gun, ammo: $0, armorLevel: armorLevel, part: part, tables: data.armor) }
            .sorted(by: order)
    }

    static func order(_ a: ComboResult, _ b: ComboResult) -> Bool {
        if a.ttk != b.ttk { return a.ttk < b.ttk }
        if a.btk != b.btk { return a.btk < b.btk }
        if a.sim.broke != b.sim.broke { return a.sim.broke < b.sim.broke }
        if a.gun.zh != b.gun.zh { return a.gun.zh < b.gun.zh }
        return a.ammo.n < b.ammo.n
    }
}
