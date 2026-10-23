// AuthStore.swift — 账号会话与云同步状态（token 存 Keychain，用户信息仅展示用存 UserDefaults）
// 数据流：登录 / 注册 → 拉云端与本地自选并集合并（AppModel 落回 FavoritesStore）
// → 云端回写；登录状态下用户点星标 → 2s 防抖整文档回推（保留云端其他键）。
// 登出：服务器使全部令牌失效（best-effort）→ 清本地会话；本地自选保留。
import DeltaForceCore
import Foundation
import Observation
import Security

// MARK: - Keychain 薄封装（零第三方依赖；token 是唯一凭证，不落 UserDefaults）

enum Keychain {
    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func set(_ value: String, service: String, account: String) {
        var query = baseQuery(service: service, account: account)
        let attr = SecItemCopyMatching(query as CFDictionary, nil)
        let update = [kSecValueData as String: Data(value.utf8)]
        if attr == errSecSuccess {
            SecItemUpdate(query as CFDictionary, update as CFDictionary)
        } else {
            query[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func get(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }
}

// MARK: - 账号状态

@MainActor
@Observable
final class AuthStore {
    /// 同步状态（idle 未登录/未同步；error 时 message 有值，本地功能不受影响）
    enum SyncState: Equatable {
        case idle, syncing, ok, error(message: String)
    }

    private static let tokenService = "com.kingsxiao.deltaforce.auth"
    private static let tokenAccount = "token"
    private static let userKey = "auth.user.v1"

    private(set) var user: AuthUser?
    private(set) var syncState: SyncState = .idle
    private(set) var lastSyncAt: Date?

    private let client: APIClient
    /// 云端文档缓存（上推保留其他键；登录拉取后有效）
    private var cloudDoc: [String: AccountValue] = [:]
    private var pushTask: Task<Void, Never>?
    private var started = false

    init(client: APIClient) {
        self.client = client
    }

    private var token: String? {
        get { Keychain.get(service: Self.tokenService, account: Self.tokenAccount) }
        set {
            if let newValue {
                Keychain.set(newValue, service: Self.tokenService, account: Self.tokenAccount)
            } else {
                Keychain.delete(service: Self.tokenService, account: Self.tokenAccount)
            }
        }
    }

    // MARK: - 启动恢复

    /// 启动时用存量 token 调 /me 恢复会话（静默：失败只清失效令牌）
    func restore() async {
        guard !started else { return }
        started = true
        guard let token else { return }
        do {
            user = try await client.me(token: token)
        } catch {
            if isAuthExpired(error) { clearLocal() }
        }
    }

    // MARK: - 登录 / 注册 / 登出

    func login(username: String, password: String) async throws {
        let session = try await client.login(username: username, password: password)
        adopt(session)
    }

    func register(username: String, password: String) async throws {
        let session = try await client.register(username: username, password: password)
        adopt(session)
    }

    private func adopt(_ session: AuthSession) {
        token = session.token
        user = session.user
        if let data = try? JSONEncoder().encode(session.user) {
            UserDefaults.standard.set(data, forKey: Self.userKey)
        }
    }

    /// 登出：服务器失效全部令牌（best-effort，不可达也已清本地）→ 清会话；本地自选保留
    func logout() async {
        let old = token
        clearLocal()
        cloudDoc = [:]
        pushTask?.cancel()
        syncState = .idle
        if let old {
            try? await client.logout(token: old)
        }
    }

    private func clearLocal() {
        token = nil
        user = nil
        UserDefaults.standard.removeObject(forKey: Self.userKey)
    }

    /// 401 语义（BAD_TOKEN / TOKEN_EXPIRED）：会话已失效，需清本地重登
    private func isAuthExpired(_ error: Error) -> Bool {
        (error as? APIError)?.isAuthExpired == true
    }

    // MARK: - 云同步（口径 shared/API.md §6.3；AppModel 负责把合并结果落回本地 Store）

    /// 本地用户数据快照（上推 / 合并的入参形状）
    struct LocalData {
        var stars: [String] = []
        var positions: [LedgerEntry] = []
    }

    /// 云端合并结果（nil = 同步失败；调用方按项落地）
    struct MergeResult {
        var stars: [String]?
        var positions: [LedgerEntry]?
    }

    private static func accountValue(_ positions: [LedgerEntry]) -> AccountValue {
        .array(positions.map { .object(["name": .string($0.name), "qty": .number(Double($0.qty)), "cost": .number($0.cost)]) })
    }

    /// 云端缓存里的两项（部分推送时补全另一项用）
    private var cloudStars: [String] { cloudDoc["stars.ammo"]?.stringArray ?? [] }
    private var cloudPositions: [LedgerEntry] { cloudDoc["ledger.ammo"]?.ledgerArray ?? [] }

    /// 拉云端并与本地合并（星标并集 / 台账按名并集·同名本地优先）：
    /// 合并结果回写云端（其他键原样保留），返回给调用方落回本地。
    func pullAndMerge(stars: [String], positions: [LedgerEntry]) async -> MergeResult {
        guard let token, user != nil else { return MergeResult(stars: nil, positions: nil) }
        syncState = .syncing
        do {
            let envelope = try await client.accountData(token: token)
            cloudDoc = normalizeAccountDoc(envelope.data) ?? [:]
            let mergedStars = mergeStars(local: stars, remote: cloudStars)
            let mergedPositions = mergePositions(local: positions, remote: cloudPositions)
            var doc = cloudDoc
            doc["stars.ammo"] = .array(mergedStars.map { .string($0) })
            doc["ledger.ammo"] = Self.accountValue(mergedPositions)
            try await client.putAccountData(doc, token: token)
            cloudDoc = doc
            lastSyncAt = .now
            syncState = .ok
            return MergeResult(stars: mergedStars, positions: mergedPositions)
        } catch {
            if isAuthExpired(error) { clearLocal() }
            syncState = .error(message: error.localizedDescription)
            return MergeResult(stars: nil, positions: nil)
        }
    }

    /// 本地数据变化后的防抖上推（2s；AppModel 在用户 toggle / 改台账后调用）。
    /// 只传变化的一项时，另一项取云端缓存补全（未登录时直接忽略）。
    func schedulePushDoc(stars: [String]?, positions: [LedgerEntry]?) {
        guard token != nil, user != nil else { return }
        pushTask?.cancel()
        let payload = LocalData(
            stars: (stars ?? cloudStars).sorted(),
            positions: positions ?? cloudPositions
        )
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.pushNow(payload)
        }
    }

    private func pushNow(_ payload: LocalData) async {
        guard let token, user != nil else { return }
        do {
            var doc = cloudDoc
            doc["stars.ammo"] = .array(payload.stars.map { .string($0) })
            doc["ledger.ammo"] = Self.accountValue(payload.positions)
            try await client.putAccountData(doc, token: token)
            cloudDoc = doc
            lastSyncAt = .now
            syncState = .ok
        } catch {
            if isAuthExpired(error) { clearLocal() }
            syncState = .error(message: error.localizedDescription)
        }
    }
}
