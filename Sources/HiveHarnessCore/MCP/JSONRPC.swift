import Foundation

// MARK: - JSON-RPC 2.0 消息

public enum JSONRPCErrorCode: Int, Sendable {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
}

/// JSON-RPC 2.0 请求/响应/通知统一消息
public struct JSONRPCMessage: Codable, Sendable, Equatable {
    public var jsonrpc: String
    public var id: Int?
    public var method: String?
    public var params: AnyCodable?
    public var result: AnyCodable?
    public var error: RPCError?

    public struct RPCError: Codable, Sendable, Equatable {
        public var code: Int
        public var message: String
        public var data: AnyCodable?

        public init(code: Int, message: String, data: AnyCodable? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }
    }

    public init(
        jsonrpc: String = "2.0",
        id: Int? = nil,
        method: String? = nil,
        params: AnyCodable? = nil,
        result: AnyCodable? = nil,
        error: RPCError? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    public static func request(id: Int, method: String, params: AnyCodable?) -> JSONRPCMessage {
        JSONRPCMessage(jsonrpc: "2.0", id: id, method: method, params: params)
    }

    public static func response(id: Int, result: AnyCodable) -> JSONRPCMessage {
        JSONRPCMessage(jsonrpc: "2.0", id: id, result: result)
    }

    public static func error(id: Int?, code: Int, message: String) -> JSONRPCMessage {
        JSONRPCMessage(jsonrpc: "2.0", id: id, error: RPCError(code: code, message: message))
    }

    /// 从 JSON 行解码(容忍字段缺失)
    public static func decode(_ data: Data) throws -> JSONRPCMessage {
        try JSONDecoder().decode(JSONRPCMessage.self, from: data)
    }

    public func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

/// JSON-RPC 编解码错误
public enum JSONRPCError: Error, Sendable, Equatable {
    case decode(String)
    case responseMismatch
}

// MARK: - MCP 基础类型

/// MCP 工具声明(tools/list 结果项)
public struct MCPTool: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    public var inputSchema: AnyCodable?

    public init(name: String, description: String? = nil, inputSchema: AnyCodable? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// MCP 服务器配置(兼容原版 servers.json 格式)
public struct MCPServerConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    /// stdio / http / internal
    public var type: String
    /// stdio 类型:可执行文件路径
    public var command: String
    /// stdio 类型:启动参数
    public var args: [String]
    /// http/sse 类型:端点 URL
    public var url: String
    public var headers: [String: String]
    public var enabled: Bool

    public init(
        id: String,
        name: String,
        description: String = "",
        type: String = "stdio",
        command: String = "",
        args: [String] = [],
        url: String = "",
        headers: [String: String] = [:],
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
        self.command = command
        self.args = args
        self.url = url
        self.headers = headers
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, type, command, args, url, headers, enabled
    }

    /// 兼容精简配置:只写 id/url/type 也能加载。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "stdio"
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
