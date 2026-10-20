// SSEClient.swift — /events 实时通道（text/event-stream）客户端
// 契约 shared/API.md §2：命名事件 hello / market / radar 为轻量 ping，注释行 `: ping`
// 每 25s 一次是心跳。实现要点：
//   · URLSession.bytes 逐字节切行（不用 AsyncBytes.lines：空行是 SSE 的事件分隔符，
//     必须可靠保留），SSEParser 为纯状态机可单测
//   · 空闲超时 90s（> 25s 心跳 × 3）：代理掐流后自动重连
//   · 断线指数退避 1s → 30s（带抖动），连上即复位；Task 取消即结束
import Foundation

public struct SSEEvent: Sendable, Hashable {
    public let name: String
    public let data: String
    public let id: String?

    public init(name: String, data: String, id: String? = nil) {
        self.name = name
        self.data = data
        self.id = id
    }
}

/// SSE 行级解析状态机（WHATWG 规范子集：event / data / id / retry / 注释）
public struct SSEParser: Sendable {
    public enum Output: Sendable, Hashable {
        case none
        case heartbeat
        case event(SSEEvent)
    }

    private var eventName = ""
    private var dataLines: [String] = []
    private var lastId: String?

    public init() {}

    public mutating func feed(line rawLine: String) -> Output {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            // 空行 = 派发；data 为空时按规范丢弃（只重置 event 名）
            guard !dataLines.isEmpty else {
                eventName = ""
                return .none
            }
            let event = SSEEvent(
                name: eventName.isEmpty ? "message" : eventName,
                data: dataLines.joined(separator: "\n"),
                id: lastId
            )
            eventName = ""
            dataLines = []
            return .event(event)
        }
        if line.hasPrefix(":") { return .heartbeat }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        case "id": lastId = String(value)
        default: break // retry 与未知字段忽略
        }
        return .none
    }
}

public enum SSEStreamEvent: Sendable, Hashable {
    case open
    case heartbeat
    case event(SSEEvent)
    case closed(String)
}

public enum SSEClient {
    /// 打开长连接并持续产出事件；消费方取消迭代即断开。reconnect=false 时流结束于首个 closed
    public static func stream(
        url: URL,
        session: URLSession = .shared,
        reconnect: Bool = true,
        initialDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 30,
        idleTimeout: TimeInterval = 90
    ) -> AsyncStream<SSEStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                var delay = initialDelay
                while !Task.isCancelled {
                    do {
                        var req = URLRequest(url: url)
                        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                        req.cachePolicy = .reloadIgnoringLocalCacheData
                        req.timeoutInterval = idleTimeout
                        let (bytes, response) = try await session.bytes(for: req)
                        guard let http = response as? HTTPURLResponse else { throw APIError.notHTTP }
                        guard http.statusCode == 200 else { throw APIError.badStatus(http.statusCode) }
                        continuation.yield(.open)
                        delay = initialDelay

                        var parser = SSEParser()
                        var buffer: [UInt8] = []
                        buffer.reserveCapacity(512)
                        for try await byte in bytes {
                            if byte == 0x0A {
                                let line = String(decoding: buffer, as: UTF8.self)
                                buffer.removeAll(keepingCapacity: true)
                                switch parser.feed(line: line) {
                                case .event(let e): continuation.yield(.event(e))
                                case .heartbeat: continuation.yield(.heartbeat)
                                case .none: break
                                }
                            } else {
                                buffer.append(byte)
                            }
                        }
                        continuation.yield(.closed("服务端关闭了连接"))
                    } catch is CancellationError {
                        break
                    } catch {
                        if Task.isCancelled { break }
                        continuation.yield(.closed(error.localizedDescription))
                    }
                    guard reconnect, !Task.isCancelled else { break }
                    let jitter = Double.random(in: 0...0.3) * delay
                    try? await Task.sleep(for: .seconds(delay + jitter))
                    delay = min(delay * 2, maxDelay)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
