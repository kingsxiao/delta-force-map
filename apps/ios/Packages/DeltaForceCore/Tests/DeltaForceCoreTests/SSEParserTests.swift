// SSEParserTests.swift — SSE 行级状态机（契约 §2 的 wire 格式）
import Foundation
import Testing
@testable import DeltaForceCore

@Suite("SSE 解析")
struct SSEParserTests {
    @Test("命名事件：event + data + 空行派发；注释心跳单独上报")
    func namedEvent() {
        var p = SSEParser()
        #expect(p.feed(line: ": ping") == .heartbeat)
        #expect(p.feed(line: "event: hello") == .none)
        #expect(p.feed(line: #"data: {"version":"202610201121","source":"moligod","generatedAt":null}"#) == .none)
        let out = p.feed(line: "")
        #expect(out == .event(SSEEvent(name: "hello", data: #"{"version":"202610201121","source":"moligod","generatedAt":null}"#)))
        // 派发后状态复位：下一条无 event 名的默认 message
        #expect(p.feed(line: "data: x") == .none)
        #expect(p.feed(line: "") == .event(SSEEvent(name: "message", data: "x")))
    }

    @Test("多行 data 以 \\n 拼接；CRLF 行尾；id 字段跟随；无 data 的空行不派发")
    func multilineAndCRLF() {
        var p = SSEParser()
        #expect(p.feed(line: "id: 7\r") == .none)
        #expect(p.feed(line: "event: market\r") == .none)
        #expect(p.feed(line: "data: a\r") == .none)
        #expect(p.feed(line: "data:b\r") == .none)
        #expect(p.feed(line: "\r") == .event(SSEEvent(name: "market", data: "a\nb", id: "7")))
        #expect(p.feed(line: "event: radar") == .none)
        #expect(p.feed(line: "") == .none) // 只有 event 名没有 data → 丢弃
        #expect(p.feed(line: "data: z") == .none)
        #expect(p.feed(line: "") == .event(SSEEvent(name: "message", data: "z", id: "7")))
    }

    @Test("服务端 wire 格式整段喂入（与 live.mjs broadcast 一致）")
    func wireFormat() {
        let wire = "event: hello\ndata: {\"version\":null,\"source\":null,\"generatedAt\":null}\n\n: ping\n\nevent: market\ndata: {\"version\":\"202610201121\",\"source\":\"moligod\",\"generatedAt\":\"2026-10-20T03:23:17.111Z\"}\n\n"
        var p = SSEParser()
        var events: [SSEEvent] = []
        var heartbeats = 0
        for line in wire.split(separator: "\n", omittingEmptySubsequences: false) {
            switch p.feed(line: String(line)) {
            case .event(let e): events.append(e)
            case .heartbeat: heartbeats += 1
            case .none: break
            }
        }
        #expect(heartbeats == 1)
        #expect(events.map(\.name) == ["hello", "market"])
        if case .market(let ping) = LiveEvent.parse(events[1]) {
            #expect(ping.version == "202610201121")
        } else {
            Issue.record("应解析为 market")
        }
        if case .hello(let ping) = LiveEvent.parse(events[0]) {
            #expect(ping.version == nil) // 冷启动 hello 允许 null
        } else {
            Issue.record("应解析为 hello")
        }
    }
}

@Suite("APIClient 地址解析")
struct APIClientTests {
    @Test("补 scheme、去尾斜杠、空值报错")
    func parseBaseURL() throws {
        #expect(try APIClient.parseBaseURL("192.168.1.8:8080").absoluteString == "http://192.168.1.8:8080")
        #expect(try APIClient.parseBaseURL("https://df.example.com/").absoluteString == "https://df.example.com")
        #expect(try APIClient.parseBaseURL("  http://a.b:1// ").absoluteString == "http://a.b:1")
        #expect(throws: APIError.self) { try APIClient.parseBaseURL("") }
        #expect(throws: APIError.self) { try APIClient.parseBaseURL("http://") }
    }

    @Test("端点拼接")
    func endpoints() throws {
        let c = APIClient(baseURL: try APIClient.parseBaseURL("http://10.0.0.2:8080"))
        #expect(c.eventsURL.absoluteString == "http://10.0.0.2:8080/events")
        #expect(c.healthURL.absoluteString == "http://10.0.0.2:8080/health")
    }
}
