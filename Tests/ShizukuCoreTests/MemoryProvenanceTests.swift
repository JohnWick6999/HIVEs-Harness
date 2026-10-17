import Foundation
@testable import ShizukuCore
import Testing

private func makeMemoryStore() throws -> SQLiteStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("shizuku-memory-db-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try SQLiteStore(path: dir.appendingPathComponent("agent.db").path)
}

@Suite("记忆溯源")
struct MemoryProvenanceTests {
    @Test("写入来源/置信度并可读回")
    func provenanceRoundtrip() throws {
        let store = try makeMemoryStore()
        _ = try store.addMemory(
            persona: "p",
            content: "用户喜欢冰美式",
            sourceThread: "thread-1",
            sourceKind: "tool",
            confidence: 0.8
        )
        let memory = try #require(try store.listMemories(persona: "p").first)
        #expect(memory.sourceThread == "thread-1")
        #expect(memory.sourceKind == "tool")
        #expect(memory.confidence == 0.8)
        #expect(memory.useCount == 0)
        #expect(memory.lastUsedAt == nil)
    }

    @Test("编辑记忆正文/置信度并重建检索")
    func updateMemory() throws {
        let store = try makeMemoryStore()
        let id = try store.addMemory(
            persona: "p",
            content: "用户喜欢旧口味",
            sourceKind: "manual",
            confidence: 0.4
        )
        #expect(try store.updateMemory(id: id, content: "用户喜欢新口味", confidence: 0.9))

        let memory = try #require(try store.listMemories(persona: "p").first)
        #expect(memory.content == "用户喜欢新口味")
        #expect(memory.confidence == 0.9)

        let results = try store.searchMemories(query: "新口味", persona: "p", topK: 3)
        #expect(results.contains { $0.id == id })
    }

    @Test("检索注入会累计使用次数")
    func retrievalUsage() throws {
        let store = try makeMemoryStore()
        _ = try store.addMemory(
            persona: "p",
            content: "用户喜欢冰美式咖啡每天一杯",
            sourceThread: "thread-1",
            sourceKind: "auto",
            confidence: 0.5
        )
        _ = try store.searchMemories(query: "冰美式", persona: "p", topK: 3)

        let memory = try #require(try store.listMemories(persona: "p").first)
        #expect(memory.useCount == 1)
        #expect(memory.lastUsedAt != nil)
    }

    @Test("AgentLoop 自动记忆带会话来源")
    func autoMemorySource() async throws {
        let fixture = try makeAgentFixture(responses: [LLMResponse(content: "好的")])
        _ = try await fixture.loop.invoke(message: "用户喜欢喝冰美式咖啡每天一杯不加糖")

        let memories = try fixture.store.listMemories(persona: "shizuku")
        let memory = try #require(memories.first { $0.content.contains("冰美式") })
        #expect(memory.sourceKind == "auto")
        #expect(memory.sourceThread == "persona:shizuku")
        #expect(memory.confidence == 0.5)
    }

    @Test("add_memory 工具带会话来源")
    func toolMemorySource() throws {
        let store = try makeMemoryStore()
        let tool = BuiltinTools.AddMemoryTool(store: store, persona: "p", threadID: "thread-2")
        _ = try tool.run(arguments: ["content": AnyCodable("用户偏好深色模式")])

        let memory = try #require(try store.listMemories(persona: "p").first)
        #expect(memory.sourceKind == "tool")
        #expect(memory.sourceThread == "thread-2")
        #expect(memory.confidence == 0.8)
    }
}
