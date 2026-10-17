import Foundation
@testable import HiveHarnessCore
import Testing

private func makeContextStore() throws -> SQLiteStore {
    let dbDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hiveharness-context-db-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    return try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)
}

private func longHistory(turns: Int, chars: Int) -> [ChatMessage] {
    var messages: [ChatMessage] = []
    for turn in 0..<turns {
        messages.append(.text(.user, String(repeating: "用", count: chars) + " \(turn)"))
        messages.append(.text(.assistant, String(repeating: "答", count: chars) + " \(turn)"))
    }
    return messages
}

@Suite("上下文压缩")
struct ContextManagerTests {
    @Test("token 估算:CJK 按 1 token,ASCII 按 1/3")
    func estimator() {
        let cjk = TokenEstimator.estimate(String(repeating: "你", count: 300))
        let ascii = TokenEstimator.estimate(String(repeating: "a", count: 300))
        #expect(cjk > 280)
        #expect(ascii < 120)
        #expect(TokenEstimator.estimate("") == 4)
    }

    @Test("未达阈值时不调用摘要模型")
    func noCompactionUnderBudget() async throws {
        let store = try makeContextStore()
        let client = MockLLMClient(responses: [])
        let manager = ContextManager(store: store, contextWindow: 32_768, maxOutputTokens: 4_096)
        let messages: [ChatMessage] = [
            .text(.system, "系统提示"),
            .text(.user, "你好"),
            .text(.assistant, "你好呀"),
        ]

        let result = try await manager.prepare(
            messages: messages,
            tools: [],
            threadID: "t",
            persona: "p",
            model: "mock",
            client: client
        )

        #expect(result.state.hasCompaction == false)
        #expect(result.state.coveredCount == 0)
        #expect(result.messages.count == messages.count)
        #expect(client.capturedMessages().isEmpty)
        #expect(try store.loadContextState(threadID: "t", persona: "p").estimatedTokens > 0)
    }

    @Test("超过 85% 时压缩早期历史并保留最近两轮")
    func compactsOlderHistory() async throws {
        let store = try makeContextStore()
        let client = MockLLMClient(responses: [LLMResponse(content: "摘要:用户在做上下文压缩测试。")])
        let manager = ContextManager(store: store, contextWindow: 4_000, maxOutputTokens: 500)

        var body = longHistory(turns: 3, chars: 500)
        body.append(.text(.user, "最新问题"))
        let messages = [ChatMessage.text(.system, "系统提示")] + body

        let result = try await manager.prepare(
            messages: messages,
            tools: [],
            threadID: "t",
            persona: "p",
            model: "mock",
            client: client
        )

        #expect(result.state.hasCompaction)
        #expect(result.state.summary.contains("上下文压缩测试"))
        #expect(result.state.coveredCount == 4)  // 保留 u3/a3 + 最新问题
        // system + 摘要 system + 保留的 3 条
        #expect(result.messages.count == 5)
        #expect(result.messages.first?.role == .system)
        #expect(result.messages[1].content.plainText.contains("会话压缩摘要"))
        #expect(result.messages.last?.content.plainText == "最新问题")

        // 原始消息不被修改
        #expect(messages.count == 8)
        // 摘要在独立状态表中
        let saved = try store.loadContextState(threadID: "t", persona: "p")
        #expect(saved.coveredCount == 4)
        #expect(saved.hasCompaction)
    }

    @Test("历史被修改后旧摘要失效")
    func invalidatesStaleSummary() async throws {
        let store = try makeContextStore()
        try store.saveContextState(
            SessionContextState(
                summary: "旧摘要",
                coveredCount: 2,
                prefixHash: "stale-hash"
            ),
            threadID: "t",
            persona: "p"
        )
        let client = MockLLMClient(responses: [])
        let manager = ContextManager(store: store, contextWindow: 32_768, maxOutputTokens: 4_096)
        let messages: [ChatMessage] = [
            .text(.system, "系统"),
            .text(.user, "新问题"),
        ]

        let result = try await manager.prepare(
            messages: messages,
            tools: [],
            threadID: "t",
            persona: "p",
            model: "mock",
            client: client
        )

        #expect(result.state.coveredCount == 0)
        #expect(result.state.summary.isEmpty)
        #expect(result.messages.count == 2)
    }

    @Test("单轮超长工具结果在请求视图中节选")
    func prunesOversizedToolOutput() async throws {
        let store = try makeContextStore()
        let client = MockLLMClient(responses: [])
        let manager = ContextManager(store: store, contextWindow: 3_000, maxOutputTokens: 300)
        let messages: [ChatMessage] = [
            .text(.system, "系统"),
            .text(.user, "读一下"),
            ChatMessage(
                role: .tool,
                content: .text(String(repeating: "文", count: 3_000)),
                toolCallID: "call-1",
                toolName: "read_file"
            ),
        ]

        let result = try await manager.prepare(
            messages: messages,
            tools: [],
            threadID: "t",
            persona: "p",
            model: "mock",
            client: client
        )

        #expect(result.state.prunedTools == 1)
        let toolText = result.messages.last?.content.plainText ?? ""
        #expect(toolText.count < 1_400)
        #expect(toolText.contains("已节选"))
        // 原始记录仍保留完整内容
        #expect(messages.last?.content.plainText.count == 3_000)
    }

    @Test("压缩与节选后仍超预算则报错")
    func throwsWhenStillOverBudget() async throws {
        let store = try makeContextStore()
        let client = MockLLMClient(responses: [])
        let manager = ContextManager(store: store, contextWindow: 1_000, maxOutputTokens: 200)
        let messages: [ChatMessage] = [
            .text(.system, "系统"),
            .text(.user, "读一下"),
            ChatMessage(
                role: .tool,
                content: .text(String(repeating: "文", count: 3_000)),
                toolCallID: "call-1",
                toolName: "read_file"
            ),
        ]

        await #expect(throws: ContextError.self) {
            try await manager.prepare(
                messages: messages,
                tools: [],
                threadID: "t",
                persona: "p",
                model: "mock",
                client: client
            )
        }
    }

    @Test("AgentLoop 集成:超预算时先摘要再回答")
    func loopCompactsBeforeAnswer() async throws {
        let store = try makeContextStore()
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiveharness-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

        try store.saveMessages(
            threadID: "persona:assistant",
            persona: "assistant",
            messages: longHistory(turns: 3, chars: 500)
        )

        var config = AppConfig.default
        config.llm.contextWindow = 4_000
        config.llm.maxOutputTokens = 500
        let mock = MockLLMClient(responses: [
            LLMResponse(content: "摘要:历史已压缩"),
            LLMResponse(content: "回答"),
        ])
        let loop = AgentLoop(
            store: store,
            config: config,
            keychain: KeychainStore(service: "com.hiveharness.test.\(UUID().uuidString)"),
            workspace: ws,
            clientOverride: mock
        )

        let result = try await loop.invoke(message: "最新问题")

        #expect(result.reply == "回答")
        let state = try store.loadContextState(threadID: "persona:assistant", persona: "assistant")
        #expect(state.hasCompaction)
        let lastRequest = try #require(mock.capturedMessages().last)
        #expect(lastRequest.contains { $0.content.plainText.contains("会话压缩摘要") })
        #expect(lastRequest.last?.content.plainText == "最新问题")
    }
}
