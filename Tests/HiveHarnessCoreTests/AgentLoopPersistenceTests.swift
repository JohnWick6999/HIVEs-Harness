import Foundation
@testable import HiveHarnessCore
import Testing

/// AgentLoop 重构后的行为回归:invoke 与 stream 共用同一条落盘路径。
@Suite("AgentLoop 统一落盘")
struct AgentLoopPersistenceTests {
    @Test("非流式:工具产出文件写入历史附件")
    func invokePersistsAttachments() async throws {
        let args = #"{"path":"out.txt","content":"你好"}"#
        let fixture = try makeAgentFixture(responses: [
            LLMResponse(content: "", toolCalls: [ToolCall(name: "write_file", arguments: args)]),
            LLMResponse(content: "已写入"),
        ])

        _ = try await fixture.loop.invoke(message: "把你好写进文件")

        let saved = try fixture.store.loadMessages(threadID: "persona:assistant", persona: "assistant")
        #expect(saved?.count == 2)
        let assistant = saved?.last
        #expect(assistant?.role == .assistant)
        #expect(assistant?.fileAttachments.count == 1)
        #expect(assistant?.fileAttachments.first?.path.hasSuffix("out.txt") == true)
    }

    @Test("请求携带完整历史,由上下文管理器控制预算")
    func contextWindow() async throws {
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiveharness-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)

        var history: [ChatMessage] = []
        for index in 0..<20 {
            history.append(.text(index.isMultiple(of: 2) ? .user : .assistant, "历史 \(index)"))
        }
        try store.saveMessages(threadID: "persona:assistant", persona: "assistant", messages: history)

        let mock = MockLLMClient(responses: [LLMResponse(content: "收到")])
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiveharness-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let loop = AgentLoop(
            store: store,
            config: .default,
            keychain: KeychainStore(service: "com.hiveharness.test.\(UUID().uuidString)"),
            workspace: ws,
            clientOverride: mock
        )

        _ = try await loop.invoke(message: "最新问题")

        let request = try #require(mock.capturedMessages().first)
        // 1 条 system + 20 条历史 + 本轮用户消息(小上下文不触发压缩)
        #expect(request.count == 22)
        #expect(request.first?.role == .system)
        #expect(request.last?.content.plainText == "最新问题")
    }
}
