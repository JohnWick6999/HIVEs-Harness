import Foundation

/// 聊天记录,对齐原版 chat_records 表。
public struct ChatRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: Int64
    public let persona: String
    public let role: String
    public let content: String
    public let createdAt: String

    public init(id: Int64, persona: String, role: String, content: String, createdAt: String) {
        self.id = id
        self.persona = persona
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

/// 长期记忆条目,对齐原版 memories 表。
public struct MemoryItem: Codable, Sendable, Equatable, Identifiable {
    public let id: Int64
    public let persona: String
    public let kind: String
    public let content: String
    public let metadata: [String: AnyCodable]?
    /// 检索时的相似度得分(非检索场景为 nil)
    public let score: Double?
    public let createdAt: String
    /// 来源会话(自动记忆/工具写入时记录)
    public let sourceThread: String?
    /// auto / tool / manual
    public let sourceKind: String
    /// 置信度 0-1
    public let confidence: Double
    /// 被检索注入的次数
    public let useCount: Int
    /// 最近一次被检索的时间
    public let lastUsedAt: String?

    public init(
        id: Int64,
        persona: String,
        kind: String,
        content: String,
        metadata: [String: AnyCodable]?,
        score: Double? = nil,
        createdAt: String,
        sourceThread: String? = nil,
        sourceKind: String = "manual",
        confidence: Double = 0.6,
        useCount: Int = 0,
        lastUsedAt: String? = nil
    ) {
        self.id = id
        self.persona = persona
        self.kind = kind
        self.content = content
        self.metadata = metadata
        self.score = score
        self.createdAt = createdAt
        self.sourceThread = sourceThread
        self.sourceKind = sourceKind
        self.confidence = confidence
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }
}

/// 会话检查点,对齐原版 checkpoints 表(thread_id + persona 复合主键)。
public struct Checkpoint: Sendable, Equatable {
    public let threadID: String
    public let persona: String
    public let state: [String: AnyCodable]
    public let updatedAt: String

    public init(threadID: String, persona: String, state: [String: AnyCodable], updatedAt: String) {
        self.threadID = threadID
        self.persona = persona
        self.state = state
        self.updatedAt = updatedAt
    }
}
