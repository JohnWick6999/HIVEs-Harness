import Foundation
@testable import HiveHarnessCore
import Testing

@Suite("对话轮次摘要")
struct ConversationTurnsTests {
    @Test("按 user 分组并忽略 tool 消息")
    func buildTurns() {
        let messages: [ChatMessage] = [
            .text(.user, "第一轮问题"),
            .text(.assistant, "第一轮回答"),
            ChatMessage(role: .tool, content: .text("工具结果"), toolName: "read_file"),
            .text(.user, "第二轮问题"),
            .text(.assistant, "第二轮回答"),
        ]
        let turns = ConversationTurnBuilder.build(messages)
        #expect(turns.count == 2)
        #expect(turns[0].index == 1)
        #expect(turns[0].userText == "第一轮问题")
        #expect(turns[0].assistantText == "第一轮回答")
        #expect(turns[1].userText == "第二轮问题")
    }
}
