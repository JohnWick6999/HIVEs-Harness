import Foundation
@testable import HiveHarnessCore
import Testing

@Suite("会话归档与重命名")
struct SessionArchiveTests {
    private func makeStore() throws -> SQLiteStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hive-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteStore(path: dir.appendingPathComponent("agent.db").path)
    }

    @Test("归档后移出主列表,恢复后返回")
    func archive() throws {
        let store = try makeStore()
        let record = SessionRecord(id: "s1", persona: "assistant", title: "会话一")
        try store.upsertSession(record)

        try store.setSessionArchived(threadID: "s1", persona: "assistant", archived: true)
        #expect(try store.listSessions(persona: "assistant").isEmpty)
        #expect(try store.listArchivedSessions(persona: "assistant").count == 1)

        try store.setSessionArchived(threadID: "s1", persona: "assistant", archived: false)
        #expect(try store.listSessions(persona: "assistant").count == 1)
        #expect(try store.listArchivedSessions(persona: "assistant").isEmpty)
    }

    @Test("重命名通过 upsert 持久化")
    func rename() throws {
        let store = try makeStore()
        var record = SessionRecord(id: "s1", persona: "assistant", title: "旧标题")
        try store.upsertSession(record)
        record.title = "新标题"
        try store.upsertSession(record)
        #expect(try store.listSessions(persona: "assistant").first?.title == "新标题")
    }

    @Test("删除会清理会话索引")
    func delete() throws {
        let store = try makeStore()
        try store.upsertSession(SessionRecord(id: "s1", persona: "assistant", title: "待删"))
        try store.deleteSession(threadID: "s1", persona: "assistant")
        #expect(try store.listSessions(persona: "assistant").isEmpty)
    }

    @Test("旧 SessionRecord 默认未归档")
    func legacyDecode() throws {
        let json = """
        {"id":"s1","persona":"assistant","title":"旧会话","preview":"","createdAt":0,"updatedAt":0}
        """
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        #expect(!record.isArchived)
    }
}
