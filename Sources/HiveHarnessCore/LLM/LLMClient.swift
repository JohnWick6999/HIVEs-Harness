import Foundation

// MARK: - 消息与工具类型

/// 对话角色,对齐 OpenAI 协议。
public enum ChatRole: String, Codable, Sendable, Equatable {
    case system, user, assistant, tool
}

/// 消息内容:纯文本或多模态片段列表(图片 URL 等,对齐原版 `_compose_user_content`)。
public enum ChatContent: Codable, Sendable, Equatable {
    case text(String)
    case parts([ContentPart])

    public struct ContentPart: Codable, Sendable, Equatable {
        public enum PartType: String, Codable, Sendable {
            case text
            case imageURL = "image_url"
        }
        public var type: PartType
        public var text: String?
        public var imageURL: String?

        public init(type: PartType, text: String? = nil, imageURL: String? = nil) {
            self.type = type
            self.text = text
            self.imageURL = imageURL
        }

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
    }

    public var plainText: String {
        switch self {
        case .text(let t): return t
        case .parts(let parts):
            return parts.compactMap { $0.type == .text ? $0.text : "[图片]" }.joined(separator: "\n")
        }
    }
}

/// 工具产出文件附件(UI 渲染为可点击卡片)
public struct FileAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let path: String
    public let name: String

    public init(id: UUID = UUID(), path: String, name: String? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
    }
}

/// 对话消息。
public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var role: ChatRole
    public var content: ChatContent
    /// 工具调用(tool_calls,assistant 消息携带)
    public var toolCalls: [ToolCall]?
    /// tool 消息对应的调用 id
    public var toolCallID: String?
    /// 工具名(tool 消息)
    public var toolName: String?
    /// 工具产出的文件(展示为可点击附件)
    public var fileAttachments: [FileAttachment]

    public init(
        role: ChatRole,
        content: ChatContent,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil,
        toolName: String? = nil,
        fileAttachments: [FileAttachment] = [],
        id: UUID = UUID()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.fileAttachments = fileAttachments
    }

    public static func text(_ role: ChatRole, _ text: String) -> ChatMessage {
        ChatMessage(role: role, content: .text(text))
    }
}

/// 模型请求的工具调用(OpenAI function calling 格式)。
public struct ToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// 参数 JSON 字符串(原版 `parse_tool_arguments` 处理对象)
    public var arguments: String

    public init(id: String = UUID().uuidString, name: String, arguments: String = "{}") {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// 工具的模型侧描述(OpenAI tools 参数格式)。
public struct ToolSpec: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON Schema 格式参数定义
    public var parameters: [String: AnyCodable]

    public init(name: String, description: String, parameters: [String: AnyCodable] = [:]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// 任意可编码值的包装,用于工具参数 JSON Schema 与结构化输出。
/// 内部为不可变 JSON 值(NSNumber/String/Array/Dictionary 等),线程安全。
public struct AnyCodable: Codable, @unchecked Sendable, Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { value = b }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let arr = try? container.decode([AnyCodable].self) { value = arr.map(\.value) }
        else if let obj = try? container.decode([String: AnyCodable].self) { value = obj.mapValues(\.value) }
        else if container.decodeNil() { value = NSNull() }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解码 AnyCodable") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        case let arr as [Any]: try container.encode(arr.map(AnyCodable.init))
        case let obj as [String: Any]: try container.encode(obj.mapValues(AnyCodable.init))
        case is NSNull: try container.encodeNil()
        default: try container.encode(String(describing: value))
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}

// MARK: - 响应类型

/// 一次模型调用的 token 用量(兼容 OpenAI / DeepSeek 的缓存字段)。
public struct LLMUsage: Codable, Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    /// 命中缓存的 prompt token(无该字段时为 0)。
    public var cachedTokens: Int

    public init(
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        totalTokens: Int? = nil,
        cachedTokens: Int = 0
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens ?? (promptTokens + completionTokens)
        self.cachedTokens = cachedTokens
    }

    public static let zero = LLMUsage()

    public var cacheHitRate: Double {
        promptTokens > 0 ? min(1, max(0, Double(cachedTokens) / Double(promptTokens))) : 0
    }

    public static func + (lhs: LLMUsage, rhs: LLMUsage) -> LLMUsage {
        LLMUsage(
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            cachedTokens: lhs.cachedTokens + rhs.cachedTokens
        )
    }
}

/// 单轮完成的响应。
public struct LLMResponse: Sendable, Equatable {
    public var content: String
    public var toolCalls: [ToolCall]
    public var finishReason: String?
    public var usage: LLMUsage?

    public init(
        content: String,
        toolCalls: [ToolCall] = [],
        finishReason: String? = nil,
        usage: LLMUsage? = nil
    ) {
        self.content = content
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.usage = usage
    }
}

/// 流式增量块。
public struct LLMStreamChunk: Sendable, Equatable {
    public var delta: String
    public var toolCallAccumulator: [ToolCall]?
    public var finishReason: String?
    public var usage: LLMUsage?

    public init(
        delta: String,
        toolCallAccumulator: [ToolCall]? = nil,
        finishReason: String? = nil,
        usage: LLMUsage? = nil
    ) {
        self.delta = delta
        self.toolCallAccumulator = toolCallAccumulator
        self.finishReason = finishReason
        self.usage = usage
    }
}

// MARK: - 协议

public enum LLMError: Error, Sendable, Equatable {
    case invalidResponse
    case httpStatus(Int, String)
    case transport(String)
}

extension LLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "模型返回了无法解析的响应。请检查 Base URL 是否为 OpenAI 兼容的 /v1 地址、模型名是否正确,以及 API Key 是否填到了 Keychain 字段。"
        case .httpStatus(let code, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            return "模型请求失败 (HTTP \(code)): \(detail)"
        case .transport(let message):
            return "模型网络请求失败: \(message)"
        }
    }
}

/// 大模型客户端统一接口(对应原版 `LLMClient` 抽象)。
/// 实现必须为 Sendable,可跨 actor 传递。
public protocol LLMClient: Sendable {
    /// 非流式对话,支持工具调用
    func chat(messages: [ChatMessage], tools: [ToolSpec]?) async throws -> LLMResponse
    /// 流式对话
    func stream(messages: [ChatMessage], tools: [ToolSpec]?) -> AsyncThrowingStream<LLMStreamChunk, Error>
    /// 文本向量化(记忆检索用;不支持时返回 nil)
    func embed(text: String) async throws -> [Double]?
}
