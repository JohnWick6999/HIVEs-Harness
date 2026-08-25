import Foundation
@testable import ShizukuCore
import Testing

func tempStore() throws -> SQLiteStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("shizuku-db-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try SQLiteStore(path: dir.appendingPathComponent("agent.db").path)
}

@Suite("TextEmbedding")
struct TextEmbeddingTests {
    @Test("确定性:相同文本向量相同")
    func deterministic() {
        #expect(TextEmbedding.hashVector("苹果电脑") == TextEmbedding.hashVector("苹果电脑"))
    }

    @Test("相似文本余弦更高")
    func similarityRanking() {
        let query = TextEmbedding.hashVector("苹果")
        let apple = TextEmbedding.hashVector("苹果电脑很好用")
        let banana = TextEmbedding.hashVector("香蕉很好吃")
        #expect(TextEmbedding.cosine(query, apple) > TextEmbedding.cosine(query, banana))
    }

    @Test("归一化向量模长为 1")
    func normalized() {
        let vector = TextEmbedding.hashVector("测试文本")
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        #expect(abs(norm - 1) < 1e-9)
    }

    @Test("共享字符检测(忽略空白)")
    func sharedCharacters() {
        #expect(TextEmbedding.hasSharedCharacters("苹果", "苹果电脑很好用"))
        #expect(TextEmbedding.hasSharedCharacters("Apple Music", "用户在用 Apple Music 听 R&B"))
        #expect(!TextEmbedding.hasSharedCharacters("不存在的关键词xyz", "用户喜欢 R&B"))
        #expect(!TextEmbedding.hasSharedCharacters("hello", "你好世界"))
    }
}

@Suite("SQLiteStore")
struct SQLiteStoreTests {
    @Test("聊天记录增删查")
    func chatRecords() throws {
        let store = try tempStore()
        let id1 = try store.addChatRecord(persona: "shizuku", role: "user", content: "你好")
        let id2 = try store.addChatRecord(persona: "shizuku", role: "assistant", content: "嗨")
        #expect(id2 > id1)

        let records = try store.listChatRecords()
        #expect(records.count == 2)
        #expect(records.first?.content == "嗨")  // 按 id DESC

        #expect(try store.deleteChatRecord(id: id1) == true)
        #expect(try store.deleteChatRecord(id: 99999) == false)
        #expect(try store.listChatRecords().count == 1)

        try store.clearChatRecords()
        #expect(try store.listChatRecords().isEmpty)
    }

    @Test("deleteFirstN 只删前 N 条")
    func deleteFirstN() throws {
        let store = try tempStore()
        for i in 0..<5 {
            _ = try store.addChatRecord(persona: "p", role: "user", content: "msg\(i)")
        }
        let deleted = try store.deleteFirstN(3)
        #expect(deleted == 3)
        #expect(try store.listChatRecords().count == 2)
    }

    @Test("记忆写入与列表")
    func memories() throws {
        let store = try tempStore()
        _ = try store.addMemory(persona: "shizuku", content: "用户喜欢 R&B 音乐", kind: "long_term")
        _ = try store.addMemory(persona: "azuma", content: "另一条记忆", kind: "long_term")

        let all = try store.listMemories()
        #expect(all.count == 2)

        let filtered = try store.listMemories(persona: "shizuku", kind: "long_term")
        #expect(filtered.count == 1)
        #expect(filtered.first?.content == "用户喜欢 R&B 音乐")
        #expect(filtered.first?.score == nil)
    }

    @Test("记忆检索按相似度排序")
    func memorySearch() throws {
        let store = try tempStore()
        _ = try store.addMemory(persona: "shizuku", content: "用户在用 Apple Music 听 R&B")
        _ = try store.addMemory(persona: "shizuku", content: "用户明天要去沈阳建筑大学上课")
        _ = try store.addMemory(persona: "shizuku", content: "Apple Music 会员到期时间")

        let results = try store.searchMemories(query: "Apple Music", persona: "shizuku", topK: 2)
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.score != nil })
        // 相关度更高的记忆排前面
        #expect(results[0].content.contains("Apple Music"))
        #expect(results[0].score! >= results[1].score!)
    }

    @Test("检查点保存与加载")
    func checkpoints() throws {
        let store = try tempStore()
        #expect(try store.loadCheckpoint(threadID: "t1", persona: "shizuku") == nil)

        let state: [String: AnyCodable] = [
            "messages": AnyCodable(["a", "b"]),
            "count": AnyCodable(3),
        ]
        try store.saveCheckpoint(threadID: "t1", persona: "shizuku", state: state)
        let loaded = try store.loadCheckpoint(threadID: "t1", persona: "shizuku")
        #expect((loaded?["count"]?.value as? Int) == 3)
        #expect((loaded?["messages"]?.value as? [String]) == ["a", "b"])

        // 覆盖更新
        try store.saveCheckpoint(threadID: "t1", persona: "shizuku", state: ["count": AnyCodable(9)])
        let updated = try store.loadCheckpoint(threadID: "t1", persona: "shizuku")
        #expect((updated?["count"]?.value as? Int) == 9)
    }

    @Test("KV 存储")
    func kvStore() throws {
        let store = try tempStore()
        #expect(try store.getKV(key: "port") == nil)

        try store.setKV(key: "port", value: AnyCodable(8888))
        #expect((try store.getKV(key: "port"))?.value as? Int == 8888)

        try store.setKV(key: "port", value: AnyCodable(9000))
        #expect((try store.getKV(key: "port"))?.value as? Int == 9000)
    }

    @Test("重复初始化不破坏数据(迁移幂等)")
    func reopenIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("agent.db").path

        let store1 = try SQLiteStore(path: path)
        _ = try store1.addChatRecord(persona: "p", role: "user", content: "x")
        let store2 = try SQLiteStore(path: path)
        #expect(try store2.listChatRecords().count == 1)
    }

    @Test("删除单条记忆")
    func deleteMemory() throws {
        let store = try tempStore()
        let id1 = try store.addMemory(persona: "shizuku", content: "记忆一", kind: "long_term")
        let id2 = try store.addMemory(persona: "shizuku", content: "记忆二", kind: "long_term")

        #expect(try store.deleteMemory(id: id1) == true)
        #expect(try store.deleteMemory(id: 99999) == false)
        let remaining = try store.listMemories(persona: "shizuku")
        #expect(remaining.count == 1)
        #expect(remaining.first?.content == "记忆二")
    }
}
