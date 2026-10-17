import Foundation

/// 会话索引记录:对话正文仍在 checkpoints 中,这里只保存列表展示与排序信息。
public struct SessionRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var persona: String
    public var title: String
    public var preview: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        persona: String,
        title: String,
        preview: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.persona = persona
        self.title = title
        self.preview = preview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
