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
    /// 实际成功响应的模型 id(回退后可能不是首选)
    public let activeModel: String

    public init(
        success: Bool,
        persona: String,
        reply: String,
        memories: [MemoryItem],
        engine: String,
        trace: [ToolTrace],
        activeModel: String = ""
    ) {
        self.success = success
        self.persona = persona
        self.reply = reply
        self.memories = memories
        self.engine = engine
        self.trace = trace
        self.activeModel = activeModel
    }
}

/// 流式事件(UI 直接消费)
public enum AgentStreamEvent: Sendable {
    /// 回复文本增量
    case chunk(String)
    /// 工具调用轨迹
    case toolCalled(ToolTrace)
    /// 任务计划变更(UI 实时更新)
    case planUpdated(TaskPlan)
    /// 上下文用量/压缩状态更新
    case contextUpdated(SessionContextState)
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
    /// 审批回调(由平台壳注入);nil 时外部写入/执行一律拒绝
    private let approvalHandler: ApprovalHandler?
    /// 主动澄清回调(由平台壳注入);nil 时不暴露 ask_user 工具
    private let clarificationHandler: ClarificationHandler?
    /// 测试注入:按解析后的模型创建客户端(优先于真实网络客户端)
    private let clientFactory: (@Sendable (ResolvedModel) -> any LLMClient)?
    /// 额外工具(MCP 适配器等),随内置工具一起注册
    private let extraTools: [any Tool]
    /// 已启用技能的渐进披露索引(name + description),注入 system prompt
    private let skillCatalog: String

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
        toolsOverride: [any Tool]? = nil,
        approvalHandler: ApprovalHandler? = nil,
        clarificationHandler: ClarificationHandler? = nil,
        clientFactory: (@Sendable (ResolvedModel) -> any LLMClient)? = nil,
        extraTools: [any Tool] = [],
        skillCatalog: String = ""
    ) {
        self.store = store
        self.config = config
        self.keychain = keychain
        self.personas = personas
        self.workspace = workspace
        self.clientOverride = clientOverride
        self.toolsOverride = toolsOverride
        self.approvalHandler = approvalHandler
        self.clarificationHandler = clarificationHandler
        self.clientFactory = clientFactory
        self.extraTools = extraTools
        self.skillCatalog = skillCatalog
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
        /// 本轮运行标识(绑定任务计划,防止跨轮串写)
        let runID: String
        /// 本轮开始时的任务计划
        let plan: TaskPlan
        let systemPrompt: String
    }

    /// 运行模式:真实客户端 + 工具集,或无 Key 本地回退。
    /// 一组按顺序尝试的模型客户端(同一次请求内回退)。
    private struct ModelPool {
        struct Entry {
            let id: String
            let model: ModelConfig
            let client: any LLMClient
        }

        let entries: [Entry]

        var primaryModelID: String { entries.first?.id ?? "" }
        var primaryModelName: String { entries.first?.model.model ?? "" }
        var contextWindow: Int { entries.first?.model.contextWindow ?? 32_768 }
        var maxOutputTokens: Int { entries.first?.model.maxOutputTokens ?? 4_096 }
    }

    private enum RunMode {
        case live(pool: ModelPool, registry: ToolRegistry, specs: [ToolSpec])
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

    /// 单次无工具补全(技能复盘、标题生成等内部用途)。
    public func complete(prompt: String, system: String) async throws -> String {
        let registry = ModelRegistry(config: config, keychain: keychain)
        let candidates = try registry.agentCandidates()
        let usable = candidates.filter { $0.provider.isOllama || !$0.apiKey.isEmpty }
        guard let first = usable.first else { throw LLMError.invalidResponse }
        let client = clientFactory?(first) ?? makeClient(for: first)
        let response = try await client.chat(
            messages: [.text(.system, system), .text(.user, prompt)],
            tools: []
        )
        return response.content
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

        // 开启本轮计划:覆盖可能残留的 running 标记(崩溃恢复),
        // runID 只在本次执行内有效,工具写入必须匹配。
        var plan = (try? store.loadTaskPlan(threadID: thread, persona: current)) ?? .empty
        let runID = UUID().uuidString
        plan.runID = runID
        plan.running = true
        try? store.saveTaskPlan(plan, threadID: thread, persona: current)

        return Session(
            persona: current,
            threadID: thread,
            userText: text,
            history: history,
            memories: memories,
            runID: runID,
            plan: plan,
            systemPrompt: buildSystemPrompt(persona: current, memories: memories, plan: plan)
        )
    }

    /// 人格 prompt + 长期记忆 + 工作模式 + 工具使用约束 + 任务计划。
    private func buildSystemPrompt(persona: String, memories: [MemoryItem], plan: TaskPlan) -> String {
        let memoryText = memories.isEmpty
            ? "暂无长期记忆。"
            : memories.map { "- \($0.content)" }.joined(separator: "\n")
        let personaPrompt = personas.load(id: persona)?.buildSystemPrompt() ?? config.agent.systemPrompt
        let planText = plan.promptText
        let planSection = planText.isEmpty ? "" : "\n\n\(planText)"
        let clarificationSection: String
        if clarificationHandler == nil {
            clarificationSection = ""
        } else {
            clarificationSection = """

            [主动澄清]
            当关键信息缺失,且不同选择会显著改变方案时,调用 ask_user 向用户提问。
            - 先尝试从上下文、记忆和工具结果推断;能确定就不要问。
            - 每轮最多 2 个问题;不要用提问替代执行,也不要问“是否继续”这类低价值问题。
            - 优先给 2-4 个具体选项,可标记 recommended;始终允许用户自由补充。
            - 说明为什么需要这个信息,以及不同选择的影响。
            - 用户跳过后,采用最保守、可逆的默认方案继续,并明确说明假设。
            """
        }
        let mode = config.agent.workMode
        return """
        \(personaPrompt)

        [工作模式]
        \(mode.title):\(mode.detail)

        [长期记忆]
        \(memoryText)

        你是传统工具循环 Agent:需要外部信息时先调用工具,再根据工具结果回答。
        \(imageHint)

        文件工具(list_dir/read_file)可以读取任意本地路径,包括工作区外的绝对路径;不能因为路径在工作区外就声称无法读取。
        写入范围由工作模式决定:安全模式只能写工作区,完全控制模式写工作区外会先请求用户审批。
        若用户要求写到桌面或其他目录,在安全模式下将文件写入工作区并说明实际完整路径;在完全控制模式下可以直接写入。

        [任务计划]
        多步骤执行任务开始时使用 todowrite 创建具体任务列表,只将当前步骤标为 in_progress,每完成一个步骤就更新。
        验证后才标为 completed。中断或失败时保留未完成状态,不要虚报完成;简单问答不需要计划。

        \(clarificationSection)

        [技能]
        需要复用成熟流程(代码审查、会议纪要、调研简报等)时,先查看下方索引,再用 run_skill 加载对应指令后执行。
        \(skillCatalog.isEmpty ? "当前没有已启用技能。" : skillCatalog)\(planSection)
        """
    }

    // MARK: - 客户端与工具装配

    /// 解析客户端:测试注入 > Ollama > OpenAI 兼容;无 Key 时返回本地回退。
    private func makeRunMode(session: Session) -> RunMode {
        let (registry, specs) = makeToolRegistry(session: session)

        // 测试注入:单客户端,保持既有测试路径
        if let clientOverride {
            let model = ModelConfig(
                id: "override",
                provider: "override",
                model: config.llm.model,
                contextWindow: config.llm.contextWindow,
                maxOutputTokens: config.llm.maxOutputTokens,
                temperature: config.llm.temperature
            )
            let pool = ModelPool(entries: [
                ModelPool.Entry(id: config.llm.model, model: model, client: clientOverride)
            ])
            return .live(pool: pool, registry: registry, specs: specs)
        }

        let modelRegistry = ModelRegistry(config: config, keychain: keychain)
        let candidates: [ResolvedModel]
        do {
            candidates = try modelRegistry.agentCandidates()
        } catch {
            return .fallback(reply: localFallbackReply(session))
        }
        // 没有 Key 且不是 Ollama 的候选跳过;全部跳过则本地回退
        let usable = candidates.filter { $0.provider.isOllama || !$0.apiKey.isEmpty }
        guard !usable.isEmpty else {
            return .fallback(reply: localFallbackReply(session))
        }
        let entries = usable.map { resolved in
            ModelPool.Entry(
                id: resolved.id,
                model: resolved.model,
                client: clientFactory?(resolved) ?? makeClient(for: resolved)
            )
        }
        return .live(pool: ModelPool(entries: entries), registry: registry, specs: specs)
    }

    private func makeClient(for resolved: ResolvedModel) -> any LLMClient {
        if resolved.provider.isOllama {
            return LocalOllamaClient(
                model: resolved.model.model,
                temperature: resolved.model.temperature
            )
        }
        return OpenAICompatibleClient(
            baseURL: resolved.provider.baseURL,
            apiKey: resolved.apiKey,
            model: resolved.model.model,
            temperature: resolved.model.temperature
        )
    }

    private func localFallbackReply(_ session: Session) -> String {
        let lastUser = session.history.last(where: { $0.role == .user })?.content.plainText ?? ""
        return """
        [\(session.persona)] 已收到:\(lastUser)
        当前运行传统 Agent 循环。未配置主模型 API Key,因此使用本地回退回复。
        """
    }

    private func makeToolRegistry(session: Session) -> (ToolRegistry, [ToolSpec]) {
        let tools = toolsOverride ?? buildDefaultTools(session: session)
        let registry = ToolRegistry()
        for tool in tools {
            registry.register(tool)
        }
        // 只把当前模式允许的工具暴露给模型;执行阶段还会再校验一次
        let specs = tools
            .filter { config.agent.workMode.allows(tool: $0.name) }
            .map(\.spec)
        return (registry, specs)
    }

    /// 内置工具集(绑定当前人格、工作区、会话与运行标识)
    private func buildDefaultTools(session: Session) -> [any Tool] {
        let policy = FileAccessPolicy(mode: config.agent.workMode, approval: approvalHandler)
        var tools: [any Tool] = [
            BuiltinTools.ListDirTool(workspace: workspace, policy: policy),
            BuiltinTools.ReadFileTool(workspace: workspace, policy: policy),
            BuiltinTools.WriteFileTool(workspace: workspace, policy: policy),
            BuiltinTools.SearchMemoryTool(store: store, persona: session.persona),
            BuiltinTools.AddMemoryTool(
                store: store,
                persona: session.persona,
                threadID: session.threadID
            ),
            TaskPlanTools.TodoWriteTool(
                store: store,
                threadID: session.threadID,
                persona: session.persona,
                runID: session.runID
            ),
            TaskPlanTools.TodoReadTool(
                store: store,
                threadID: session.threadID,
                persona: session.persona
            ),
        ]
        if let clarificationHandler {
            tools.append(AskUserTool(handler: clarificationHandler))
        }
        #if os(macOS)
        tools.append(BuiltinTools.RunLocalAgentTool())
        #endif
        tools.append(contentsOf: extraTools)
        return tools
    }

    // MARK: - 主入口

    public func invoke(
        message: String,
        persona: String? = nil,
        threadID: String? = nil
    ) async throws -> AgentResult {
        let session = prepareSession(message: message, persona: persona, threadID: threadID)
        defer { endRun(session) }
        let recorder = RunRecorder(threadID: session.threadID, persona: session.persona)
        recorder.add(.started, title: "开始", detail: session.userText)
        let promptTokens = TokenEstimator.estimate(session.userText)

        do {
            switch makeRunMode(session: session) {
            case .fallback(let reply):
                recorder.add(.finished, title: "本地回退", detail: reply)
                persist(session, reply: reply, traces: [])
                try? store.saveRun(recorder.snapshot(
                    status: .completed,
                    model: "local-fallback",
                    replyPreview: reply,
                    promptTokens: promptTokens,
                    completionTokens: TokenEstimator.estimate(reply)
                ))
                return AgentResult(
                    success: true,
                    persona: session.persona,
                    reply: reply,
                    memories: session.memories,
                    engine: "local-fallback",
                    trace: [],
                    activeModel: "local-fallback"
                )
            case let .live(pool, registry, specs):
                let (reply, traces, engine, activeModel) = try await runToolLoop(
                    session: session,
                    pool: pool,
                    registry: registry,
                    specs: specs,
                    yield: nil,
                    recorder: recorder
                )
                persist(session, reply: reply, traces: traces)
                recorder.add(
                    .finished,
                    title: "完成",
                    detail: reply,
                    metadata: ["engine": engine, "tools": String(traces.count)]
                )
                try? store.saveRun(recorder.snapshot(
                    status: .completed,
                    model: activeModel,
                    replyPreview: reply,
                    promptTokens: promptTokens,
                    completionTokens: TokenEstimator.estimate(reply)
                ))
                return AgentResult(
                    success: true,
                    persona: session.persona,
                    reply: reply,
                    memories: session.memories,
                    engine: engine,
                    trace: traces,
                    activeModel: activeModel
                )
            }
        } catch {
            recorder.add(.error, title: "失败", detail: error.localizedDescription, ok: false)
            try? store.saveRun(recorder.snapshot(status: .failed, model: ""))
            throw error
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
        defer { endRun(session) }
        let recorder = RunRecorder(threadID: session.threadID, persona: session.persona)
        recorder.add(.started, title: "开始", detail: session.userText)
        let promptTokens = TokenEstimator.estimate(session.userText)
        if !session.plan.items.isEmpty {
            yield(.planUpdated(session.plan))
        }

        do {
            switch makeRunMode(session: session) {
            case .fallback(let reply):
                yield(.fallback(reply))
                persist(session, reply: reply, traces: [])
                endRun(session)
                recorder.add(.finished, title: "本地回退", detail: reply)
                try? store.saveRun(recorder.snapshot(
                    status: .completed,
                    model: "local-fallback",
                    replyPreview: reply,
                    promptTokens: promptTokens,
                    completionTokens: TokenEstimator.estimate(reply)
                ))
                if let plan = currentPlan(session) { yield(.planUpdated(plan)) }
                yield(.finished(AgentResult(
                    success: true,
                    persona: session.persona,
                    reply: reply,
                    memories: session.memories,
                    engine: "local-fallback",
                    trace: [],
                    activeModel: "local-fallback"
                )))
            case let .live(pool, registry, specs):
                let (reply, traces, engine, activeModel) = try await runToolLoop(
                    session: session,
                    pool: pool,
                    registry: registry,
                    specs: specs,
                    yield: yield,
                    recorder: recorder
                )
                persist(session, reply: reply, traces: traces)
                endRun(session)
                recorder.add(
                    .finished,
                    title: "完成",
                    detail: reply,
                    metadata: ["engine": engine, "tools": String(traces.count)]
                )
                try? store.saveRun(recorder.snapshot(
                    status: .completed,
                    model: activeModel,
                    replyPreview: reply,
                    promptTokens: promptTokens,
                    completionTokens: TokenEstimator.estimate(reply)
                ))
                if let plan = currentPlan(session) { yield(.planUpdated(plan)) }
                yield(.finished(AgentResult(
                    success: true,
                    persona: session.persona,
                    reply: reply,
                    memories: session.memories,
                    engine: engine,
                    trace: traces,
                    activeModel: activeModel
                )))
            }
        } catch {
            recorder.add(.error, title: "失败", detail: error.localizedDescription, ok: false)
            try? store.saveRun(recorder.snapshot(status: .failed, model: ""))
            throw error
        }
    }

    // MARK: - 工具循环

    /// 模型/工具循环。`yield == nil` 走非流式 `chat`,`yield != nil` 走流式 `stream`。
    private func runToolLoop(
        session: Session,
        pool: ModelPool,
        registry: ToolRegistry,
        specs: [ToolSpec],
        yield: (@Sendable (AgentStreamEvent) -> Void)?,
        recorder: RunRecorder
    ) async throws -> (reply: String, traces: [ToolTrace], engine: String, activeModel: String) {
        guard let primary = pool.entries.first else {
            throw LLMError.invalidResponse
        }
        let streaming = yield != nil
        var messages: [ChatMessage] = [.text(.system, session.systemPrompt)]
        messages.append(contentsOf: session.history)
        var traces: [ToolTrace] = []
        var lastPlan = session.plan
        var lastContext: SessionContextState?
        var activeModel = primary.id
        let contextManager = ContextManager(
            store: store,
            contextWindow: pool.contextWindow,
            maxOutputTokens: pool.maxOutputTokens
        )

        for round in 0..<max(config.agent.maxRounds, 1) {
            // 每次模型调用前检查预算;压缩只影响请求视图,不改动完整历史
            let prepared = try await contextManager.prepare(
                messages: messages,
                tools: specs,
                threadID: session.threadID,
                persona: session.persona,
                model: activeModel,
                client: primary.client
            )
            if prepared.state != lastContext {
                lastContext = prepared.state
                recorder.add(
                    .context,
                    title: "上下文 \(Int(prepared.state.usagePercent))%",
                    detail: prepared.state.summary,
                    metadata: [
                        "tokens": String(prepared.state.estimatedTokens),
                        "covered": String(prepared.state.coveredCount),
                        "pruned_tools": String(prepared.state.prunedTools),
                    ]
                )
                yield?(.contextUpdated(prepared.state))
            }
            let requestMessages = prepared.messages
            let modelStarted = Date()

            let text: String
            let toolCalls: [ToolCall]
            if streaming {
                (text, toolCalls, activeModel) = try await streamWithFallback(
                    pool: pool,
                    messages: requestMessages,
                    specs: specs,
                    yield: yield
                )
            } else {
                let (response, modelID) = try await chatWithFallback(
                    pool: pool,
                    messages: requestMessages,
                    specs: specs
                )
                text = response.content
                toolCalls = response.toolCalls
                activeModel = modelID
            }
            recorder.add(
                .model,
                title: activeModel,
                detail: "第 \(round + 1) 轮",
                durationMs: Int(Date().timeIntervalSince(modelStarted) * 1000),
                metadata: ["round": String(round + 1)]
            )

            if toolCalls.isEmpty {
                return (text, traces, streaming ? "tool-stream" : "tool-loop", activeModel)
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
                let (trace, toolMessage) = await execute(
                    call,
                    registry: registry,
                    recorder: recorder
                )
                traces.append(trace)
                yield?(.toolCalled(trace))
                messages.append(toolMessage)

                // todowrite 等工具可能改写计划,实时推给 UI
                if let updated = currentPlan(session), updated != lastPlan {
                    lastPlan = updated
                    recorder.add(.plan, title: "任务计划", detail: updated.displayText)
                    yield?(.planUpdated(updated))
                }
            }
        }

        let limitText = "工具调用轮次过多,已停止。请把问题拆小后再试。"
        recorder.add(.error, title: "轮次上限", detail: limitText, ok: false)
        yield?(.limitReached(limitText))
        return (limitText, traces, "tool-loop-limit", activeModel)
    }

    /// 非流式请求:按模型组顺序回退,返回实际成功的模型 id。
    private func chatWithFallback(
        pool: ModelPool,
        messages: [ChatMessage],
        specs: [ToolSpec]
    ) async throws -> (response: LLMResponse, modelID: String) {
        var lastError: Error?
        for entry in pool.entries {
            do {
                let response = try await entry.client.chat(messages: messages, tools: specs)
                return (response, entry.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? LLMError.invalidResponse
    }

    /// 流式请求:首个增量产出前失败可切换到下一个模型;已产出内容后失败则原样抛出。
    private func streamWithFallback(
        pool: ModelPool,
        messages: [ChatMessage],
        specs: [ToolSpec],
        yield: (@Sendable (AgentStreamEvent) -> Void)?
    ) async throws -> (text: String, toolCalls: [ToolCall], modelID: String) {
        var lastError: Error?
        for entry in pool.entries {
            var text = ""
            var toolCalls: [ToolCall] = []
            var emitted = false
            do {
                for try await chunk in entry.client.stream(messages: messages, tools: specs) {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    text += chunk.delta
                    if !chunk.delta.isEmpty {
                        emitted = true
                        yield?(.chunk(chunk.delta))
                    }
                    if let calls = chunk.toolCallAccumulator {
                        toolCalls = calls
                    }
                }
                return (text, toolCalls, entry.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if emitted { throw error }
                lastError = error
            }
        }
        throw lastError ?? LLMError.invalidResponse
    }

    /// 执行单个工具调用,统一产出轨迹与回填消息。
    private func execute(
        _ call: ToolCall,
        registry: ToolRegistry,
        recorder: RunRecorder
    ) async -> (trace: ToolTrace, message: ChatMessage) {
        let started = Date()
        let mode = config.agent.workMode
        let argumentText = String(call.arguments.prefix(800))

        func record(_ output: (trace: ToolTrace, message: ChatMessage), ok: Bool) {
            recorder.add(
                .tool,
                title: call.name,
                detail: output.trace.result,
                durationMs: Int(Date().timeIntervalSince(started) * 1000),
                ok: ok,
                metadata: ["args": argumentText]
            )
        }

        guard mode.allows(tool: call.name) else {
            let output = denied(call, reason: "当前为\(mode.title)模式,不允许执行工具 \(call.name)。")
            record(output, ok: false)
            return output
        }
        if mode.requiresExecutionApproval, WorkMode.requiresExecutionApproval(for: call.name) {
            let decision = await askApproval(
                .toolExecution,
                detail: "\(call.name)\n\(argumentText)"
            )
            recorder.add(
                .approval,
                title: call.name,
                detail: "工具执行审批",
                ok: decision != .reject,
                metadata: ["decision": decision.rawValue]
            )
            guard decision != .reject else {
                let output = denied(call, reason: "用户拒绝执行工具 \(call.name)。")
                record(output, ok: false)
                return output
            }
        }

        let arguments = Self.parseArguments(call.arguments)
        let isClarification = call.name == "ask_user"
        if isClarification {
            let question = (arguments["question"]?.value as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let context = arguments["context"]?.value as? String ?? ""
            recorder.add(
                .question,
                title: "等待用户回答",
                detail: question,
                metadata: ["context": context]
            )
        }
        var ok = true
        let result: ToolResult
        do {
            result = try await registry.execute(name: call.name, arguments: arguments)
        } catch {
            ok = false
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
        let output = (trace, message)
        record(output, ok: ok)
        if isClarification {
            recorder.add(
                .answer,
                title: "用户回答",
                detail: String(result.text.prefix(500)),
                ok: true
            )
        }
        return output
    }

    private func denied(_ call: ToolCall, reason: String) -> (trace: ToolTrace, message: ChatMessage) {
        let message = ChatMessage(
            role: .tool,
            content: .text(reason),
            toolCallID: call.id,
            toolName: call.name
        )
        return (
            ToolTrace(tool: call.name, arguments: call.arguments, result: reason),
            message
        )
    }

    /// 请求审批;未注入处理器时默认拒绝(安全兜底)。
    private func askApproval(_ kind: ApprovalKind, detail: String) async -> ApprovalDecision {
        guard let approvalHandler else { return .reject }
        return await approvalHandler(ApprovalRequest(kind: kind, detail: detail))
    }

    // MARK: - 任务计划生命周期

    /// 读取当前计划(不存在或读取失败时返回 nil)。
    private func currentPlan(_ session: Session) -> TaskPlan? {
        try? store.loadTaskPlan(threadID: session.threadID, persona: session.persona)
    }

    /// 结束本轮:仅当计划仍绑定本轮的 runID 时才清除 running。
    private func endRun(_ session: Session) {
        guard var plan = currentPlan(session), plan.runID == session.runID else { return }
        plan.running = false
        try? store.saveTaskPlan(plan, threadID: session.threadID, persona: session.persona)
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
        try? store.addChatRecord(persona: session.persona, role: "user", content: session.userText, threadID: session.threadID)
        try? store.addChatRecord(persona: session.persona, role: "assistant", content: reply, threadID: session.threadID)
        if session.userText.count >= autoMemoryThreshold {
            try? store.addMemory(
                persona: session.persona,
                content: session.userText,
                kind: "long_term",
                sourceThread: session.threadID,
                sourceKind: "auto",
                confidence: 0.5
            )
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
