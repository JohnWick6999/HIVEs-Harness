import Foundation
@testable import ShizukuCore
import Testing

/// 脚本化 Mock LLM:按顺序弹出预设响应(含流式),并记录收到的消息。
final class MockLLMClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [LLMResponse]
    private var streamResponses: [[LLMStreamChunk]]
    private var captured: [[ChatMessage]] = []

    init(responses: [LLMResponse], streamResponses: [[LLMStreamChunk]] = []) {
        self.responses = responses
        self.streamResponses = streamResponses
    }

    func chat(messages: [ChatMessage], tools: [ToolSpec]?) async throws -> LLMResponse {
        lock.withLock {
            captured.append(messages)
            if responses.isEmpty { return LLMResponse(content: "(默认回复)") }
            return responses.removeFirst()
        }
    }

    func stream(messages: [ChatMessage], tools: [ToolSpec]?) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let chunks = lock.withLock {
                captured.append(messages)
                if streamResponses.isEmpty { return [LLMStreamChunk]() }
                return streamResponses.removeFirst()
            }
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    func embed(text: String) async throws -> [Double]? { nil }

    func capturedMessages() -> [[ChatMessage]] {
        lock.withLock { captured }
    }
}

func makeAgentFixture(
    responses: [LLMResponse],
    keychain: any KeychainStoring = KeychainStore(service: "com.shizukuclaw.test.\(UUID().uuidString)")
) throws -> (loop: AgentLoop, store: SQLiteStore, workspace: URL) {
    let ws = FileManager.default.temporaryDirectory
        .appendingPathComponent("shizuku-agent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

    let dbDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("shizuku-db-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    let store = try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)

    let loop = AgentLoop(
        store: store,
        config: .default,
        keychain: keychain,
        personas: PersonaStore(),
        workspace: ws,
        clientOverride: MockLLMClient(responses: responses)
    )
    return (loop, store, ws)
}

@Suite("AgentLoop")
struct AgentLoopTests {
    @Test("工具循环:调用工具后完成回复")
    func toolLoop() async throws {
        let args = #"{"path":"note.txt","content":"你好"}"#
        let fixture = try makeAgentFixture(responses: [
            LLMResponse(content: "", toolCalls: [ToolCall(name: "write_file", arguments: args)]),
            LLMResponse(content: "已写入文件"),
        ])
        let result = try await fixture.loop.invoke(message: "帮我写个文件")

        #expect(result.reply == "已写入文件")
        #expect(result.engine == "tool-loop")
        #expect(result.trace.count == 1)
        #expect(result.trace.first?.tool == "write_file")
        #expect(result.trace.first?.result.contains("已写入") == true)

        // 文件真实写入工作区
        let content = try String(contentsOf: fixture.workspace.appendingPathComponent("note.txt"), encoding: .utf8)
        #expect(content == "你好")

        // 检查点保存(用户 + 助手 2 条)
        let saved = try fixture.store.loadMessages(threadID: "persona:shizuku", persona: "shizuku")
        #expect(saved?.count == 2)

        // 聊天记录落库
        #expect(try fixture.store.listChatRecords().count == 2)
    }

    @Test("轮次上限:一直调用工具则停止")
    func roundLimit() async throws {
        let fixture = try makeAgentFixture(responses: [
            LLMResponse(content: "", toolCalls: [ToolCall(name: "list_dir", arguments: "{}")]),
            LLMResponse(content: "", toolCalls: [ToolCall(name: "list_dir", arguments: "{}")]),
            LLMResponse(content: "", toolCalls: [ToolCall(name: "list_dir", arguments: "{}")]),
            LLMResponse(content: "", toolCalls: [ToolCall(name: "list_dir", arguments: "{}")]),
            LLMResponse(content: "", toolCalls: [ToolCall(name: "list_dir", arguments: "{}")]),
            LLMResponse(content: "", toolCalls: [ToolCall(name: "list_dir", arguments: "{}")]),
            LLMResponse(content: "", toolCalls: [ToolCall(name: "list_dir", arguments: "{}")]),
        ])
        let result = try await fixture.loop.invoke(message: "一直列目录")

        #expect(result.reply.contains("工具调用轮次过多"))
        #expect(result.engine == "tool-loop-limit")
        #expect(result.trace.count == AppConfig.default.agent.maxRounds)
    }

    @Test("无 API Key 时本地回退")
    func localFallback() async throws {
        // 不注入 clientOverride:走 config 构建路径,空 key 触发回退
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)
        let keychain = KeychainStore(service: "com.shizukuclaw.empty.\(UUID().uuidString)")

        let loop = AgentLoop(store: store, config: .default, keychain: keychain, workspace: ws)
        let result = try await loop.invoke(message: "你好")

        #expect(result.reply.contains("本地回退"))
        #expect(result.engine == "local-fallback")
    }

    @Test("长消息自动写入长期记忆")
    func autoMemory() async throws {
        let fixture = try makeAgentFixture(responses: [LLMResponse(content: "好的,记住了")])
        let longMessage = "用户喜欢喝冰美式咖啡每天一杯不加糖"
        _ = try await fixture.loop.invoke(message: longMessage)

        let results = try fixture.store.searchMemories(query: "冰美式", persona: "shizuku", topK: 3)
        #expect(results.contains { $0.content == longMessage })
    }

    @Test("人格与记忆注入系统提示词")
    func personaInjection() async throws {
        // 自定义人格目录
        let personaDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-personas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: personaDir, withIntermediateDirectories: true)
        let personaJSON = """
        {
          "meta": {"name": "测试酱", "description": "测试用", "version": "1.0"},
          "character": {"name": "测试酱", "personality": "认真", "brother_qqid": "", "catchphrases": "明白"},
          "system_prompt": {"template": "你是{name},一个{personality}的助手,口头禅是{catchphrases}"}
        }
        """
        try personaJSON.write(to: personaDir.appendingPathComponent("test.json"), atomically: true, encoding: .utf8)

        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)
        _ = try store.addMemory(persona: "test", content: "用户喜欢抹茶", kind: "long_term")

        let mock = MockLLMClient(responses: [LLMResponse(content: "好的")])
        let loop = AgentLoop(
            store: store,
            config: .default,
            keychain: KeychainStore(service: "com.shizukuclaw.test.\(UUID().uuidString)"),
            personas: PersonaStore(directory: personaDir),
            workspace: ws,
            clientOverride: mock
        )
        _ = try await loop.invoke(message: "用户喜欢抹茶,是吗")

        let system = mock.capturedMessages().first?.first?.content.plainText ?? ""
        #expect(system.contains("你是测试酱,一个认真的助手"))
        #expect(system.contains("口头禅是明白"))
        #expect(system.contains("用户喜欢抹茶"))
    }

    @Test("流式:文本增量与 finished 事件")
    func streamChunks() async throws {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)
        let mock = MockLLMClient(
            responses: [],
            streamResponses: [[
                LLMStreamChunk(delta: "你"),
                LLMStreamChunk(delta: "好"),
                LLMStreamChunk(delta: "呀"),
            ]]
        )
        let loop = AgentLoop(
            store: store,
            config: .default,
            keychain: KeychainStore(service: "com.shizukuclaw.test.\(UUID().uuidString)"),
            workspace: ws,
            clientOverride: mock
        )

        var text = ""
        var finished: AgentResult?
        for try await event in await loop.stream(message: "嗨") {
            switch event {
            case .chunk(let delta):
                text += delta
            case .finished(let result):
                finished = result
            case .fallback, .toolCalled, .limitReached:
                break
            }
        }
        #expect(text == "你好呀")
        #expect(finished?.reply == "你好呀")
        #expect(finished?.engine == "tool-stream")
    }

    @Test("流式:无 API Key 发出 fallback 事件")
    func streamFallback() async throws {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)
        let loop = AgentLoop(
            store: store,
            config: .default,
            keychain: KeychainStore(service: "com.shizukuclaw.empty.\(UUID().uuidString)"),
            workspace: ws
        )

        var gotFallback = false
        var gotFinished = false
        for try await event in await loop.stream(message: "测试") {
            switch event {
            case .fallback(let text):
                gotFallback = text.contains("本地回退")
            case .finished(let result):
                gotFinished = result.engine == "local-fallback"
            default:
                break
            }
        }
        #expect(gotFallback)
        #expect(gotFinished)
    }

    @Test("内置人格资源加载")
    func bundledPersonas() {
        let store = PersonaStore()
        let personas = store.listPersonas()
        #expect(personas.count >= 5)
        #expect(store.load(id: "shizuku") != nil)
        let prompt = store.load(id: "shizuku")?.buildSystemPrompt() ?? ""
        #expect(prompt.contains("你叫"))
    }
}
