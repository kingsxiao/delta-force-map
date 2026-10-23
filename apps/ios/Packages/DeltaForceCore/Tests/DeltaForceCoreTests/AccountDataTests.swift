// AccountDataTests.swift — 账号云数据口径单测（与 server/auth/selftest.mjs ①
// 及 shared/js/accountData.js 逐项对账；同构移植的正确性由两侧用例一致保证）
import Foundation
import Testing
@testable import DeltaForceCore

@Test func 星标并集_去重排序() {
    #expect(mergeStars(local: ["b", "a"], remote: ["a", "c"]) == ["a", "b", "c"])
    #expect(mergeStars(local: [], remote: []) == [])
    #expect(mergeStars(local: ["a"], remote: []) == ["a"])
    #expect(mergeStars(local: ["弹A", "弹B"], remote: ["弹B", "弹C"]) == ["弹B", "弹C", "弹A"].sorted())
    // 空串剔除（与 JS mergeStars 输入清洗同口径）
    #expect(mergeStars(local: ["弹A", ""], remote: ["弹B"]) == ["弹A", "弹B"])
    #expect(mergeStars(local: [""], remote: [""]) == [])
}

@Test func stringArray_剔除非字符串与空串() {
    let value = AccountValue.array([.string("a"), .number(1), .null, .string(""), .string("b")])
    #expect(value.stringArray == ["a", "b"])
    #expect(AccountValue.string("a").stringArray == nil)
    #expect(AccountValue.null.stringArray == nil)
}

@Test func 文档校验_键名规则() {
    #expect(normalizeAccountDoc(["stars.ammo": AccountValue.array([.string("a")])]) != nil)
    #expect(normalizeAccountDoc(["bad key!": AccountValue.number(1)]) == nil)
    #expect(normalizeAccountDoc(["": AccountValue.number(1)]) == nil)
    #expect(normalizeAccountDoc([String(repeating: "k", count: 65): AccountValue.number(1)]) == nil)
    // 中文键不合法（JS 侧 KEY_RE 同为 ASCII 集合）
    #expect(normalizeAccountDoc(["中文键": AccountValue.number(1)]) == nil)
}

@Test func 文档校验_64KB上限() {
    let big = ["stars.ammo": AccountValue.array([.string(String(repeating: "x", count: 1000))])]
    #expect(normalizeAccountDoc(big) != nil)
    let huge = ["k": AccountValue.string(String(repeating: "y", count: accountDocMaxBytes))]
    #expect(normalizeAccountDoc(huge) == nil)
}

@Test func AccountValue_JSON往返() throws {
    let doc: [String: AccountValue] = [
        "stars.ammo": .array([.string("弹A"), .string("弹B")]),
        "flag": .bool(true),
        "num": .number(3.14),
        "inner": .object(["k": .null]),
    ]
    let data = try JSONEncoder().encode(doc)
    let back = try JSONDecoder().decode([String: AccountValue].self, from: data)
    #expect(back == doc)
    // Bool 不被 Number 吞掉
    #expect(back["flag"] == .bool(true))
    #expect(back["num"] == .number(3.14))
}

@Test func AuthUser_解码形状() throws {
    let json = #"{"uid":"0123456789abcdef","username":"玩家一号","createdAt":"2026-10-22T08:00:00.000Z"}"#
    let user = try JSONDecoder.deltaForce().decode(AuthUser.self, from: Data(json.utf8))
    #expect(user.uid == "0123456789abcdef")
    #expect(user.username == "玩家一号")
}

@Test func APIError_401语义() {
    #expect(APIError.server(code: "BAD_TOKEN", message: "x").isAuthExpired)
    #expect(APIError.server(code: "TOKEN_EXPIRED", message: "x").isAuthExpired)
    #expect(!APIError.server(code: "AUTH_FAILED", message: "x").isAuthExpired)
    #expect(!APIError.badStatus(500).isAuthExpired)
}

@Test func 台账合并_按名并集_同名本地优先() {
    let local = [
        LedgerEntry(name: "弹B", qty: 100, cost: 300),
        LedgerEntry(name: "弹A", qty: 50, cost: 200),
    ]
    let remote = [
        LedgerEntry(name: "弹A", qty: 999, cost: 1), // 同名：本地优先，远端丢弃
        LedgerEntry(name: "弹C", qty: 10, cost: 50),
    ]
    let merged = mergePositions(local: local, remote: remote)
    #expect(merged.map(\.name) == ["弹A", "弹B", "弹C"])
    #expect(merged[0].qty == 50 && merged[0].cost == 200) // 本地的弹A胜出
    #expect(mergePositions(local: [], remote: []) == [])
}

@Test func ledgerArray_剔除非法条目并钳位() {
    let value = AccountValue.array([
        .object(["name": .string("弹A"), "qty": .number(2.6), "cost": .number(300)]),
        .object(["name": .string(""), "qty": .number(1), "cost": .number(1)]), // 空名剔除
        .object(["name": .string("弹B"), "qty": .string("x"), "cost": .number(1)]), // qty 非数剔除
        .object(["name": .string("弹C"), "qty": .number(0), "cost": .number(-5)]), // 钳位 qty≥1 cost≥0
        .string("不是对象"),
    ])
    let list = value.ledgerArray
    #expect(list?.count == 2)
    #expect(list?[0].name == "弹A" && list?[0].qty == 3) // 2.6 → 四舍五入 3
    #expect(list?[1].name == "弹C" && list?[1].qty == 1 && list?[1].cost == 0)
    #expect(AccountValue.string("x").ledgerArray == nil)
}

@Test func ledgerArray_超大有限qty不崩_退哨兵() {
    // 1e300 isFinite=true 可从云端解出，Int() 强转会 trap 崩 App（web 侧
    // loadSanitized 无上限即可落盘；Int(exactly:) 落空退哨兵，同 TtkEngine 手法）
    let value = AccountValue.array([
        .object(["name": .string("弹A"), "qty": .number(1e300), "cost": .number(300)]),
        .object(["name": .string("弹B"), "qty": .number(-1e300), "cost": .number(1)]), // 负向溢出同理
        .object(["name": .string("弹C"), "qty": .number(.infinity), "cost": .number(1)]), // 非有限仍剔除
    ])
    let list = value.ledgerArray
    #expect(list?.count == 2)
    #expect(list?[0].name == "弹A" && list?[0].qty == Int.max) // 溢出退哨兵而非 trap
    #expect(list?[1].name == "弹B" && list?[1].qty == 1) // max(1, …) 钳位兜住负向哨兵
}
