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
    /// cloudDoc 是否已成功从云端加载。未加载前拒绝整文档上推——服务端 PUT 是
    /// 全量覆盖，带着空缓存推会误删云端其他端写入的键（如网页端 mycost.ammo）
    private var cloudDocLoaded = false
    /// 会话是否已经 /me 验证（冷启动离线时先用 UserDefaults 缓存作乐观展示，
    /// 未验证期间 scenePhase 回前台可重试；adopt 即已验证）
    private var restoreVerified = false
    private var pushTask: Task<Void, Never>?
    private var started = false

    /// 上推途中退化为拉取合并（cloudDoc 尚未加载）时，把合并结果抛给 AppModel
    /// 落回本地 Store——否则本地仍是未合并的旧集合，后续上推会把它覆盖回云端
    var onMerged: ((MergeResult) -> Void)?

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

    /// 启动时用存量 token 调 /me 恢复会话（静默：401 只清失效令牌）。
    /// 网络类失败（离线冷启动）不放弃会话：回填 UserDefaults 缓存用户作乐观
    /// 展示，云同步照常排队；scenePhase 回前台由 retryRestoreIfNeeded 补拉验证。
    func restore() async {
        guard !started else { return }
        started = true
        guard let token else { return }
        do {
            let me = try await client.me(token: token)
            user = me
            restoreVerified = true
            cacheUser(me)
        } catch {
            if isAuthExpired(error) {
                clearLocal()
            } else if let cached = cachedUser() {
                user = cached
            }
        }
    }

    /// 会话补拉：restore 因网络失败（或无缓存）未验证时，前台激活等时机重试 /me。
    /// 返回 true = 本次调用验证成功（调用方可顺带补一次冷启动漏掉的云同步）。
    func retryRestoreIfNeeded() async -> Bool {
        guard started, !restoreVerified, let token else { return false }
        do {
            let me = try await client.me(token: token)
            user = me
            restoreVerified = true
            cacheUser(me)
            return true
        } catch {
            if isAuthExpired(error) { clearLocal() }
            return false
        }
    }

    /// UserDefaults 里的用户缓存（adopt 时写入；离线冷启动兜底展示用）
    private func cachedUser() -> AuthUser? {
        guard let data = UserDefaults.standard.data(forKey: Self.userKey) else { return nil }
        return try? JSONDecoder().decode(AuthUser.self, from: data)
    }

    private func cacheUser(_ u: AuthUser) {
        if let data = try? JSONEncoder().encode(u) {
            UserDefaults.standard.set(data, forKey: Self.userKey)
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
        restoreVerified = true
        cacheUser(session.user)
        resetCloudDoc() // 换会话：旧账号的云端缓存绝不能带进新会话的上推
    }

    /// 登出：服务器失效全部令牌（best-effort，不可达也已清本地）→ 清会话；本地自选保留
    func logout() async {
        let old = token
        clearLocal()
        pushTask?.cancel()
        syncState = .idle
        if let old {
            try? await client.logout(token: old)
        }
    }

    private func clearLocal() {
        token = nil
        user = nil
        restoreVerified = false
        UserDefaults.standard.removeObject(forKey: Self.userKey)
        resetCloudDoc()
    }

    /// 云端缓存复位：新会话 / 会话失效后，未加载状态下的上推会被门禁拦下
    private func resetCloudDoc() {
        cloudDoc = [:]
        cloudDocLoaded = false
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
        .array(positions.map { p in
            var o: [String: AccountValue] = [
                "name": .string(p.name),
                "qty": .number(Double(p.qty)),
                "cost": .number(p.cost),
            ]
            if let at = p.at { o["at"] = .number(at) } // 可选记账时刻：缺省不带键（契约 §6.3）
            return .object(o)
        })
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
            // 规范化不过（键非法 / 超尺寸）按同步失败中止——若回退空文档继续，
            // 后续上推会以空缓存整文档覆盖，误删云端其他键
            guard let doc = normalizeAccountDoc(envelope.data) else {
                syncState = .error(message: "云端数据校验失败，已中止同步")
                return MergeResult(stars: nil, positions: nil)
            }
            cloudDoc = doc
            cloudDocLoaded = true
            let mergedStars = mergeStars(local: stars, remote: cloudStars)
            let mergedPositions = mergePositions(local: positions, remote: cloudPositions)
            var newDoc = cloudDoc
            newDoc["stars.ammo"] = .array(mergedStars.map { .string($0) })
            newDoc["ledger.ammo"] = Self.accountValue(mergedPositions)
            try await client.putAccountData(newDoc, token: token)
            cloudDoc = newDoc
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
        // 门禁：云端缓存未加载（登录后首拉失败 / 尚未拉过）时先转一次完整
        // 拉取合并——拉不到就中止，绝不带着空缓存整文档 PUT（会误删云端
        // 其他端写入的键，且本地集合会覆盖其他端新增的星标）
        if !cloudDocLoaded {
            let merged = await pullAndMerge(stars: payload.stars, positions: payload.positions)
            if merged.stars != nil || merged.positions != nil {
                onMerged?(merged) // AppModel 落回本地，本地与云端回到同一并集
            }
            return
        }
        do {
            // 上推前先 GET 云端现值，两键按 §6.3 口径合并（星标并集 / 台账按名
            // 并集·同名本机优先）再回推——多端并发时后推者不用内存旧快照整文档
            // 覆盖对端改动（网页端写入的 mycost.ammo 等其他键随最新云端原样
            // 保留），与 web useAccount.schedulePush 同口径
            let envelope = try await client.accountData(token: token)
            guard let remote = normalizeAccountDoc(envelope.data) else {
                // 规范化不过按同步失败中止，绝不带着空文档整文档覆盖（同 pullAndMerge）
                syncState = .error(message: "云端数据校验失败，已中止同步")
                return
            }
            var doc = remote
            let mergedStars = mergeStars(local: payload.stars, remote: remote["stars.ammo"]?.stringArray ?? [])
            let mergedPositions = mergePositions(local: payload.positions, remote: remote["ledger.ammo"]?.ledgerArray ?? [])
            doc["stars.ammo"] = .array(mergedStars.map { .string($0) })
            doc["ledger.ammo"] = Self.accountValue(mergedPositions)
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
