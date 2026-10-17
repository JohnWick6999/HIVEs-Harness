import Foundation

/// 会话索引记录:对话正文仍在 checkpoints 中,这里只保存列表展示与排序信息。
public struct SessionRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var persona: String
    public var title: String
    public var preview: String
    public var createdAt: Date
    public var updatedAt: Date
    /// 归档会话不出现在主列表,但保留全部数据。
    public var isArchived: Bool

    public init(
        id: String,
        persona: String,
        title: String,
        preview: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isArchived: Bool = false
    ) {
        self.id = id
        self.persona = persona
        self.title = title
        self.preview = preview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey {
        case id, persona, title, preview, createdAt, updatedAt, isArchived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        persona = try container.decode(String.self, forKey: .persona)
        title = try container.decode(String.self, forKey: .title)
        preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}
