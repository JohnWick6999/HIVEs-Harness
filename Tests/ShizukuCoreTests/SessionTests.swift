import Foundation
@testable import ShizukuCore
import Testing

private func makeSessionStore() throws -> SQLiteStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("shizuku-session-db-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try SQLiteStore(path: dir.appendingPathComponent("agent.db").path)
}

@Suite("会话索引")
struct SessionTests {
    @Test("upsert/list/delete 与关联数据清理")
    func lifecycle() throws {
        let store = try makeSessionStore()
        let older = SessionRecord(
            id: "s1",
            persona: "p",
            title: "旧会话",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = SessionRecord(
            id: "s2",
            persona: "p",
            title: "新会话",
            createdAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try store.upsertSession(older)
        try store.upsertSession(newer)

        #expect(try store.listSessions(persona: "p").map(\.id) == ["s2", "s1"])

        try store.saveMessages(threadID: "s1", persona: "p", messages: [.text(.user, "hi")])
        try store.saveTaskPlan(
            TaskPlan(items: [TaskItem(content: "步骤")], running: false),
            threadID: "s1",
            persona: "p"
        )
        try store.saveContextState(
            SessionContextState(summary: "摘要"),
            threadID: "s1",
            persona: "p"
        )
        _ = try store.addChatRecord(persona: "p", role: "user", content: "hi", threadID: "s1")
        _ = try store.addChatRecord(persona: "p", role: "user", content: "hi2", threadID: "s2")

        try store.deleteSession(threadID: "s1", persona: "p")

        #expect(try store.listSessions(persona: "p").map(\.id) == ["s2"])
        #expect((try store.loadMessages(threadID: "s1", persona: "p"))?.isEmpty ?? true)
        #expect(try store.loadTaskPlan(threadID: "s1", persona: "p").items.isEmpty)
        #expect(try store.loadContextState(threadID: "s1", persona: "p").summary.isEmpty)
        #expect(try store.listChatRecords(threadID: "s1").isEmpty)
        #expect(try store.listChatRecords(threadID: "s2").count == 1)
    }

    @Test("AgentLoop 落库的聊天记录带会话 id")
    func agentRecordsThread() async throws {
        let fixture = try makeAgentFixture(responses: [LLMResponse(content: "好的")])
        _ = try await fixture.loop.invoke(message: "你好", threadID: "s_custom")

        let records = try fixture.store.listChatRecords(threadID: "s_custom")
        #expect(records.count == 2)
        #expect(records.contains { $0.role == "assistant" && $0.content == "好的" })
    }
}
