import Foundation

/// 对话轮次摘要:用于右侧对话条和悬停预览。
public struct ConversationTurn: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var index: Int
    public var userText: String
    public var assistantText: String
    public var targetMessageID: UUID

    public init(
        id: UUID,
        index: Int,
        userText: String,
        assistantText: String,
        targetMessageID: UUID
    ) {
        self.id = id
        self.index = index
        self.userText = userText
        self.assistantText = assistantText
        self.targetMessageID = targetMessageID
    }
}

public enum ConversationTurnBuilder {
    public static func build(_ messages: [ChatMessage]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var current: (id: UUID, user: String, assistant: String)?

        func flush() {
            guard let current else { return }
            turns.append(
                ConversationTurn(
                    id: current.id,
                    index: turns.count + 1,
                    userText: summary(current.user, limit: 90),
                    assistantText: summary(current.assistant, limit: 140),
                    targetMessageID: current.id
                )
            )
        }

        for message in messages {
            switch message.role {
            case .user:
                flush()
                current = (message.id, message.content.plainText, "")
            case .assistant:
                if var turn = current {
                    let text = message.content.plainText
                    if !text.isEmpty {
                        turn.assistant += (turn.assistant.isEmpty ? "" : "\n") + text
                    }
                    current = turn
                }
            default:
                break
            }
        }
        flush()
        return turns
    }

    private static func summary(_ text: String, limit: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n\n[用户上传附件]", with: "\n[附件]")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)) + "…"
    }
}
