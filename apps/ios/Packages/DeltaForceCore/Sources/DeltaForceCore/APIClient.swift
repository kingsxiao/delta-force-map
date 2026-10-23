// APIClient.swift — 快照 / 健康检查的 HTTP 客户端（契约 shared/API.md §1）
// 零第三方依赖：URLSession + async/await。快照一律绕过本地缓存（服务端对 *.json
// 发 no-cache，这里再保险一次），避免拿到构建时旧快照。
import Foundation

public enum APIError: Error, LocalizedError, Sendable, Equatable {
    case invalidBaseURL(String)
    case notHTTP
    case badStatus(Int)
    /// 服务端业务错误（契约 §6.2：{error: 中文说明, code: 机器码}）
    case server(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "服务地址配置无效"
        case .notHTTP: "响应不是 HTTP"
        case .badStatus(let code): "服务器返回 HTTP \(code)"
        case .server(_, let message): message
        }
    }

    /// 账号侧 401 语义（令牌失效 / 过期）→ 需要清会话重登
    public var isAuthExpired: Bool {
        switch self {
        case .server(let code, _) where code == "BAD_TOKEN" || code == "TOKEN_EXPIRED": true
        default: false
        }
    }
}

public struct APIClient: Sendable {
    /// 固定后端（HTTPS 域名，nginx 443 反代本机 8080；iOS 26 ATS 禁明文，必须走 https）
    public static let productionBaseURL = URL(string: "https://xiaofating.cc")!

    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// 解析用户输入的服务器地址：无 scheme 补 http://、去掉末尾斜杠；形如 192.168.1.8:8080 / https://df.example.com
    public static func parseBaseURL(_ raw: String) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw APIError.invalidBaseURL(raw) }
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let host = url.host(), !host.isEmpty else {
            throw APIError.invalidBaseURL(raw)
        }
        return url
    }

    public var eventsURL: URL { baseURL.appending(path: "events") }
    public var healthURL: URL { baseURL.appending(path: "health") }
    public func fetchMarket() async throws -> MarketSnapshot {
        try await fetchJSON("ammo/market.json")
    }

    public func fetchRadar() async throws -> MarketSnapshot {
        try await fetchJSON("market/radar.json")
    }

    public func fetchCraft() async throws -> CraftSnapshot {
        try await fetchJSON("craft/craft.json")
    }

    /// 健康探测：短超时，取不到即视为实时服务不在线（与网页端 gate 一致）
    public func health(timeout: TimeInterval = 4) async throws -> HealthStatus {
        try await fetchJSON("health", timeout: timeout)
    }

    func fetchJSON<T: Decodable>(_ path: String, timeout: TimeInterval = 15) async throws -> T {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }
        return try JSONDecoder.deltaForce().decode(T.self, from: data)
    }

    // MARK: - 账号接口（契约 §6.2；body 走 JSON，错误统一解码 {error, code}）

    /// 带方法 / 请求体 / Bearer 令牌的通用请求；204 返回空 Data
    func requestJSON(
        _ path: String,
        method: String,
        body: (any Encodable)? = nil,
        token: String? = nil,
        timeout: TimeInterval = 15
    ) async throws -> Data {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = timeout
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            // 服务端业务错误优先（带可行动的中文说明与机器码）
            if let e = try? JSONDecoder.deltaForce().decode(ServerErrorMessage.self, from: data) {
                throw APIError.server(code: e.code, message: e.error)
            }
            throw APIError.badStatus(http.statusCode)
        }
        return data
    }

    /// 注册成功返回会话；409 用户名已存在（server code = USERNAME_TAKEN）
    public func register(username: String, password: String) async throws -> AuthSession {
        let data = try await requestJSON(
            "api/auth/register", method: "POST", body: AuthCredentials(username: username, password: password)
        )
        return try JSONDecoder.deltaForce().decode(AuthSession.self, from: data)
    }

    /// 登录成功返回会话；401 用户名或密码错误（server code = AUTH_FAILED）
    public func login(username: String, password: String) async throws -> AuthSession {
        let data = try await requestJSON(
            "api/auth/login", method: "POST", body: AuthCredentials(username: username, password: password)
        )
        return try JSONDecoder.deltaForce().decode(AuthSession.self, from: data)
    }

    /// 登出：服务器使该用户全部令牌失效（204 无响应体）
    public func logout(token: String) async throws {
        _ = try await requestJSON("api/auth/logout", method: "POST", token: token)
    }

    /// 当前用户信息；401 = 令牌失效
    public func me(token: String) async throws -> AuthUser {
        let data = try await requestJSON("api/auth/me", method: "GET", token: token)
        return try JSONDecoder.deltaForce().decode(AuthUser.self, from: data)
    }

    /// 云数据文档：{data, savedAt}
    public func accountData(token: String) async throws -> AccountDataEnvelope {
        let data = try await requestJSON("api/account/data", method: "GET", token: token)
        return try JSONDecoder.deltaForce().decode(AccountDataEnvelope.self, from: data)
    }

    /// 整文档覆盖上传；返回 savedAt（ISO-8601 字符串）。
    /// PUT body 顶层 = 文档本身（契约 §6.2：服务端不剥壳，禁止再包 {"data":…} 外层）。
    @discardableResult
    public func putAccountData(_ doc: [String: AccountValue], token: String) async throws -> String? {
        let data = try await requestJSON(
            "api/account/data", method: "PUT", body: AccountDocPayload(doc: doc), token: token
        )
        return try? JSONDecoder.deltaForce().decode(SavedAtMessage.self, from: data).savedAt
    }
}

/// 注册 / 登录请求体 {username, password}
private struct AuthCredentials: Encodable {
    let username: String
    let password: String
}

/// PUT /api/account/data 请求体：直接把 [String: AccountValue] 编码为顶层 K/V
/// （Dictionary 已是 Encodable；独立命名以固化「顶层即文档、不包壳」这条接缝契约）
private struct AccountDocPayload: Encodable {
    let doc: [String: AccountValue]

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        for (k, v) in doc { try c.encode(v, forKey: AnyCodingKey(k)) }
    }
}

/// 动态键编码用的 CodingKey
private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// 服务端错误统一形状（契约 §6.2）
struct ServerErrorMessage: Decodable {
    let error: String
    let code: String
}

/// PUT 成功响应 {savedAt}
struct SavedAtMessage: Decodable {
    let savedAt: String?
}
