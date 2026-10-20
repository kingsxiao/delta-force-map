// APIClient.swift — 快照 / 健康检查的 HTTP 客户端（契约 shared/API.md §1）
// 零第三方依赖：URLSession + async/await。快照一律绕过本地缓存（服务端对 *.json
// 发 no-cache，这里再保险一次），避免拿到构建时旧快照。
import Foundation

public enum APIError: Error, LocalizedError, Sendable, Equatable {
    case invalidBaseURL(String)
    case notHTTP
    case badStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let s): "服务器地址无效：\(s)"
        case .notHTTP: "响应不是 HTTP"
        case .badStatus(let code): "服务器返回 HTTP \(code)"
        }
    }
}

public struct APIClient: Sendable {
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
    /// 网页端路由（hash 模式），供地图 / 打法 WebView 使用
    public func webURL(route: String) -> URL {
        URL(string: baseURL.absoluteString + "/#" + route) ?? baseURL
    }

    public func fetchMarket() async throws -> MarketSnapshot {
        try await fetchJSON("ammo/market.json")
    }

    public func fetchRadar() async throws -> MarketSnapshot {
        try await fetchJSON("market/radar.json")
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
}
