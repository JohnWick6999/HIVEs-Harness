import Foundation
@testable import ShizukuCore
import Testing

private struct AlwaysFailingClient: LLMClient {
    func chat(messages: [ChatMessage], tools: [ToolSpec]?) async throws -> LLMResponse {
        throw LLMError.transport("模拟模型失败")
    }

    func stream(messages: [ChatMessage], tools: [ToolSpec]?) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError.transport("模拟模型失败")) }
    }

    func embed(text: String) async throws -> [Double]? { nil }
}

@Suite("运行日志")
struct RunJournalTests {
    @Test("成功运行写入 started/model/tool/finished 事件")
    func completedRun() async throws {
        let fixture = try makeAgentFixture(responses: [
            LLMResponse(content: "", toolCalls: [ToolCall(name: "list_dir", arguments: "{}")]),
            LLMResponse(content: "完成"),
        ])
        _ = try await fixture.loop.invoke(message: "列目录")

        let runs = try fixture.store.listRuns(
            threadID: "persona:shizuku",
            persona: "shizuku"
        )
        #expect(runs.count == 1)
        let run = try #require(runs.first)
        #expect(run.status == .completed)
        #expect(run.events.contains { $0.kind == .started })
        #expect(run.events.contains { $0.kind == .model })
        #expect(run.events.contains { $0.kind == .tool && $0.title == "list_dir" })
        #expect(run.events.contains { $0.kind == .finished })
        #expect(run.events.map(\.seq) == Array(1...run.events.count))
    }

    @Test("失败运行记录 failed 与 error 事件")
    func failedRun() async throws {
        let ws = try tempDir()
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-run-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)
        let loop = AgentLoop(
            store: store,
            config: .default,
            keychain: KeychainStore(service: "com.shizukuclaw.test.\(UUID().uuidString)"),
            workspace: ws,
            clientOverride: AlwaysFailingClient()
        )

        await #expect(throws: Error.self) {
            _ = try await loop.invoke(message: "你好")
        }

        let runs = try store.listRuns(persona: "shizuku")
        #expect(runs.count == 1)
        #expect(runs.first?.status == .failed)
        #expect(runs.first?.events.contains { $0.kind == .error } == true)
    }

    @Test("事件回放游标:单步/跳转/重置")
    func replayCursor() {
        let run = RunRecord(
            id: "run-replay",
            threadID: "t",
            persona: "p",
            status: .completed,
            events: [
                RunEvent(seq: 1, kind: .started, title: "开始"),
                RunEvent(seq: 2, kind: .tool, title: "list_dir"),
                RunEvent(seq: 3, kind: .finished, title: "完成"),
            ]
        )
        var replay = RunReplay(run: run)
        #expect(replay.cursor == 0)
        #expect(replay.visibleEvents.isEmpty)
        #expect(replay.step()?.seq == 1)
        #expect(replay.visibleEvents.count == 1)
        replay.jump(to: 2)
        #expect(replay.cursor == 2)
        #expect(replay.current?.seq == 2)
        replay.toEnd()
        #expect(replay.isFinished)
        #expect(replay.visibleEvents.count == 3)
        replay.reset()
        #expect(replay.cursor == 0)
    }

    @Test("保存/读取/删除运行记录")
    func storeRoundtrip() throws {
        let store = try SQLiteStore(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("shizuku-run-\(UUID().uuidString).db").path
        )
        let run = RunRecord(
            id: "run-1",
            threadID: "t",
            persona: "p",
            status: .completed,
            model: "m",
            events: [
                RunEvent(seq: 1, kind: .started, title: "开始"),
                RunEvent(seq: 2, kind: .finished, title: "完成"),
            ]
        )
        try store.saveRun(run)
        #expect(try store.listRuns(persona: "p").count == 1)
        #expect(try store.loadRun(id: "run-1")?.events.count == 2)

        try store.deleteRun(id: "run-1")
        #expect(try store.listRuns(persona: "p").isEmpty)
    }
}
