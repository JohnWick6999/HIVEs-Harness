import Foundation
@testable import HiveHarnessCore
import Testing

final class HTTPToolMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func httpToolSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HTTPToolMockURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite("HTTP 联网工具", .serialized)
struct HTTPGetToolTests {
    @Test("GET 返回文本")
    func fetchText() async throws {
        let session = httpToolSession()
        HTTPToolMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "text/plain"]
            )!
            return (response, Data("营口: 晴 +18°C".utf8))
        }
        defer { HTTPToolMockURLProtocol.handler = nil }
        let tool = HTTPGetTool(session: session)
        let result = try await tool.run(arguments: [
            "url": AnyCodable("https://wttr.in/Yingkou?format=3"),
        ])
        #expect(result.text.contains("HTTP 200"))
        #expect(result.text.contains("营口"))
    }

    @Test("非 2xx 返回失败")
    func httpError() async throws {
        let session = httpToolSession()
        HTTPToolMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 503,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("unavailable".utf8))
        }
        defer { HTTPToolMockURLProtocol.handler = nil }
        let tool = HTTPGetTool(session: session)
        await #expect(throws: ToolError.self) {
            _ = try await tool.run(arguments: ["url": AnyCodable("https://example.com")])
        }
    }

    @Test("拒绝本机/私网 URL")
    func rejectPrivate() async {
        let tool = HTTPGetTool(session: httpToolSession())
        await #expect(throws: ToolError.self) {
            _ = try await tool.run(arguments: ["url": AnyCodable("http://127.0.0.1:8080")])
        }
        await #expect(throws: ToolError.self) {
            _ = try await tool.run(arguments: ["url": AnyCodable("http://192.168.1.2/x")])
        }
    }

    @Test("只在完全控制模式可用且需审批")
    func workMode() {
        #expect(WorkMode.full.allows(tool: "http_get"))
        #expect(WorkMode.full.requiresExecutionApproval)
        #expect(WorkMode.requiresExecutionApproval(for: "http_get"))
        #expect(!WorkMode.sandbox.allows(tool: "http_get"))
        #expect(!WorkMode.chat.allows(tool: "http_get"))
    }
}
