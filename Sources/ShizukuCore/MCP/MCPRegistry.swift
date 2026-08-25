import Foundation

/// MCP 工具适配器:把远程 MCP 工具包装成本地 Tool(对齐"MCP 工具动态注册进 ToolRegistry")。
public struct MCPToolAdapter: Tool {
    public let name: String
    public let spec: ToolSpec
    private let client: MCPClient

    public init(client: MCPClient, tool: MCPTool) {
        self.client = client
        self.name = tool.name
        let schema: [String: AnyCodable]
        if let dict = tool.inputSchema?.value as? [String: Any] {
            schema = dict.mapValues(AnyCodable.init)
        } else {
            schema = [:]
        }
        self.spec = ToolSpec(
            name: tool.name,
            description: tool.description ?? "",
            parameters: schema
        )
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        try await ToolResult(text: client.callTool(name: name, arguments: arguments))
    }
}

/// MCP 服务器注册表(对齐原版 mcp_manager):管理多个服务器配置,
/// 聚合工具列表并提供统一的工具调用入口。
public actor MCPRegistry {
    public private(set) var configs: [MCPServerConfig]
    private var clients: [String: MCPClient] = [:]
    private let timeout: Duration

    public init(configs: [MCPServerConfig] = [], timeout: Duration = .seconds(30)) {
        self.configs = configs
        self.timeout = timeout
    }

    public func reload(configs: [MCPServerConfig]) async {
        for client in clients.values {
            await client.disconnect()
        }
        clients.removeAll()
        self.configs = configs
    }

    private func client(for id: String) -> MCPClient {
        if let existing = clients[id] { return existing }
        guard let config = configs.first(where: { $0.id == id && $0.enabled }) else {
            return MCPClient(config: MCPServerConfig(id: id, name: id), timeout: timeout)
        }
        let client = MCPClient(config: config, timeout: timeout)
        clients[id] = client
        return client
    }

    /// 连接所有启用服务器并返回各自的工具
    public func connectAll() async throws -> [String: [MCPTool]] {
        var result: [String: [MCPTool]] = [:]
        for config in configs where config.enabled {
            let client = client(for: config.id)
            let tools = try await client.listTools()
            result[config.id] = tools
        }
        return result
    }

    /// 全部可用工具(含服务器归属)
    public func allTools() async throws -> [(server: String, tool: MCPTool)] {
        var result: [(server: String, tool: MCPTool)] = []
        for config in configs where config.enabled {
            let client = client(for: config.id)
            let tools = try await client.listTools()
            result.append(contentsOf: tools.map { (config.id, $0) })
        }
        return result
    }

    /// 生成可注册进 ToolRegistry 的适配器
    public func makeAdapters() async throws -> [any Tool] {
        try await allTools().map { MCPToolAdapter(client: client(for: $0.server), tool: $0.tool) }
    }

    /// 调用指定服务器的工具
    public func callTool(server: String, name: String, arguments: [String: AnyCodable]) async throws -> String {
        try await client(for: server).callTool(name: name, arguments: arguments)
    }

    public func status() async -> [String: String] {
        var result: [String: String] = [:]
        for config in configs {
            result[config.id] = config.enabled ? "configured" : "disabled"
        }
        return result
    }
}
