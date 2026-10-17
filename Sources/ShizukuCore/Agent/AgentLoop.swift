import Foundation

/// 单轮工具调用轨迹(对齐原版 trace)
public struct ToolTrace: Sendable, Equatable {
    public let tool: String
    public let arguments: String
    public let result: String
    /// 产出文件路径(UI 可点击打开)
    public let files: [String]

    public init(tool: String, arguments: String, result: String, files: [String] = []) {
        self.tool = tool
        self.arguments = arguments
        self.result = result
        self.files = files
    }
}

/// Agent 调用结果(对齐原版 invoke 返回值)
public struct AgentResult: Sendable, Equatable {
    public let success: Bool
    public let persona: String
    public let reply: String
    public let memories: [MemoryItem]
    public let engine: String
    public let trace: [ToolTrace]

    public init(
        success: Bool,
        persona: String,
        reply: String,
        memories: [MemoryItem],
        engine: String,
        trace: [ToolTrace]
    ) {
        self.success = success
        self.persona = persona
        self.reply = reply
        self.memories = memories
        self.engine = engine
        self.trace = trace
    }
}

/// 流式事件(UI 直接消费)
public enum AgentStreamEvent: Sendable {
    /// 回复文本增量
    case chunk(String)
    /// 工具调用轨迹
    case toolCalled(ToolTrace)
    /// 本地回退(无 API Key)
    case fallback(String)
    /// 工具轮次上限
    case limitReached(String)
    /// 结束(携带完整结果,落盘后发出)
    case finished(AgentResult)
}

/// 传统工具循环 Agent(对齐原版 `app/agent/loop.py`)。
/// 核心流程:注入人格 + 长期记忆 -> 循环调用 LLM -> 有工具调用则执行并回填,直到模型直接回复或达到轮次上限。
///
/// 调用路径统一为四步,`invoke` 与 `stream` 只是最后一步的呈现方式不同:
/// 1. `prepareSession` 恢复历史、追加用户消息、检索记忆、构建系统提示词;
/// 2. `makeRunMode` 解析客户端(含无 Key 本地回退)并装配工具注册表;
/// 3. `runToolLoop` 执行模型/工具循环(流式或非流式);
/// 4. `persist` 落盘历史、聊天记录与自动记忆。
public actor AgentLoop {
    private let store: SQLiteStore
    private let config: AppConfig
    private let keychain: any KeychainStoring
    private let personas: PersonaStore
    private let workspace: URL
    /// 测试注入:固定客户端(优先于 config 构建)
    private let clientOverride: (any LLMClient)?
    /// 测试注入:固定工具集(nil 时按 workspace/persona 构建内置工具)
    private let toolsOverride: [any Tool]?

    /// 历史保留条数(对齐原版 40)
    private let historyLimit = 40
    /// 单次请求携带的最近消息条数
    private let contextMessageLimit = 12
    /// 用户消息达到此长度自动写入长期记忆(对齐原版 12)
    private let autoMemoryThreshold = 12
    private let imageHint = "不要调用 read_file 去读 png/jpg/gif/webp。"

    public init(
        store: SQLiteStore,
        config: AppConfig,
        keychain: any KeychainStoring,
        personas: PersonaStore = PersonaStore(),
        workspace: URL = FileManager.default.temporaryDirectory,
        clientOverride: (any LLMClient)? = nil,
        toolsOverride: [any Tool]? = nil
    ) {
        self.store = store
        self.config = config
        self.keychain = keychain
        self.personas = personas
        self.workspace = workspace
        self.clientOverride = clientOverride
        self.toolsOverride = toolsOverride
    }

    // MARK: - 会话准备

    /// 一次运行所需的全部会话上下文(准备阶段产出,执行/落盘阶段只读)。
    private struct Session {
        let persona: String
        let threadID: String
        /// 用户输入的原始文本(落聊天记录用)
        let userText: String
        /// 含本轮用户消息的完整历史
        var history: [ChatMessage]
        let memories: [MemoryItem]
        let systemPrompt: String
    }

    /// 运行模式:真实客户端 + 工具集,或无 Key 本地回退。
    private enum RunMode {
        case live(client: any LLMClient, registry: ToolRegistry, specs: [ToolSpec])
        case fallback(reply: String)
    }

    public func defaultPersona() -> String {
        // 优先配置的默认人格;不存在时回退到第一个可用人格
        let configured = config.agent.defaultPersona
        if personas.load(id: configured) != nil {
            return configured
        }
        return personas.defaultPersona()?.id ?? configured
    }

    public func availablePersonas() -> [Persona] {
        personas.listPersonas()
    }

    /// 恢复历史、追加用户消息、检索记忆并构建系统提示词。
    private func prepareSession(
        message: String,
        persona: String?,
        threadID: String?
    ) -> Session {
        let current = persona ?? defaultPersona()
        let thread = threadID ?? "persona:\(current)"

        var history = (try? store.loadMessages(threadID: thread, persona: current)) ?? []
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        history.append(.text(.user, text.isEmpty ? "（空消息）" : text))

        let memories = (try? store.searchMemories(
            query: text.isEmpty ? current : text,
            persona: current,
            topK: 5
        )) ?? []

        return Session(
            persona: current,
            threadID: thread,
            userText: text,
            history: history,
            memories: memories,
            systemPrompt: buildSystemPrompt(persona: current, memories: memories)
        )
    }

    /// 人格 prompt + 长期记忆 + 工具使用约束。
    private func buildSystemPrompt(persona: String, memories: [MemoryItem]) -> String {
        let memoryText = memories.isEmpty
            ? "暂无长期记忆。"
            : memories.map { "- \($0.content)" }.joined(separator: "\n")
        let personaPrompt = personas.load(id: persona)?.buildSystemPrompt() ?? config.agent.systemPrompt
        return """
        \(personaPrompt)

        [长期记忆]
        \(memoryText)

        你是传统工具循环 Agent:需要外部信息时先调用工具,再根据工具结果回答。
        \(imageHint)

        文件工具(list_dir/read_file/write_file)只能访问工作区目录,无法访问桌面、文稿等系统位置。
        若用户要求写到桌面或其他目录,将文件写入工作区,并在回复中明确说明文件的实际完整路径。
        """
    }

    // MARK: - 客户端与工具装配

    /// 解析客户端:测试注入 > Ollama > OpenAI 兼容;无 Key 时返回本地回退。
    private func makeRunMode(persona: String, history: [ChatMessage]) -> RunMode {
        let client: any LLMClient
        if let clientOverride {
            client = clientOverride
        } else {
            let apiKey = (try? keychain.string(forKey: "llm.api_key")) ?? ""
            if config.llm.provider != "ollama" && apiKey.isEmpty {
                let lastUser = history.last(where: { $0.role == .user })?.content.plainText ?? ""
                let reply = """
                [\(persona)] 已收到:\(lastUser)
                当前运行传统 Agent 循环。未配置主模型 API Key,因此使用本地回退回复。
                """
                return .fallback(reply: reply)
            }
            if config.llm.provider == "ollama" {
                client = LocalOllamaClient(model: config.llm.model, temperature: config.llm.temperature)
            } else {
                client = OpenAICompatibleClient(
                    baseURL: config.llm.baseURL,
                    apiKey: apiKey,
                    model: config.llm.model,
                    temperature: config.llm.temperature
                )
            }
        }

        let (registry, specs) = makeToolRegistry(persona: persona)
        return .live(client: client, registry: registry, specs: specs)
    }

    private func makeToolRegistry(persona: String) -> (ToolRegistry, [ToolSpec]) {
        let tools = toolsOverride ?? buildDefaultTools(persona: persona)
        let registry = ToolRegistry()
        for tool in tools {
            registry.register(tool)
        }
        return (registry, tools.map(\.spec))
    }

    /// 内置工具集(绑定当前人格与工作区)
    private func buildDefaultTools(persona: String) -> [any Tool] {
        var tools: [any Tool] = [
            BuiltinTools.ListDirTool(workspace: workspace),
            BuiltinTools.ReadFileTool(workspace: workspace),
            BuiltinTools.WriteFileTool(workspace: workspace),
            BuiltinTools.SearchMemoryTool(store: store, persona: persona),
            BuiltinTools.AddMemoryTool(store: store, persona: persona),
        ]
        #if os(macOS)
        tools.append(BuiltinTools.RunLocalAgentTool())
        #endif
        return tools
    }

    // MARK: - 主入口

    public func invoke(
        message: String,
        persona: String? = nil,
        threadID: String? = nil
    ) async throws -> AgentResult {
        let session = prepareSession(message: message, persona: persona, threadID: threadID)

        switch makeRunMode(persona: session.persona, history: session.history) {
        case .fallback(let reply):
            persist(session, reply: reply, traces: [])
            return AgentResult(
                success: true,
                persona: session.persona,
                reply: reply,
                memories: session.memories,
                engine: "local-fallback",
                trace: []
            )
        case let .live(client, registry, specs):
            let (reply, traces, engine) = try await runToolLoop(
                session: session,
                client: client,
                registry: registry,
                specs: specs,
                yield: nil
            )
            persist(session, reply: reply, traces: traces)
            return AgentResult(
                success: true,
                persona: session.persona,
                reply: reply,
                memories: session.memories,
                engine: engine,
                trace: traces
            )
        }
    }

    // MARK: - 流式入口

    /// 流式调用:逐块产出文本增量,工具调用与结束状态以事件形式发出。
    public func stream(
        message: String,
        persona: String? = nil,
        threadID: String? = nil
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStreaming(message: message, persona: persona, threadID: threadID) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runStreaming(
        message: String,
        persona: String?,
        threadID: String?,
        yield: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws {
        let session = prepareSession(message: message, persona: persona, threadID: threadID)

        switch makeRunMode(persona: session.persona, history: session.history) {
        case .fallback(let reply):
            yield(.fallback(reply))
            persist(session, reply: reply, traces: [])
            yield(.finished(AgentResult(
                success: true,
                persona: session.persona,
                reply: reply,
                memories: session.memories,
                engine: "local-fallback",
                trace: []
            )))
        case let .live(client, registry, specs):
            let (reply, traces, engine) = try await runToolLoop(
                session: session,
                client: client,
                registry: registry,
                specs: specs,
                yield: yield
            )
            persist(session, reply: reply, traces: traces)
            yield(.finished(AgentResult(
                success: true,
                persona: session.persona,
                reply: reply,
                memories: session.memories,
                engine: engine,
                trace: traces
            )))
        }
    }

    // MARK: - 工具循环

    /// 模型/工具循环。`yield == nil` 走非流式 `chat`,`yield != nil` 走流式 `stream`。
    private func runToolLoop(
        session: Session,
        client: any LLMClient,
        registry: ToolRegistry,
        specs: [ToolSpec],
        yield: (@Sendable (AgentStreamEvent) -> Void)?
    ) async throws -> (reply: String, traces: [ToolTrace], engine: String) {
        let streaming = yield != nil
        var messages: [ChatMessage] = [.text(.system, session.systemPrompt)]
        messages.append(contentsOf: session.history.suffix(contextMessageLimit))
        var traces: [ToolTrace] = []

        for _ in 0..<max(config.agent.maxRounds, 1) {
            let text: String
            let toolCalls: [ToolCall]
            if streaming {
                (text, toolCalls) = try await streamOnce(
                    client: client,
                    messages: messages,
                    specs: specs,
                    yield: yield
                )
            } else {
                let response = try await client.chat(messages: messages, tools: specs)
                text = response.content
                toolCalls = response.toolCalls
            }

            if toolCalls.isEmpty {
                return (text, traces, streaming ? "tool-stream" : "tool-loop")
            }

            // 回填 assistant 工具调用消息
            messages.append(
                ChatMessage(
                    role: .assistant,
                    content: .text(text),
                    toolCalls: toolCalls
                )
            )

            // 逐个执行工具
            for call in toolCalls {
                let (trace, toolMessage) = await execute(call, registry: registry)
                traces.append(trace)
                yield?(.toolCalled(trace))
                messages.append(toolMessage)
            }
        }

        let limitText = "工具调用轮次过多,已停止。请把问题拆小后再试。"
        yield?(.limitReached(limitText))
        return (limitText, traces, "tool-loop-limit")
    }

    /// 单轮流式请求:累积文本增量与工具调用。
    private func streamOnce(
        client: any LLMClient,
        messages: [ChatMessage],
        specs: [ToolSpec],
        yield: (@Sendable (AgentStreamEvent) -> Void)?
    ) async throws -> (text: String, toolCalls: [ToolCall]) {
        var text = ""
        var toolCalls: [ToolCall] = []
        for try await chunk in client.stream(messages: messages, tools: specs) {
            if Task.isCancelled {
                throw CancellationError()
            }
            text += chunk.delta
            if !chunk.delta.isEmpty {
                yield?(.chunk(chunk.delta))
            }
            if let calls = chunk.toolCallAccumulator {
                toolCalls = calls
            }
        }
        return (text, toolCalls)
    }

    /// 执行单个工具调用,统一产出轨迹与回填消息。
    private func execute(
        _ call: ToolCall,
        registry: ToolRegistry
    ) async -> (trace: ToolTrace, message: ChatMessage) {
        let arguments = Self.parseArguments(call.arguments)
        let result: ToolResult
        do {
            result = try await registry.execute(name: call.name, arguments: arguments)
        } catch {
            result = ToolResult(text: "工具执行失败: \(error.localizedDescription)")
        }
        let trace = ToolTrace(
            tool: call.name,
            arguments: call.arguments,
            result: String(result.text.prefix(500)),
            files: result.files.map(\.path)
        )
        let message = ChatMessage(
            role: .tool,
            content: .text(result.text),
            toolCallID: call.id,
            toolName: call.name
        )
        return (trace, message)
    }

    // MARK: - 落盘

    /// 保存历史(含工具产出附件)、聊天记录与自动记忆。
    private func persist(_ session: Session, reply: String, traces: [ToolTrace]) {
        var history = session.history
        let attachments = traces.flatMap(\.files).map { FileAttachment(path: $0) }
        history.append(
            ChatMessage(
                role: .assistant,
                content: .text(reply),
                fileAttachments: attachments
            )
        )
        try? store.saveMessages(
            threadID: session.threadID,
            persona: session.persona,
            messages: Array(history.suffix(historyLimit))
        )
        try? store.addChatRecord(persona: session.persona, role: "user", content: session.userText)
        try? store.addChatRecord(persona: session.persona, role: "assistant", content: reply)
        if session.userText.count >= autoMemoryThreshold {
            try? store.addMemory(persona: session.persona, content: session.userText, kind: "long_term")
        }
    }

    /// 解析工具参数 JSON(对齐原版 parse_tool_arguments;解析失败回退空参数)
    static func parseArguments(_ raw: String) -> [String: AnyCodable] {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: AnyCodable].self, from: data)
        else {
            return [:]
        }
        return decoded
    }
}
