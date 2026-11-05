// BarkPush.swift — Bark 推送注册（契约 shared/API.md §6.4）
// JS 单一源：server/push/bark.mjs（parseBarkUrl / KEY_RE / 默认服务器）。
// 本文件是其 Swift 同构镜像 + 注册请求/状态的消息形状——改任一侧必须同步另一处
// （SIGNAL_META 镜像同款同步义务）。
import Foundation

/// Bark 公共服务器（自建 Bark 填自己的 https 源；与 JS DEFAULT_BARK_SERVER 一致）
public enum BarkPush {
    public static let defaultServer = "https://api.day.app"
    /// 设备 key：Bark app「复制URL」路径里那段设备标识（字母数字 10–80 位）
    static let keyPattern = "^[A-Za-z0-9]{10,80}$"

    public static func isValidKey(_ k: String) -> Bool {
        k.range(of: keyPattern, options: .regularExpression) != nil
    }

    /// 设备 key 掩码回显（前 4 + … + 后 4）；过短 / 非 key 原样返回不误伤
    public static func keyMask(_ key: String?) -> String {
        guard let key, key.count >= 10 else { return key ?? "—" }
        return "\(key.prefix(4))…\(key.suffix(4))"
    }

    /// 与 server 端 parseBarkUrl 同构：接受裸 key、整段样例 URL
    /// （https://api.day.app/<key>/推送内容）、bark:// scheme（bark://域名/<key>/…、
    /// bark:///<key>）；解析不出合法 key 返回 nil
    public static func parseURL(_ raw: String) -> (server: String, key: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if isValidKey(s) { return (defaultServer, s) }
        guard let u = URLComponents(string: s), let scheme = u.scheme?.lowercased() else { return nil }
        let server: String
        switch scheme {
        case "https":
            guard let host = u.host, !host.isEmpty else { return nil }
            let portPart = u.port.map { ":\($0)" } ?? ""
            server = "https://\(host)\(portPart)"
        case "bark":
            guard let host = u.host, !host.isEmpty else {
                server = defaultServer
                break
            }
            server = "https://\(host)"
        default:
            return nil
        }
        let key = u.path.split(separator: "/").first.map(String.init) ?? ""
        guard isValidKey(key) else { return nil }
        return (server, key)
    }
}

/// PUT /api/push/bark 请求体 {server?, key, buys, sells}
public struct BarkPutRequest: Encodable, Sendable {
    public var server: String?
    public var key: String
    public var buys: Bool
    public var sells: Bool

    public init(server: String? = nil, key: String, buys: Bool, sells: Bool) {
        self.server = server
        self.key = key
        self.buys = buys
        self.sells = sells
    }
}

/// GET /api/push/bark 响应：未注册 registered=false；已注册带注册内容
public struct BarkStatusMessage: Decodable, Sendable {
    public let registered: Bool
    public let server: String?
    public let key: String?
    public let buys: Bool?
    public let sells: Bool?
    public let savedAt: String?
}

/// PUT / test 成功响应 {ok, savedAt?}
public struct BarkOkMessage: Decodable, Sendable {
    public let ok: Bool?
    public let savedAt: String?
}
