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
    @Test("滚动可见消息反推当前轮次")
    func visibleMessageTurn() {
        let firstUser = ChatMessage.text(.user, "第一轮")
        let firstAssistant = ChatMessage.text(.assistant, "第一轮回答")
        let tool = ChatMessage(role: .tool, content: .text("工具结果"), toolCallID: "call_1")
        let secondUser = ChatMessage.text(.user, "第二轮")
        let secondAssistant = ChatMessage.text(.assistant, "第二轮回答")
        let messages = [firstUser, firstAssistant, tool, secondUser, secondAssistant]
        let turns = ConversationTurnBuilder.build(messages)
        #expect(turns.count == 2)
        #expect(ConversationTurnBuilder.turnID(containing: firstUser.id, in: messages) == turns[0].id)
        #expect(ConversationTurnBuilder.turnID(containing: firstAssistant.id, in: messages) == turns[0].id)
        #expect(ConversationTurnBuilder.turnID(containing: tool.id, in: messages) == turns[0].id)
        #expect(ConversationTurnBuilder.turnID(containing: secondUser.id, in: messages) == turns[1].id)
        #expect(ConversationTurnBuilder.turnID(containing: secondAssistant.id, in: messages) == turns[1].id)
    }

}
