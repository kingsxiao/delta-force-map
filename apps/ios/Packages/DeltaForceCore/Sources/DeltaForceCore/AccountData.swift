// AccountData.swift — 账号云数据口径（契约 shared/API.md §6.3，
// shared/js/accountData.js 的同构移植；单测与 JS selftest 逐项对账）
//
// 云数据 = 不透明 K/V 文档：服务端只存不解析，键名与合并规则三端共用。
// 已约定键：stars.ammo = [String]（子弹自选弹名）。
import Foundation

/// 任意 JSON 值（云数据文档的值类型；Hashable 供测试断言）
public enum AccountValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AccountValue])
    case object([String: AccountValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        // 顺序即优先级：Bool 必须在 Number 前（否则 true 会被当 1.0）
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([AccountValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: AccountValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "不支持的 JSON 值"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// 字符串数组视图（stars.ammo 取值用）：剔除非字符串与空串，与 JS mergeStars 的输入清洗同口径
    public var stringArray: [String]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap { item -> String? in
            guard case .string(let s) = item, !s.isEmpty else { return nil }
            return s
        }
    }
}

/// 账号用户（契约 §6.2：uid 16 位 hex / username / createdAt ISO-8601）
public struct AuthUser: Codable, Sendable, Hashable {
    public let uid: String
    public let username: String
    public let createdAt: String

    public init(uid: String, username: String, createdAt: String) {
        self.uid = uid
        self.username = username
        self.createdAt = createdAt
    }
}

/// 注册 / 登录返回的会话（token 无状态签名令牌，有效期 30 天）
public struct AuthSession: Codable, Sendable, Hashable {
    public let token: String
    public let user: AuthUser
}

/// GET /api/account/data 响应：{data, savedAt}（savedAt 无数据时为 null）
public struct AccountDataEnvelope: Codable, Sendable {
    public let data: [String: AccountValue]
    public let savedAt: String?
}

/// 文档序列化后的大小上限（字节），与 JS 侧 ACCOUNT_DOC_MAX_BYTES 一致
public let accountDocMaxBytes = 64 * 1024

/// K/V 键名规则：字母 / 数字 / 点 / 下划线 / 短横线，1–64 字符。
/// 与 JS 侧 KEY_RE（`^[A-Za-z0-9._-]{1,64}$`）逐字节一致：只认 ASCII，
/// 不用 Character.isLetter（那是 Unicode 语义，中文也算字母会放开键名）。
private func isValidKey(_ k: String) -> Bool {
    let bytes = Array(k.utf8)
    guard (1...64).contains(bytes.count) else { return false }
    return bytes.allSatisfy { b in
        (b >= 0x41 && b <= 0x5A) // A-Z
            || (b >= 0x61 && b <= 0x7A) // a-z
            || (b >= 0x30 && b <= 0x39) // 0-9
            || b == 0x2E // .
            || b == 0x5F // _
            || b == 0x2D // -
    }
}

/// 校验并规范化账号数据文档（上传前客户端预检，与服务端同口径）。
/// 尺寸口径与 JS 逐字节对齐：2 + Σ(键长 + 值序列化长 + 4)。
public func normalizeAccountDoc(_ doc: [String: AccountValue]) -> [String: AccountValue]? {
    let encoder = JSONEncoder()
    var size = 2
    for (k, v) in doc {
        guard isValidKey(k), let payload = try? encoder.encode(v) else { return nil }
        size += k.utf8.count + payload.count + 4
        if size > accountDocMaxBytes { return nil }
    }
    return doc
}

/// 合并两端自选星标：并集、去重、剔除空串、按名排序（首次登录 / 多端合并，不丢任何一端数据）。
/// 空串过滤与 JS mergeStars 的输入清洗（typeof n === 'string' && n）同口径
public func mergeStars(local: [String], remote: [String]) -> [String] {
    Set(local.filter { !$0.isEmpty })
        .union(remote.filter { !$0.isEmpty })
        .sorted()
}

// MARK: - 囤货台账（键 ledger.ammo 的合并口径，与 shared/js/accountData.js 同构）

/// 台账条目：弹名 + 数量 + 成本单价（哈夫币/发）+ 记账时刻（epoch ms，可选）。
/// Codable 形状 = 客户端存储与云端 K/V 的 ledger.ammo（契约 shared/API.md §6.3）。
public struct LedgerEntry: Codable, Sendable, Hashable {
    public var name: String
    public var qty: Int
    public var cost: Double
    /// 记账时刻 epoch ms；nil = 旧条目未记录（合成 Codable 对 Optional 走
    /// decodeIfPresent / encodeIfPresent，旧存档与旧云文档双向兼容）
    public var at: Double?

    public init(name: String, qty: Int, cost: Double, at: Double? = nil) {
        self.name = name
        self.qty = qty
        self.cost = cost
        self.at = at
    }
}

/// 台账条目在 AccountValue 上的视图（云文档取值用）
extension AccountValue {
    public var ledgerEntry: LedgerEntry? {
        guard case .object(let o) = self,
              case .string(let name) = o["name"] ?? .null, !name.isEmpty
        else { return nil }
        let qty: Double
        if case .number(let n) = o["qty"] ?? .null { qty = n } else { return nil }
        let cost: Double
        if case .number(let c) = o["cost"] ?? .null { cost = c } else { return nil }
        guard qty.isFinite, cost.isFinite else { return nil }
        // at 记账时刻（可选）：只认 JSON number 且 > 0，其余（缺键 / 字符串 /
        // 非正数）一律剔除为 nil——与 shared/js/accountData.js normalizePosition
        // 同一清洗口径，同一云文档两端清洗后形状一致
        var at: Double?
        if case .number(let a) = o["at"] ?? .null, a.isFinite, a > 0 { at = a }
        // qty 是有限但超出 Int64 范围的值（如 1e300，web 侧 loadSanitized 无上限
        // 即可落盘）时 Int() 强转会 trap 崩 App——Int(exactly:) 落空按方向退哨兵
        // （正向 Int.max / 负向 1，max(1,·) 本就把一切 ≤1 钳到 1），同 TtkEngine
        // 的防崩手法
        return LedgerEntry(name: name, qty: max(1, Int(exactly: qty.rounded()) ?? (qty > 0 ? Int.max : 1)), cost: max(0, cost), at: at)
    }

    /// 台账数组视图（ledger.ammo 取值用）：剔除非法条目
    public var ledgerArray: [LedgerEntry]? {
        guard case .array(let items) = self else { return nil }
        return items.compactMap(\.ledgerEntry)
    }
}

/// 合并两端的囤货台账：按弹名并集，**同名冲突本地优先**（登录合并发生在
/// 用户正在用的设备上，本地刚改过的数字更可信）。结果按弹名排序。
public func mergePositions(local: [LedgerEntry], remote: [LedgerEntry]) -> [LedgerEntry] {
    var byName: [String: LedgerEntry] = [:]
    // 先放远端、后放本地：本地同名覆盖远端（与 JS 侧口径一致）
    for p in remote { byName[p.name] = p }
    for p in local { byName[p.name] = p }
    return byName.values.sorted { $0.name < $1.name }
}
