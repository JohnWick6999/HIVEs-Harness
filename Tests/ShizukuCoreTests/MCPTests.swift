import Foundation
@testable import ShizukuCore
import Testing

/// 测试用假 MCP 服务器配置(本地 python3 进程)
func fakeServerConfig() -> MCPServerConfig {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fake_mcp_server.py")
    return MCPServerConfig(
        id: "fake",
        name: "Fake Server",
        description: "测试假服务器",
        type: "stdio",
        command: "/usr/bin/python3",
        args: [script.path],
        enabled: true
    )
}

@Suite("JSON-RPC 2.0")
struct JSONRPCTests {
    @Test("请求编码往返")
    func requestRoundtrip() throws {
        let message = JSONRPCMessage.request(
            id: 1,
            method: "tools/list",
            params: AnyCodable(["cursor": "abc"])
        )
        let data = try message.encode()
        let decoded = try JSONRPCMessage.decode(data)
        #expect(decoded.id == 1)
        #expect(decoded.method == "tools/list")
        #expect((decoded.params?.value as? [String: Any])?["cursor"] as? String == "abc")
        #expect(decoded.jsonrpc == "2.0")
    }

    @Test("响应与错误解码")
    func responseDecode() throws {
        let response = try JSONRPCMessage.decode(
            Data(#"{"jsonrpc":"2.0","id":2,"result":{"ok":true}}"#.utf8)
        )
        #expect(response.id == 2)
        #expect((response.result?.value as? [String: Any])?["ok"] as? Bool == true)

        let error = try JSONRPCMessage.decode(
            Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"Method not found"}}"#.utf8)
        )
        #expect(error.error?.code == -32601)
        #expect(error.error?.message == "Method not found")
    }
}

@Suite("MCPClient(假服务器)", .serialized)
struct MCPClientTests {
    @Test("initialize 握手返回服务器信息")
    func initialize() async throws {
        let client = MCPClient(config: fakeServerConfig(), timeout: .seconds(10))
        let result = try await client.initialize()
        let info = result?.value as? [String: Any]
        #expect((info?["serverInfo"] as? [String: Any])?["name"] as? String == "fake-server")
        await client.disconnect()
    }

    @Test("tools/list 返回工具列表")
    func listTools() async throws {
        let client = MCPClient(config: fakeServerConfig(), timeout: .seconds(10))
        let tools = try await client.listTools()
        #expect(tools.count == 2)
        #expect(tools.contains { $0.name == "echo" })
        #expect(tools.contains { $0.name == "add" })
        await client.disconnect()
    }

    @Test("tools/call 调用远程工具")
    func callTool() async throws {
        let client = MCPClient(config: fakeServerConfig(), timeout: .seconds(10))
        let echo = try await client.callTool(
            name: "echo",
            arguments: ["text": AnyCodable("hello mcp")]
        )
        #expect(echo == "echo:hello mcp")

        let sum = try await client.callTool(
            name: "add",
            arguments: ["a": AnyCodable(20), "b": AnyCodable(22)]
        )
        #expect(sum == "42")
        await client.disconnect()
    }

    @Test("错误工具返回 isError 内容")
    func callUnknownTool() async throws {
        let client = MCPClient(config: fakeServerConfig(), timeout: .seconds(10))
        let result = try await client.callTool(name: "nope", arguments: [:])
        #expect(result.contains("执行失败"))
        #expect(result.contains("unknown tool"))
        await client.disconnect()
    }
}

@Suite("MCPRegistry 与工具适配", .serialized)
struct MCPRegistryTests {
    @Test("适配器注册进 ToolRegistry 并可执行")
    func adaptersIntegrate() async throws {
        let registry = MCPRegistry(configs: [fakeServerConfig()], timeout: .seconds(10))
        let adapters = try await registry.makeAdapters()
        #expect(adapters.count == 2)

        let toolRegistry = ToolRegistry()
        for adapter in adapters {
            toolRegistry.register(adapter)
        }
        #expect(toolRegistry.names() == ["add", "echo"])

        let result = try await toolRegistry.execute(
            name: "echo",
            arguments: ["text": AnyCodable("via registry")]
        )
        #expect(result == "echo:via registry")
    }

    @Test("禁用服务器不产生工具")
    func disabledServer() async throws {
        var config = fakeServerConfig()
        config.enabled = false
        let registry = MCPRegistry(configs: [config], timeout: .seconds(10))
        let adapters = try await registry.makeAdapters()
        #expect(adapters.isEmpty)
    }
}
