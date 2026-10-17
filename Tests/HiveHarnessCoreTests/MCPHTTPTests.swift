import Foundation
@testable import HiveHarnessCore
import Testing

/// 独立的 HTTP mock,避免与 LLM 测试共享 URLProtocol 处理器。
final class MCPMockURLProtocol: URLProtocol, @unchecked Sendable {
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

private func httpConfig() -> MCPServerConfig {
    MCPServerConfig(
        id: "http-fake",
        name: "HTTP Fake",
        type: "http",
        url: "https://mcp.example/rpc"
    )
}

private func mcpMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MCPMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

private func jsonResponse(
    id: Any?,
    result: [String: Any],
    headers: [String: String] = [:]
) -> (HTTPURLResponse, Data) {
    var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
    if let id { payload["id"] = id }
    let data = try! JSONSerialization.data(withJSONObject: payload)
    var allHeaders = ["Content-Type": "application/json"]
    allHeaders.merge(headers) { _, new in new }
    let response = HTTPURLResponse(
        url: URL(string: "https://mcp.example/rpc")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: allHeaders
    )!
    return (response, data)
}

private func sseResponse(id: Any?, result: [String: Any]) -> (HTTPURLResponse, Data) {
    var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
    if let id { payload["id"] = id }
    let json = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
    let body = "event: message\ndata: \(json)\n\n"
    let response = HTTPURLResponse(
        url: URL(string: "https://mcp.example/rpc")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/event-stream"]
    )!
    return (response, Data(body.utf8))
}

@Suite("MCP HTTP 传输与配置", .serialized)
struct MCPHTTPTests {
    @Test("initialize / tools/list / tools/call 走 Streamable HTTP")
    func httpLifecycle() async throws {
        MCPMockURLProtocol.handler = { request in
            let data = requestBody(request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let id = json?["id"]
            let method = json?["method"] as? String ?? ""
            switch method {
            case "initialize":
                return jsonResponse(
                    id: id,
                    result: [
                        "protocolVersion": "2024-11-05",
                        "serverInfo": ["name": "http-fake"],
                    ],
                    headers: ["Mcp-Session-Id": "session-1"]
                )
            case "notifications/initialized":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 202,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!
                return (response, Data())
            case "tools/list":
                return jsonResponse(id: id, result: [
                    "tools": [[
                        "name": "echo",
                        "description": "echo text",
                        "inputSchema": ["type": "object"],
                    ]]
                ])
            case "tools/call":
                return jsonResponse(id: id, result: [
                    "content": [["type": "text", "text": "hello from http"]]
                ])
            default:
                return jsonResponse(id: id, result: [:])
            }
        }

        let client = MCPClient(config: httpConfig(), timeout: .seconds(5), urlSession: mcpMockSession())
        let initialized = try await client.initialize()
        let info = initialized?.value as? [String: Any]
        #expect((info?["serverInfo"] as? [String: Any])?["name"] as? String == "http-fake")

        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["echo"])

        let text = try await client.callTool(
            name: "echo",
            arguments: ["text": AnyCodable("hi")]
        )
        #expect(text == "hello from http")
        await client.disconnect()
    }

    @Test("SSE 响应解析")
    func sseParsing() async throws {
        MCPMockURLProtocol.handler = { request in
            let data = requestBody(request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let id = json?["id"]
            let method = json?["method"] as? String ?? ""
            if method == "initialize" {
                return jsonResponse(id: id, result: ["protocolVersion": "2024-11-05"])
            }
            if method == "notifications/initialized" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 202,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!
                return (response, Data())
            }
            return sseResponse(id: id, result: [
                "tools": [["name": "sse-tool", "description": "from sse"]]
            ])
        }

        let client = MCPClient(config: httpConfig(), timeout: .seconds(5), urlSession: mcpMockSession())
        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["sse-tool"])
        await client.disconnect()
    }

    @Test("配置加载:servers.json + 单文件(文件名作 id)")
    func configLoader() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let container = """
        {"servers":[{"id":"alpha","name":"Alpha","type":"http","url":"https://alpha.example/rpc","enabled":true}]}
        """
        try container.write(to: dir.appendingPathComponent("servers.json"), atomically: true, encoding: .utf8)
        let single = """
        {"name":"Beta","type":"http","url":"https://beta.example/rpc"}
        """
        try single.write(to: dir.appendingPathComponent("beta.json"), atomically: true, encoding: .utf8)

        let configs = MCPConfigLoader.load(directory: dir)
        #expect(configs.count == 2)
        #expect(configs.contains { $0.id == "alpha" })
        #expect(configs.contains { $0.id == "beta" && $0.name == "Beta" })

        try MCPConfigLoader.save(configs, directory: dir)
        let reloaded = MCPConfigLoader.load(directory: dir)
        #expect(Set(reloaded.map(\.id)) == ["alpha", "beta"])
    }

    @Test("兼容 Claude mcpServers 对象格式")
    func claudeConfigFormat() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hive-claude-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"mcpServers":{"demo":{"command":"npx","args":["-y","demo-mcp"],"disabled":true},
        "remote":{"url":"https://example.com/mcp","headers":{"Authorization":"Bearer x"}}}}
        """
        try json.write(to: dir.appendingPathComponent("servers.json"), atomically: true, encoding: .utf8)
        let configs = MCPConfigLoader.load(directory: dir)
        #expect(configs.count == 2)
        #expect(configs.first { $0.id == "demo" }?.enabled == false)
        #expect(configs.first { $0.id == "remote" }?.type == "http")
    }

    @Test("工具适配器名称带服务器前缀,调用仍用远程名")
    func adapterPrefix() async throws {
        MCPMockURLProtocol.handler = { request in
            let data = requestBody(request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let id = json?["id"]
            return jsonResponse(id: id, result: [
                "content": [["type": "text", "text": "pong"]]
            ])
        }

        let client = MCPClient(config: httpConfig(), timeout: .seconds(5), urlSession: mcpMockSession())
        let remote = MCPTool(name: "ping", description: "ping", inputSchema: AnyCodable(["type": "object"]))
        let adapter = MCPToolAdapter(client: client, tool: remote, prefix: "mcp__srv")

        #expect(adapter.name == "mcp__srv__ping")
        #expect(adapter.spec.name == "mcp__srv__ping")
        let result = try await adapter.run(arguments: [:])
        #expect(result.text == "pong")
        await client.disconnect()
    }
}
