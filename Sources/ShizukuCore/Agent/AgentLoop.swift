import Foundation

/// 单轮工具调用轨迹(对齐原版 trace)
public struct ToolTrace: Sendable, Equatable {
    public let tool: String
    public let arguments: String
    public let result: String

    public init(tool: String, arguments: String, result: String) {
        self.tool = tool
        self.arguments = arguments
        self.result = result
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

    // MARK: - 主入口

    public func invoke(
        message: String,
        persona: String? = nil,
        threadID: String? = nil
    ) async throws -> AgentResult {
        let current = persona ?? defaultPersona()
        let thread = threadID ?? "persona:\(current)"

        // 1. 恢复历史
        var history = (try? store.loadMessages(threadID: thread, persona: current)) ?? []

        // 2. 组装用户消息
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        history.append(.text(.user, text.isEmpty ? "（空消息）" : text))

        // 3. 检索长期记忆
        let memories = (try? store.searchMemories(query: text.isEmpty ? current : text, persona: current, topK: 5)) ?? []
        let memoryText = memories.map { "- \($0.content)" }.joined(separator: "\n")
            .isEmpty ? "暂无长期记忆。" : memories.map { "- \($0.content)" }.joined(separator: "\n")

        // 4. 构建系统提示词
        let personaPrompt = personas.load(id: current)?.buildSystemPrompt() ?? config.agent.systemPrompt
        let systemPrompt = """
        \(personaPrompt)

        [长期记忆]
        \(memoryText)

        你是传统工具循环 Agent:需要外部信息时先调用工具,再根据工具结果回答。
        \(imageHint)
        """

        // 5. 执行工具循环
        let (reply, traces, engine) = try await runLoop(
            systemPrompt: systemPrompt,
            history: history,
            persona: current
        )

        // 6. 落盘:历史 + 聊天记录 + 自动记忆
        history.append(.text(.assistant, reply))
        try? store.saveMessages(threadID: thread, persona: current, messages: Array(history.suffix(historyLimit)))
        try? store.addChatRecord(persona: current, role: "user", content: text)
        try? store.addChatRecord(persona: current, role: "assistant", content: reply)
        if text.count >= autoMemoryThreshold {
            try? store.addMemory(persona: current, content: text, kind: "long_term")
        }

        return AgentResult(
            success: true,
            persona: current,
            reply: reply,
            memories: memories,
            engine: engine,
            trace: traces
        )
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
        let current = persona ?? defaultPersona()
        let thread = threadID ?? "persona:\(current)"
        var history = (try? store.loadMessages(threadID: thread, persona: current)) ?? []

        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        history.append(.text(.user, text.isEmpty ? "（空消息）" : text))

        let memories = (try? store.searchMemories(query: text.isEmpty ? current : text, persona: current, topK: 5)) ?? []
        let memoryText = memories.map { "- \($0.content)" }.joined(separator: "\n")
            .isEmpty ? "暂无长期记忆。" : memories.map { "- \($0.content)" }.joined(separator: "\n")

        let personaPrompt = personas.load(id: current)?.buildSystemPrompt() ?? config.agent.systemPrompt
        let systemPrompt = """
        \(personaPrompt)

        [长期记忆]
        \(memoryText)

        你是传统工具循环 Agent:需要外部信息时先调用工具,再根据工具结果回答。
        \(imageHint)
        """

        let (reply, traces, engine) = try await runStreamingLoop(
            systemPrompt: systemPrompt,
            history: history,
            persona: current,
            yield: yield
        )

        // 落盘(与 invoke 一致)
        history.append(.text(.assistant, reply))
        try? store.saveMessages(threadID: thread, persona: current, messages: Array(history.suffix(historyLimit)))
        try? store.addChatRecord(persona: current, role: "user", content: text)
        try? store.addChatRecord(persona: current, role: "assistant", content: reply)
        if text.count >= autoMemoryThreshold {
            try? store.addMemory(persona: current, content: text, kind: "long_term")
        }

        yield(.finished(AgentResult(
            success: true,
            persona: current,
            reply: reply,
            memories: memories,
            engine: engine,
            trace: traces
        )))
    }

    private func runStreamingLoop(
        systemPrompt: String,
        history: [ChatMessage],
        persona: String,
        yield: @escaping @Sendable (AgentStreamEvent) -> Void
    ) async throws -> (reply: String, traces: [ToolTrace], engine: String) {
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
                yield(.fallback(reply))
                return (reply, [], "local-fallback")
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

        let registry = ToolRegistry()
        let tools: [any Tool]
        if let toolsOverride {
            tools = toolsOverride
        } else {
            tools = buildDefaultTools(persona: persona)
        }
        for tool in tools {
            registry.register(tool)
        }
        let specs = tools.map(\.spec)

        var messages: [ChatMessage] = [.text(.system, systemPrompt)]
        messages.append(contentsOf: history.suffix(12))
        var traces: [ToolTrace] = []

        for _ in 0..<max(config.agent.maxRounds, 1) {
            var textBuffer = ""
            var toolCalls: [ToolCall] = []
            var finishReason: String?

            for try await chunk in client.stream(messages: messages, tools: specs) {
                if Task.isCancelled {
                    throw CancellationError()
                }
                textBuffer += chunk.delta
                if !chunk.delta.isEmpty {
                    yield(.chunk(chunk.delta))
                }
                if let calls = chunk.toolCallAccumulator {
                    toolCalls = calls
                }
                if let reason = chunk.finishReason {
                    finishReason = reason
                }
            }

            if toolCalls.isEmpty {
                return (textBuffer, traces, "tool-stream")
            }

            // 回填 assistant 工具调用消息
            messages.append(
                ChatMessage(
                    role: .assistant,
                    content: .text(textBuffer),
                    toolCalls: toolCalls
                )
            )

            // 执行工具
            for call in toolCalls {
                let args = Self.parseArguments(call.arguments)
                let result: String
                do {
                    result = try await registry.execute(name: call.name, arguments: args)
                } catch {
                    result = "工具执行失败: \(error.localizedDescription)"
                }
                let trace = ToolTrace(tool: call.name, arguments: call.arguments, result: String(result.prefix(500)))
                traces.append(trace)
                yield(.toolCalled(trace))
                messages.append(
                    ChatMessage(
                        role: .tool,
                        content: .text(result),
                        toolCallID: call.id,
                        toolName: call.name
                    )
                )
            }
        }
        let limitText = "工具调用轮次过多,已停止。请把问题拆小后再试。"
        yield(.limitReached(limitText))
        return (limitText, traces, "tool-loop-limit")
    }

    // MARK: - 循环

    private func runLoop(
        systemPrompt: String,
        history: [ChatMessage],
        persona: String
    ) async throws -> (reply: String, traces: [ToolTrace], engine: String) {
        // 优先使用注入客户端(测试);否则按配置构建
        let client: any LLMClient
        if let clientOverride {
            client = clientOverride
        } else {
            // 无 API Key 且非本地模型时,走本地回退(对齐原版)
            let apiKey = (try? keychain.string(forKey: "llm.api_key")) ?? ""
            if config.llm.provider != "ollama" && apiKey.isEmpty {
                let lastUser = history.last(where: { $0.role == .user })?.content.plainText ?? ""
                let reply = """
                [\(persona)] 已收到:\(lastUser)
                当前运行传统 Agent 循环。未配置主模型 API Key,因此使用本地回退回复。
                """
                return (reply, [], "local-fallback")
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

        // 构建工具注册表
        let registry = ToolRegistry()
        let tools: [any Tool]
        if let toolsOverride {
            tools = toolsOverride
        } else {
            tools = buildDefaultTools(persona: persona)
        }
        for tool in tools {
            registry.register(tool)
        }
        let specs = tools.map(\.spec)

        var messages: [ChatMessage] = [.text(.system, systemPrompt)]
        messages.append(contentsOf: history.suffix(12))
        var traces: [ToolTrace] = []

        for _ in 0..<max(config.agent.maxRounds, 1) {
            let response = try await client.chat(messages: messages, tools: specs)
            if response.toolCalls.isEmpty {
                return (response.content, traces, "tool-loop")
            }

            // 回填 assistant 工具调用消息
            messages.append(
                ChatMessage(
                    role: .assistant,
                    content: .text(response.content),
                    toolCalls: response.toolCalls
                )
            )

            // 逐个执行工具
            for call in response.toolCalls {
                let args = Self.parseArguments(call.arguments)
                let result: String
                do {
                    result = try await registry.execute(name: call.name, arguments: args)
                } catch {
                    result = "工具执行失败: \(error.localizedDescription)"
                }
                traces.append(
                    ToolTrace(tool: call.name, arguments: call.arguments, result: String(result.prefix(500)))
                )
                messages.append(
                    ChatMessage(
                        role: .tool,
                        content: .text(result),
                        toolCallID: call.id,
                        toolName: call.name
                    )
                )
            }
        }
        return ("工具调用轮次过多,已停止。请把问题拆小后再试。", traces, "tool-loop-limit")
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
